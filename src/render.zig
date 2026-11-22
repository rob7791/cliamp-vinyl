//! Frame composition: high-res Kitty picture-disc + circular stereo Braille spectrum + info.
const std = @import("std");
const scr = @import("screen.zig");
const art = @import("art.zig");
const cliamp = @import("cliamp.zig");
const kitty = @import("kitty.zig");
const Rgb = scr.Rgb;
const Screen = scr.Screen;

const ANG = 1440;
const TAU: f32 = std.math.tau;

pub const Texture = struct {
    size: usize = 0,
    data: []u8 = &.{}, // size*size*3 RGB (4x smaller than f32 for L2 cache locality)

    fn deinit(self: *Texture, alloc: std.mem.Allocator) void {
        alloc.free(self.data);
        self.* = .{};
    }

    /// Area-resample the source image into a `size`x`size` RGB texture.
    fn build(self: *Texture, alloc: std.mem.Allocator, img: *const art.Image, size: usize) !void {
        self.deinit(alloc);
        self.size = size;
        self.data = try alloc.alloc(u8, size * size * 3);
        if (size == art.SRC) {
            @memcpy(self.data, img.px);
            return;
        }
        const s: f32 = @as(f32, art.SRC) / @as(f32, @floatFromInt(size));
        for (0..size) |y| {
            const y0: usize = @intFromFloat(@floor(@as(f32, @floatFromInt(y)) * s));
            const y1: usize = @max(y0 + 1, @min(art.SRC, @as(usize, @intFromFloat(@floor(@as(f32, @floatFromInt(y + 1)) * s)))));
            for (0..size) |x| {
                const x0: usize = @intFromFloat(@floor(@as(f32, @floatFromInt(x)) * s));
                const x1: usize = @max(x0 + 1, @min(art.SRC, @as(usize, @intFromFloat(@floor(@as(f32, @floatFromInt(x + 1)) * s)))));
                var acc = [3]u32{ 0, 0, 0 };
                var yy = y0;
                while (yy < y1) : (yy += 1) {
                    var xx = x0;
                    while (xx < x1) : (xx += 1) {
                        const i = (yy * art.SRC + xx) * 3;
                        acc[0] += img.px[i];
                        acc[1] += img.px[i + 1];
                        acc[2] += img.px[i + 2];
                    }
                }
                const n: u32 = @intCast((y1 - y0) * (x1 - x0));
                const o = (y * size + x) * 3;
                self.data[o] = @intCast(acc[0] / n);
                self.data[o + 1] = @intCast(acc[1] / n);
                self.data[o + 2] = @intCast(acc[2] / n);
            }
        }
    }

    /// Bilinear sample, u/v in [-1, 1], returning [0..255] RGB.
    inline fn sampleBilinear(self: *const Texture, u: f32, v: f32) [3]u8 {
        const fs: f32 = @floatFromInt(self.size - 1);
        const fx = std.math.clamp((u + 1.0) * 0.5 * fs, 0.0, fs);
        const fy = std.math.clamp((v + 1.0) * 0.5 * fs, 0.0, fs);
        const x0: usize = @intFromFloat(fx);
        const y0: usize = @intFromFloat(fy);
        const x1 = @min(x0 + 1, self.size - 1);
        const y1 = @min(y0 + 1, self.size - 1);
        const tx: u32 = @intFromFloat((fx - @as(f32, @floatFromInt(x0))) * 256.0);
        const ty: u32 = @intFromFloat((fy - @as(f32, @floatFromInt(y0))) * 256.0);
        const itx = 256 - tx;
        const ity = 256 - ty;
        const w00 = itx * ity;
        const w10 = tx * ity;
        const w01 = itx * ty;
        const w11 = tx * ty;
        const row0 = y0 * self.size * 3;
        const row1 = y1 * self.size * 3;
        const a = self.data[row0 + x0 * 3 ..][0..3];
        const b = self.data[row0 + x1 * 3 ..][0..3];
        const c = self.data[row1 + x0 * 3 ..][0..3];
        const d = self.data[row1 + x1 * 3 ..][0..3];
        return .{
            @intCast((w00 * a[0] + w10 * b[0] + w01 * c[0] + w11 * d[0] + 32768) >> 16),
            @intCast((w00 * a[1] + w10 * b[1] + w01 * c[1] + w11 * d[1] + 32768) >> 16),
            @intCast((w00 * a[2] + w10 * b[2] + w01 * c[2] + w11 * d[2] + 32768) >> 16),
        };
    }

    /// Nearest-neighbor sample, u/v in [-1, 1] (used when AA is off for max speed).
    inline fn sampleNearest(self: *const Texture, u: f32, v: f32) [3]u8 {
        const fs: f32 = @floatFromInt(self.size - 1);
        const fx = std.math.clamp((u + 1.0) * 0.5 * fs + 0.5, 0.0, fs);
        const fy = std.math.clamp((v + 1.0) * 0.5 * fs + 0.5, 0.0, fs);
        const x: usize = @intFromFloat(fx);
        const y: usize = @intFromFloat(fy);
        const o = (y * self.size + x) * 3;
        return .{ self.data[o], self.data[o + 1], self.data[o + 2] };
    }
};

pub const BgMode = enum { tint, black };
pub const PeakMode = enum { ellipsis, ellipsis2, path, peak };
pub const VizMotion = enum { raw, smooth };
pub const VizColor = enum { freq, cover };
pub const FxColorMode = enum { cover, spectrum };
pub const InfoMode = enum { auto, show, hide };
pub const DiscRes = enum {
    med,
    high,
    ultra,

    pub fn maxSide(self: DiscRes) usize {
        return switch (self) {
            .med => 384,
            .high => 512,
            .ultra => art.SRC,
        };
    }

    pub fn label(self: DiscRes) []const u8 {
        return switch (self) {
            .med => " disc: 384px ",
            .high => " disc: 512px ",
            .ultra => " disc: 768px ",
        };
    }
};

pub const Params = struct {
    aspect: f32, // cell height / cell width
    angle: f32,
    dt: f32,
    left: []const f32,
    right: []const f32,
    raw_left: []const f32 = &.{},
    raw_right: []const f32 = &.{},
    snap: *const cliamp.Snapshot,
    position: f64,
    sheen: bool,
    bass_top: bool,
    show_fps: bool,
    show_help: bool,
    fps: f32,
    rpm: f32 = 5.0,
    bpm: f32 = 0,
    show_rpm: bool = false,
    peak_mode: PeakMode = .path,
    viz_motion: VizMotion = .raw,
    viz_color: VizColor = .freq,
    glow: bool = true,
    aurora: bool = true,
    fx_color: FxColorMode = .cover,
    hud_msg: []const u8 = "",
    bg_mode: BgMode,
    cava_ok: bool,
    kitty_enc: ?*kitty.Encoder = null,
    kitty_out: ?*std.ArrayList(u8) = null,
    kitty_warn: bool = false,
    force_redraw: bool = false,
    cell_px_w: f32 = 0,
    disc_res: DiscRes = .high,
    aa: bool = true,
    info_alpha: f32 = 1.0,
    info_seekbar: bool = true,
};

pub const Renderer = struct {
    alloc: std.mem.Allocator,
    img: ?*art.Image = null,
    old_img: ?*art.Image = null,
    tex: Texture = .{},
    old_tex: Texture = .{},
    fade: f32 = 1.0,
    amp: [ANG]f32 = [_]f32{0} ** ANG,
    raw_amp: [ANG]f32 = [_]f32{0} ** ANG,
    path_low: [ANG]f32 = [_]f32{0} ** ANG,
    path_mid: [ANG]f32 = [_]f32{0} ** ANG,
    path_high: [ANG]f32 = [_]f32{0} ** ANG,
    ell2_low: [ANG]f32 = [_]f32{0} ** ANG,
    ell2_mid: [ANG]f32 = [_]f32{0} ** ANG,
    ell2_high: [ANG]f32 = [_]f32{0} ** ANG,
    peak: [ANG]f32 = [_]f32{0} ** ANG,
    kick_avg: f32 = 0,
    kick_glow: f32 = 0,
    kick_dom_u: f32 = 0.34,
    sub_l: f32 = 0,
    sub_r: f32 = 0,
    sub_dom_u: f32 = 0.10,
    aurora_phase: f32 = 0,
    tex_size_for: usize = 0,
    img_gen: u64 = 0,

    // dirty tracking for Kitty disc frame emission
    disc_active: bool = false,
    last_col0: usize = 0,
    last_row0: usize = 0,
    last_disc_cols: usize = 0,
    last_disc_rows: usize = 0,
    last_side: usize = 0,
    last_aspect: f32 = 0,
    last_angle: f32 = -1,
    last_fade: f32 = 1.0,
    last_img_gen: u64 = 0,
    last_sheen: bool = false,
    last_aa: bool = true,

    // precomputed per-pixel circular mask & static sheen LUT (rebuilt only on geometry/AA change)
    lut_side: usize = 0,
    lut_box_w: f32 = 0,
    lut_box_h: f32 = 0,
    lut_rd: f32 = 0,
    lut_rh: f32 = 0,
    lut_aa: bool = true,
    disc_alpha: []u8 = &.{},
    disc_sheen: []u8 = &.{},

    pub fn deinit(self: *Renderer) void {
        self.tex.deinit(self.alloc);
        self.old_tex.deinit(self.alloc);
        if (self.disc_alpha.len > 0) self.alloc.free(self.disc_alpha);
        if (self.disc_sheen.len > 0) self.alloc.free(self.disc_sheen);
        if (self.img) |i| i.destroy(self.alloc);
        if (self.old_img) |i| i.destroy(self.alloc);
    }

    pub fn setImage(self: *Renderer, img: *art.Image) void {
        if (self.old_img) |o| o.destroy(self.alloc);
        self.old_img = self.img;
        std.mem.swap(Texture, &self.tex, &self.old_tex);
        self.img = img;
        self.fade = if (self.old_img == null) 1.0 else 0.0;
        self.tex_size_for = 0; // force rebuild of the new texture
        self.img_gen +%= 1;
    }

    fn ensureTextures(self: *Renderer, want_in: usize) void {
        const want = std.math.clamp(want_in, 64, art.SRC);
        if (self.tex_size_for == want) return;
        if (self.img) |i| self.tex.build(self.alloc, i, want) catch return;
        if (self.old_img) |i| {
            if (self.old_tex.size != want) self.old_tex.build(self.alloc, i, want) catch {};
        }
        self.tex_size_for = want;
    }

    const Palette = struct { c1: [3]f32, c2: [3]f32, avg: [3]f32 };

    fn palette(self: *Renderer) Palette {
        const f = self.fade;
        const cur = self.img.?;
        var c1 = toF(cur.c1);
        var c2 = toF(cur.c2);
        var avg = toF(cur.avg);
        if (f < 1.0) if (self.old_img) |o| {
            c1 = mix3(toF(o.c1), c1, f);
            c2 = mix3(toF(o.c2), c2, f);
            avg = mix3(toF(o.avg), avg, f);
        };
        return .{ .c1 = c1, .c2 = c2, .avg = avg };
    }

    fn updateRing(self: *Renderer, p: *const Params) void {
        const n = p.left.len;
        const nf: f32 = @floatFromInt(n - 1);
        const raw_l = if (p.raw_left.len == n) p.raw_left else p.left;
        const raw_r = if (p.raw_right.len == n) p.raw_right else p.right;
        const src_l = if (p.viz_motion == .raw) raw_l else p.left;
        const src_r = if (p.viz_motion == .raw) raw_r else p.right;
        const decay = p.dt * 0.55;

        // Band energies (low / mid / high) per channel following selected viz_motion (raw 1:1 or smooth)
        var low_l: f32 = 0;
        var low_r: f32 = 0;
        var low_w: f32 = 0;
        var mid_l: f32 = 0;
        var mid_r: f32 = 0;
        var mid_w: f32 = 0;
        var high_l: f32 = 0;
        var high_r: f32 = 0;
        var high_w: f32 = 0;
        // Per-band instantaneous peak maxima for ellipsis2 (pure ellipses sized to highest peak)
        var max_low_l: f32 = 0;
        var max_low_r: f32 = 0;
        var max_mid_l: f32 = 0;
        var max_mid_r: f32 = 0;
        var max_high_l: f32 = 0;
        var max_high_r: f32 = 0;
        // Sub-bass (20–80 Hz) & kick drum (100–300 Hz) always use raw unfiltered spectrum for punchy FX
        // 20–80 Hz => u in [0.0, 0.207]; 100–300 Hz => u in [0.241, 0.405]
        var sub_l_sum: f32 = 0;
        var sub_r_sum: f32 = 0;
        var sub_u_num: f32 = 0;
        var sub_u_den: f32 = 0;
        var sub_cnt: f32 = 0;
        var kick_sum: f32 = 0;
        var kick_u_num: f32 = 0;
        var kick_u_den: f32 = 0;
        var kick_cnt: f32 = 0;
        for (0..n) |i| {
            const u = if (n > 1) @as(f32, @floatFromInt(i)) / nf else 0.0;
            const mono = 0.5 * (raw_l[i] + raw_r[i]);
            if (u <= 0.20) {
                sub_l_sum += raw_l[i];
                sub_r_sum += raw_r[i];
                sub_u_num += u * mono;
                sub_u_den += mono;
                sub_cnt += 1.0;
            }
            if (u >= 0.22 and u <= 0.41) {
                kick_sum += mono;
                kick_u_num += u * mono;
                kick_u_den += mono;
                kick_cnt += 1.0;
            }
            const dl = (u - 0.12) / 0.20;
            const dm = (u - 0.50) / 0.22;
            const dh = (u - 0.86) / 0.20;
            const wl = @exp(-(dl * dl));
            const wm = @exp(-(dm * dm));
            const wh = @exp(-(dh * dh));
            low_l += src_l[i] * wl;
            low_r += src_r[i] * wl;
            low_w += wl;
            mid_l += src_l[i] * wm;
            mid_r += src_r[i] * wm;
            mid_w += wm;
            high_l += src_l[i] * wh;
            high_r += src_r[i] * wh;
            high_w += wh;
            if (u <= 0.34) {
                max_low_l = @max(max_low_l, src_l[i]);
                max_low_r = @max(max_low_r, src_r[i]);
            } else if (u < 0.67) {
                max_mid_l = @max(max_mid_l, src_l[i]);
                max_mid_r = @max(max_mid_r, src_r[i]);
            } else {
                max_high_l = @max(max_high_l, src_l[i]);
                max_high_r = @max(max_high_r, src_r[i]);
            }
        }
        if (low_w > 0) {
            low_l /= low_w;
            low_r /= low_w;
        }
        if (mid_w > 0) {
            mid_l /= mid_w;
            mid_r /= mid_w;
        }
        if (high_w > 0) {
            high_l /= high_w;
            high_r /= high_w;
        }

        // Kick sidechain detector: stronger glow for louder (dB) AND more sudden (transient flux) hits
        const kick_e: f32 = if (kick_cnt > 0) std.math.clamp(kick_sum / kick_cnt, 0, 1) else 0;
        if (kick_u_den > 1e-4) self.kick_dom_u = kick_u_num / kick_u_den;
        if (sub_u_den > 1e-4) self.sub_dom_u = sub_u_num / sub_u_den;
        const flux: f32 = @max(0.0, kick_e - self.kick_avg);
        self.kick_avg += (kick_e - self.kick_avg) * @min(1.0, p.dt * 5.5);
        const punch: f32 = std.math.clamp(std.math.pow(f32, kick_e, 1.15) * (0.30 + 3.0 * flux), 0, 1.0);
        if (punch > self.kick_glow) {
            // Fast sidechain attack
            self.kick_glow += (punch - self.kick_glow) * @min(1.0, p.dt * 48.0);
        } else {
            // Smooth pumping release (~150ms)
            self.kick_glow *= @exp(-p.dt * 6.5);
        }
        self.kick_glow = std.math.clamp(self.kick_glow, 0, 1.0);

        // Sub-bass storm aurora envelope (20–80 Hz, per-channel L/R rumble)
        const sl_raw: f32 = if (sub_cnt > 0) std.math.clamp(sub_l_sum / sub_cnt, 0, 1) else 0;
        const sr_raw: f32 = if (sub_cnt > 0) std.math.clamp(sub_r_sum / sub_cnt, 0, 1) else 0;
        if (sl_raw > self.sub_l) {
            self.sub_l += (sl_raw - self.sub_l) * @min(1.0, p.dt * 26.0);
        } else {
            self.sub_l *= @exp(-p.dt * 4.2);
        }
        if (sr_raw > self.sub_r) {
            self.sub_r += (sr_raw - self.sub_r) * @min(1.0, p.dt * 26.0);
        } else {
            self.sub_r *= @exp(-p.dt * 4.2);
        }
        self.sub_l = std.math.clamp(self.sub_l, 0, 1.0);
        self.sub_r = std.math.clamp(self.sub_r, 0, 1.0);
        const sub_avg = 0.5 * (self.sub_l + self.sub_r);
        self.aurora_phase = @mod(self.aurora_phase + p.dt * (0.9 + 2.8 * sub_avg), TAU * 16.0);

        for (0..ANG) |a| {
            const th = (@as(f32, @floatFromInt(a)) + 0.5) / ANG * TAU;
            const right_side = th < std.math.pi;
            const t = if (right_side) th / std.math.pi else (TAU - th) / std.math.pi; // 0 top, 1 bottom
            const u = if (p.bass_top) t else 1.0 - t; // 0 = bass pole, 0.5 = mid sides, 1 = high pole
            const fpos = u * nf;
            const s = smoothstep(0, 0.12, @min(t, 1 - t));
            const own = 0.5 + 0.5 * s;

            const v: f32 = if (p.viz_motion == .raw)
                std.math.clamp(if (right_side) linSample(raw_r, fpos) else linSample(raw_l, fpos), 0, 1)
            else blk: {
                const vr = catmull(p.right, fpos);
                const vl = catmull(p.left, fpos);
                break :blk std.math.clamp(if (right_side) vr * own + vl * (1 - own) else vl * own + vr * (1 - own), 0, 1);
            };
            self.amp[a] = v;
            self.raw_amp[a] = v;
            self.peak[a] = @max(v, self.peak[a] - decay);

            // Slightly deformed elliptical envelopes bulging toward each band's reference frequency
            const el = if (right_side) low_r * own + low_l * (1 - own) else low_l * own + low_r * (1 - own);
            const em = if (right_side) mid_r * own + mid_l * (1 - own) else mid_l * own + mid_r * (1 - own);
            const eh = if (right_side) high_r * own + high_l * (1 - own) else high_l * own + high_r * (1 - own);

            const c_low = @max(0.0, @cos(u * std.math.pi * 0.5));
            const s_mid = @max(0.0, @sin(u * std.math.pi));
            const s_high = @max(0.0, @sin(u * std.math.pi * 0.5));
            const env_low = 0.25 + 0.75 * std.math.pow(f32, c_low, 1.4);
            const env_mid = 0.25 + 0.75 * std.math.pow(f32, s_mid, 1.4);
            const env_high = 0.25 + 0.75 * std.math.pow(f32, s_high, 1.4);

            const deform = 0.88 + 0.22 * v;

            const ell_low = el * env_low * deform * 1.15;
            const ell_mid = em * env_mid * deform * 1.15;
            const ell_high = eh * env_high * deform * 1.15;

            // Union with peaks partitioned by frequency zone (follows bass_top and viz_motion)
            const mask_low = 1.0 - smoothstep(0.32, 0.48, u);
            const mask_mid = smoothstep(0.22, 0.36, u) * (1.0 - smoothstep(0.64, 0.78, u));
            const mask_high = smoothstep(0.52, 0.68, u);

            self.path_low[a] = std.math.clamp(@max(ell_low, v * mask_low), 0, 1.0);
            self.path_mid[a] = std.math.clamp(@max(ell_mid, v * mask_mid), 0, 1.0);
            self.path_high[a] = std.math.clamp(@max(ell_high, v * mask_high), 0, 1.0);

            // ellipsis2: pure smooth ellipses whose major radius reaches each band's highest peak
            const ml = if (right_side) max_low_r * own + max_low_l * (1 - own) else max_low_l * own + max_low_r * (1 - own);
            const mm = if (right_side) max_mid_r * own + max_mid_l * (1 - own) else max_mid_l * own + max_mid_r * (1 - own);
            const mh = if (right_side) max_high_r * own + max_high_l * (1 - own) else max_high_l * own + max_high_r * (1 - own);
            self.ell2_low[a] = std.math.clamp(ml * env_low, 0, 1.0);
            self.ell2_mid[a] = std.math.clamp(mm * env_mid, 0, 1.0);
            self.ell2_high[a] = std.math.clamp(mh * env_high, 0, 1.0);
        }
    }

    pub fn render(self: *Renderer, s: *Screen, p: Params) void {
        if (self.fade < 1.0) self.fade = @min(1.0, self.fade + p.dt / 0.8);

        const pal: Palette = if (self.img != null) self.palette() else .{
            .c1 = .{ 200, 200, 200 },
            .c2 = .{ 255, 255, 255 },
            .avg = .{ 40, 40, 40 },
        };
        const bgf: [3]f32 = switch (p.bg_mode) {
            .tint => .{ pal.avg[0] * 0.13 + 4, pal.avg[1] * 0.13 + 4, pal.avg[2] * 0.13 + 5 },
            .black => .{ 6, 6, 8 },
        };
        const bg = toRgb(bgf);
        s.fill(.{ .cp = ' ', .fg = bg, .bg = bg });

        const cols = s.cols;
        const rows = s.rows;
        const info_rows: usize = if (rows >= 16) 4 else 0;
        const vis_rows = rows - info_rows;
        const k = p.aspect;

        // Cell-aligned disc placement box centered in (0..cols, 0..vis_rows).
        const cx0: f32 = @as(f32, @floatFromInt(cols)) * 0.5;
        const cy0: f32 = @as(f32, @floatFromInt(vis_rows)) * k * 0.5;
        const rmax = @min(cx0, cy0) - 0.3;
        const ring_h = rmax * 0.27;
        const margin = @max(rmax * 0.05, k * 0.8);
        const rd_raw = rmax - ring_h - margin;
        const ring_min: f32 = 0.35;

        var disc_col0: usize = 0;
        var disc_row0: usize = 0;
        var disc_cols: usize = 0;
        var disc_rows: usize = 0;

        if (rd_raw > 2.0 and cols >= 4 and vis_rows >= 4) {
            const half_rows = @max(2, @as(usize, @intFromFloat(@floor(rd_raw / k))));
            disc_rows = @min(vis_rows, half_rows * 2);
            const half_cols = @max(2, @as(usize, @intFromFloat(@round(@as(f32, @floatFromInt(disc_rows)) * 0.5 * k))));
            disc_cols = @min(cols, half_cols * 2);
            disc_col0 = (cols - disc_cols) / 2;
            disc_row0 = (vis_rows - disc_rows) / 2;

            const box_w: f32 = @floatFromInt(disc_cols);
            const box_h: f32 = @as(f32, @floatFromInt(disc_rows)) * k;
            const cx: f32 = @as(f32, @floatFromInt(disc_col0)) + box_w * 0.5;
            const cy: f32 = (@as(f32, @floatFromInt(disc_row0)) + @as(f32, @floatFromInt(disc_rows)) * 0.5) * k;
            const rd = @min(box_w, box_h) * 0.5;
            const r0 = rd + margin;
            const rh = @max(rd * 0.048, 0.75);

            self.updateRing(&p);
            if (p.glow and self.kick_glow > 0.004) {
                const glow_src = if (p.fx_color == .spectrum) pathBandColor(self.kick_dom_u) else pal.c1;
                self.drawGlow(s, cx, cy, rd, rmax, s.rows, k, glow_src, pal.c2, bgf);
            }
            if (p.aurora and (self.sub_l > 0.004 or self.sub_r > 0.004)) {
                self.drawAurora(s, s.rows, p.fx_color);
            }
            self.drawRing(s, &p, cx, cy, rd, r0, ring_h, ring_min, vis_rows, pal.c1, pal.c2, bgf);

            if (p.kitty_enc) |enc| {
                const est_px: usize = if (p.cell_px_w > 0)
                    @intFromFloat(@round(@as(f32, @floatFromInt(disc_cols)) * p.cell_px_w))
                else
                    disc_cols * 14;
                const mode_cap: usize = if (enc.mode == .file) p.disc_res.maxSide() else @min(p.disc_res.maxSide(), 384);
                const side: usize = std.math.clamp(est_px, 128, mode_cap) & ~@as(usize, 1);
                self.ensureTextures(@min(art.SRC, side));
                if (self.img != null and self.tex.size > 0) {
                    const dirty = p.force_redraw or !self.disc_active or
                        self.last_col0 != disc_col0 or self.last_row0 != disc_row0 or
                        self.last_disc_cols != disc_cols or self.last_disc_rows != disc_rows or
                        self.last_side != side or @abs(self.last_aspect - k) > 1e-4 or
                        self.last_img_gen != self.img_gen or self.last_sheen != p.sheen or
                        self.last_aa != p.aa or
                        self.fade < 1.0 or self.last_fade < 1.0 or
                        p.angle != self.last_angle;
                    if (dirty) {
                        enc.ensureSize(side) catch {};
                        if (enc.rgba.len == side * side * 4) {
                            self.rasterizeDiscRgba(enc.rgba, side, box_w, box_h, rd, rh, &p);
                            if (p.kitty_out) |out| {
                                enc.emitFrame(out, self.alloc, disc_col0, disc_row0, disc_cols, disc_rows) catch {};
                            }
                            self.disc_active = true;
                            self.last_col0 = disc_col0;
                            self.last_row0 = disc_row0;
                            self.last_disc_cols = disc_cols;
                            self.last_disc_rows = disc_rows;
                            self.last_side = side;
                            self.last_aspect = k;
                            self.last_angle = p.angle;
                            self.last_fade = self.fade;
                            self.last_img_gen = self.img_gen;
                            self.last_sheen = p.sheen;
                            self.last_aa = p.aa;
                        }
                    }
                }
            } else if (self.disc_active) {
                if (p.kitty_out) |out| kitty.Encoder.emitDeleteAll(out, self.alloc) catch {};
                self.disc_active = false;
            }
        } else if (self.disc_active) {
            if (p.kitty_out) |out| kitty.Encoder.emitDeleteAll(out, self.alloc) catch {};
            self.disc_active = false;
        }

        self.drawInfo(s, &p, vis_rows, disc_col0, disc_row0, disc_cols, disc_rows, pal.c1, pal.c2, bg);
    }

    fn ensureDiscLut(self: *Renderer, side: usize, box_w: f32, box_h: f32, rd: f32, rh: f32, aa: bool) void {
        if (self.lut_side == side and
            @abs(self.lut_box_w - box_w) < 1e-4 and
            @abs(self.lut_box_h - box_h) < 1e-4 and
            @abs(self.lut_rd - rd) < 1e-4 and
            @abs(self.lut_rh - rh) < 1e-4 and
            self.lut_aa == aa and
            self.disc_alpha.len == side * side)
        {
            return;
        }
        const n = side * side;
        if (self.disc_alpha.len != n) {
            if (self.disc_alpha.len > 0) self.alloc.free(self.disc_alpha);
            if (self.disc_sheen.len > 0) self.alloc.free(self.disc_sheen);
            self.disc_alpha = self.alloc.alloc(u8, n) catch {
                self.disc_alpha = &.{};
                self.disc_sheen = &.{};
                self.lut_side = 0;
                return;
            };
            self.disc_sheen = self.alloc.alloc(u8, n) catch {
                self.alloc.free(self.disc_alpha);
                self.disc_alpha = &.{};
                self.disc_sheen = &.{};
                self.lut_side = 0;
                return;
            };
        }
        self.lut_side = side;
        self.lut_box_w = box_w;
        self.lut_box_h = box_h;
        self.lut_rd = rd;
        self.lut_rh = rh;
        self.lut_aa = aa;

        const inv_rd = 1.0 / rd;
        const inv_side = 1.0 / @as(f32, @floatFromInt(side));
        const px_step = @max(box_w, box_h) * inv_side;
        const aa_half: f32 = if (aa) px_step * 0.5 else 0.0;
        const outer_hi = rd + aa_half;
        const outer_lo = rd - aa_half;
        const outer_hi2 = outer_hi * outer_hi;
        const inner_lo = @max(0.0, rh - aa_half);
        const inner_hi = rh + aa_half;
        const sheen_cx: f32 = 0.65998315;
        const sheen_sy: f32 = 0.7512804;

        for (0..side) |py| {
            const ny = ((@as(f32, @floatFromInt(py)) + 0.5) * inv_side - 0.5) * box_h;
            const ny2 = ny * ny;
            const row_off = py * side;
            for (0..side) |px| {
                const nx = ((@as(f32, @floatFromInt(px)) + 0.5) * inv_side - 0.5) * box_w;
                const d2 = nx * nx + ny2;
                const idx = row_off + px;
                if (d2 >= outer_hi2) {
                    self.disc_alpha[idx] = 0;
                    self.disc_sheen[idx] = 0;
                    continue;
                }
                const rho = @sqrt(d2);
                if (rho <= inner_lo) {
                    self.disc_alpha[idx] = 0;
                    self.disc_sheen[idx] = 0;
                    continue;
                }
                const outer_a: f32 = if (!aa or rho <= outer_lo) 1.0 else smoothstep(outer_hi, outer_lo, rho);
                const inner_a: f32 = if (!aa or rho >= inner_hi) 1.0 else smoothstep(inner_lo, inner_hi, rho);
                self.disc_alpha[idx] = @intFromFloat(std.math.clamp(outer_a * inner_a * 255.0 + 0.5, 0, 255));

                if (rho > 1e-4) {
                    const rn = rho * inv_rd;
                    const cphi = (nx * sheen_cx + ny * sheen_sy) / rho;
                    const c2 = cphi * cphi;
                    const c6 = c2 * c2 * c2;
                    const w = c6 * c6 * 0.17 * smoothstep(0.10, 0.40, rn);
                    self.disc_sheen[idx] = @intFromFloat(std.math.clamp(w * 256.0, 0, 255));
                } else {
                    self.disc_sheen[idx] = 0;
                }
            }
        }
    }

    pub fn rasterizeDiscRgba(
        self: *Renderer,
        rgba: []u8,
        side: usize,
        box_w: f32,
        box_h: f32,
        rd: f32,
        rh: f32,
        p: *const Params,
    ) void {
        self.ensureDiscLut(side, box_w, box_h, rd, rh, p.aa);
        if (self.disc_alpha.len != side * side) return;

        const ca = @cos(p.angle);
        const sa = @sin(p.angle);
        const inv_rd = 1.0 / rd;
        const inv_side = 1.0 / @as(f32, @floatFromInt(side));
        const dx_step = box_w * inv_side;
        const du_dx = dx_step * ca * inv_rd;
        const dv_dx = -dx_step * sa * inv_rd;
        const nx0 = (0.5 * inv_side - 0.5) * box_w;

        const use_old = self.fade < 1.0 and self.old_img != null and self.old_tex.size == self.tex.size;
        const fade_u: u32 = @intFromFloat(std.math.clamp(self.fade * 256.0, 0, 256));
        const ifx_u: u32 = 256 - fade_u;
        const do_sheen = p.sheen;
        const do_aa = p.aa;

        for (0..side) |py| {
            const ny = ((@as(f32, @floatFromInt(py)) + 0.5) * inv_side - 0.5) * box_h;
            var u = (nx0 * ca + ny * sa) * inv_rd;
            var v = (-nx0 * sa + ny * ca) * inv_rd;
            const lut_row = py * side;
            const out_row = lut_row * 4;
            for (0..side) |px| {
                const a = self.disc_alpha[lut_row + px];
                const o = out_row + px * 4;
                if (a == 0) {
                    rgba[o] = 0;
                    rgba[o + 1] = 0;
                    rgba[o + 2] = 0;
                    rgba[o + 3] = 0;
                    u += du_dx;
                    v += dv_dx;
                    continue;
                }

                var col = if (do_aa) self.tex.sampleBilinear(u, v) else self.tex.sampleNearest(u, v);
                if (use_old) {
                    const ocol = if (do_aa) self.old_tex.sampleBilinear(u, v) else self.old_tex.sampleNearest(u, v);
                    col = .{
                        @intCast((ifx_u * ocol[0] + fade_u * col[0] + 128) >> 8),
                        @intCast((ifx_u * ocol[1] + fade_u * col[1] + 128) >> 8),
                        @intCast((ifx_u * ocol[2] + fade_u * col[2] + 128) >> 8),
                    };
                }
                if (do_sheen) {
                    const sw: u32 = self.disc_sheen[lut_row + px];
                    if (sw > 0) {
                        col = .{
                            @intCast(col[0] + (((255 - @as(u32, col[0])) * sw) >> 8)),
                            @intCast(col[1] + (((255 - @as(u32, col[1])) * sw) >> 8)),
                            @intCast(col[2] + (((255 - @as(u32, col[2])) * sw) >> 8)),
                        };
                    }
                }

                rgba[o] = col[0];
                rgba[o + 1] = col[1];
                rgba[o + 2] = col[2];
                rgba[o + 3] = a;
                u += du_dx;
                v += dv_dx;
            }
        }
    }

    fn drawGlow(
        self: *const Renderer,
        s: *Screen,
        cx: f32,
        cy: f32,
        rd: f32,
        rmax: f32,
        vis_rows: usize,
        k: f32,
        c1: [3]f32,
        c2: [3]f32,
        bgf: [3]f32,
    ) void {
        _ = c2;
        // Pure 100%-saturated hue extracted from the cover's dominant color (no white washout)
        const c_mn = @min(c1[0], @min(c1[1], c1[2]));
        const c_mx = @max(c1[0], @max(c1[1], c1[2]));
        const pure: [3]f32 = if (c_mx - c_mn > 2.0) blk: {
            const inv = 1.0 / (c_mx - c_mn);
            break :blk .{ (c1[0] - c_mn) * inv, (c1[1] - c_mn) * inv, (c1[2] - c_mn) * inv };
        } else .{ 0.45, 0.55, 1.0 }; // fallback hue for greyscale covers

        const bg_mx = @max(bgf[0], @max(bgf[1], bgf[2]));
        const target_v = std.math.clamp(bg_mx * 3.2, 64.0, 120.0);
        const sat_col = [3]f32{ pure[0] * target_v, pure[1] * target_v, pure[2] * target_v };

        const spread = @max(rmax * 0.85, rd * 1.35);
        const inv_spread = 1.0 / spread;
        const max_d = rd + spread * 2.2;
        const max_d2 = max_d * max_d;
        const inner_start = rd * 0.86;
        const intensity = self.kick_glow * 0.82;

        for (0..vis_rows) |r| {
            const dy = (@as(f32, @floatFromInt(r)) + 0.5) * k - cy;
            const dy2 = dy * dy;
            if (dy2 > max_d2) continue;
            for (0..s.cols) |c| {
                const dx = @as(f32, @floatFromInt(c)) + 0.5 - cx;
                const d2 = dx * dx + dy2;
                if (d2 > max_d2) continue;
                const d = @sqrt(d2);
                if (d < inner_start) continue;

                const rim_in = smoothstep(inner_start, rd * 1.02, d);
                const dist_out = @max(0.0, d - rd * 0.96);
                const t = dist_out * inv_spread;
                const falloff = @exp(-std.math.pow(f32, t, 1.55));
                const amt = std.math.clamp(intensity * rim_in * falloff, 0, 0.92);
                if (amt <= 0.002) continue;

                const col = toRgb(mix3(bgf, sat_col, amt));
                const cell = s.at(c, r);
                cell.bg = col;
                cell.fg = col;
            }
        }
    }

    /// Darkening storm-like aurora creeping inward from left & right screen edges on 20–80 Hz sub-bass.
    fn drawAurora(self: *const Renderer, s: *Screen, vis_rows: usize, fx_color: FxColorMode) void {
        if (s.cols < 4 or vis_rows < 2) return;
        const cols_f: f32 = @floatFromInt(s.cols);
        const rows_f: f32 = @floatFromInt(vis_rows);
        const max_span = @max(4.0, cols_f * 0.44);
        const inv_span = 1.0 / max_span;
        const phase = self.aurora_phase;
        const spec_col = pathBandColor(self.sub_dom_u);
        const storm_tint = [3]f32{ spec_col[0] * 0.30, spec_col[1] * 0.30, spec_col[2] * 0.30 };

        for (0..vis_rows) |r| {
            const ny = (@as(f32, @floatFromInt(r)) + 0.5) / rows_f;
            const sway_l = 0.5 + 0.30 * @sin(ny * 5.2 + phase * 1.1) + 0.20 * @sin(ny * 11.7 - phase * 1.9);
            const sway_r = 0.5 + 0.30 * @sin(ny * 5.6 - phase * 1.0 + 1.7) + 0.20 * @sin(ny * 11.1 + phase * 1.7);
            const reach_l = (0.28 + 0.72 * self.sub_l) * (0.62 + 0.58 * sway_l);
            const reach_r = (0.28 + 0.72 * self.sub_r) * (0.62 + 0.58 * sway_r);
            const vert_ripple_l = @sin(ny * 4.5 + phase) * 2.0;
            const vert_ripple_r = @sin(ny * 4.9 - phase * 1.1 + 1.3) * 2.0;

            for (0..s.cols) |c| {
                const edge_l = @as(f32, @floatFromInt(c)) * inv_span;
                const edge_r = @as(f32, @floatFromInt(s.cols - 1 - c)) * inv_span;
                if (edge_l > reach_l and edge_r > reach_r) continue;

                var dark: f32 = 0;
                if (self.sub_l > 0.004 and edge_l < reach_l) {
                    const mask = smoothstep(reach_l, 0.0, edge_l);
                    const ribbon = 0.65 + 0.35 * @sin(edge_l * 14.0 - phase * 2.4 + vert_ripple_l);
                    dark = @max(dark, self.sub_l * mask * ribbon);
                }
                if (self.sub_r > 0.004 and edge_r < reach_r) {
                    const mask = smoothstep(reach_r, 0.0, edge_r);
                    const ribbon = 0.65 + 0.35 * @sin(edge_r * 14.0 - phase * 2.2 + vert_ripple_r);
                    dark = @max(dark, self.sub_r * mask * ribbon);
                }
                const amt = std.math.clamp(dark * 0.94, 0.0, 0.95);
                if (amt <= 0.005) continue;

                const cell = s.at(c, r);
                const bg = switch (fx_color) {
                    .cover => blk: {
                        const scale = 1.0 - amt;
                        break :blk Rgb{
                            .r = @intFromFloat(@as(f32, @floatFromInt(cell.bg.r)) * scale),
                            .g = @intFromFloat(@as(f32, @floatFromInt(cell.bg.g)) * scale),
                            .b = @intFromFloat(@as(f32, @floatFromInt(cell.bg.b)) * scale),
                        };
                    },
                    .spectrum => toRgb(mix3(toF(cell.bg), storm_tint, amt)),
                };
                cell.bg = bg;
                if (cell.cp == ' ') cell.fg = bg;
            }
        }
    }

    fn drawRing(self: *Renderer, s: *Screen, p: *const Params, cx: f32, cy: f32, rd: f32, r0: f32, ring_h: f32, ring_min: f32, vis_rows: usize, c1: [3]f32, c2: [3]f32, bgf: [3]f32) void {
        _ = bgf;
        const k = p.aspect;
        const outer_max = r0 + ring_min + ring_h + 0.5;
        const r_lo: usize = @intFromFloat(@max(0, @floor((cy - outer_max) / k)));
        const r_hi: usize = @min(vis_rows, @as(usize, @intFromFloat(@ceil((cy + outer_max) / k))) + 1);
        const c_lo: usize = @intFromFloat(@max(0, @floor(cx - outer_max)));
        const c_hi: usize = @min(s.cols, @as(usize, @intFromFloat(@ceil(cx + outer_max))) + 1);
        const dot_bits = [4][2]u8{ .{ 0x01, 0x08 }, .{ 0x02, 0x10 }, .{ 0x04, 0x20 }, .{ 0x40, 0x80 } };
        const peak_w = k * 0.13;
        const path_w = k * 0.14;
        const white = [3]f32{ 255, 255, 255 };
        // Ellipsis 3-line colors: frequency palette (rebeccapurple/teal/yellow) or 3 tones of cover base color
        const band_low_col: Rgb = if (p.viz_color == .freq)
            .{ .r = 102, .g = 51, .b = 153 }
        else
            toRgb(mix3(c1, .{ 18, 12, 24 }, 0.42));
        const band_mid_col: Rgb = if (p.viz_color == .freq)
            .{ .r = 0, .g = 128, .b = 128 }
        else
            toRgb(c1);
        const band_high_col: Rgb = if (p.viz_color == .freq)
            .{ .r = 255, .g = 255, .b = 0 }
        else
            toRgb(mix3(c2, white, 0.52));

        var r = r_lo;
        while (r < r_hi) : (r += 1) {
            var c = c_lo;
            while (c < c_hi) : (c += 1) {
                // skip cells owned by the disc interior
                const ccx = @as(f32, @floatFromInt(c)) + 0.5 - cx;
                const ccy = (@as(f32, @floatFromInt(r)) + 0.5) * k - cy;
                const cd = @sqrt(ccx * ccx + ccy * ccy);
                if (cd < rd + k * 0.6 or cd > outer_max + k) continue;

                var bits: u8 = 0;
                var acc = [3]f32{ 0, 0, 0 };
                var lit: f32 = 0;
                // Layer priority per cell for ellipsis: 3 = bass (skyblue), 2 = mid (limegreen), 1 = high (crimson), 0 = band
                var cell_layer: u8 = 0;
                var path_acc = [3]f32{ 0, 0, 0 };
                var path_lit: f32 = 0;
                for (0..4) |j| {
                    for (0..2) |i| {
                        const dx = @as(f32, @floatFromInt(c)) + 0.25 + 0.5 * @as(f32, @floatFromInt(i)) - cx;
                        const dy = (@as(f32, @floatFromInt(r)) + 0.125 + 0.25 * @as(f32, @floatFromInt(j))) * k - cy;
                        const rho = @sqrt(dx * dx + dy * dy);
                        if (rho < r0) continue;
                        var th = std.math.atan2(dx, -dy);
                        if (th < 0) th += TAU;
                        const idx = @min(ANG - 1, @as(usize, @intFromFloat(th / TAU * ANG)));
                        const v = self.amp[idx];
                        const top = r0 + ring_min + v * ring_h;

                        var hit_layer: u8 = 0;
                        var hit_path = false;
                        if (p.peak_mode == .ellipsis or p.peak_mode == .ellipsis2) {
                            const prev_idx: usize = if (idx == 0) ANG - 1 else idx - 1;
                            const next_idx: usize = if (idx + 1 >= ANG) 0 else idx + 1;
                            const onCurve = struct {
                                inline fn f(arr: *const [ANG]f32, cur_i: usize, p_i: usize, n_i: usize, base: f32, scale: f32, half_w: f32, r_val: f32) bool {
                                    if (arr[cur_i] <= 0.01) return false;
                                    const rc = base + arr[cur_i] * scale;
                                    const rp = base + arr[p_i] * scale;
                                    const rn = base + arr[n_i] * scale;
                                    const mp = (rc + rp) * 0.5;
                                    const mn = (rc + rn) * 0.5;
                                    const lo = @min(rc, @min(mp, mn)) - half_w;
                                    const hi = @max(rc, @max(mp, mn)) + half_w;
                                    return r_val >= lo and r_val <= hi;
                                }
                            }.f;
                            const r_base = r0 + ring_min;
                            const arr_low = if (p.peak_mode == .ellipsis2) &self.ell2_low else &self.path_low;
                            const arr_mid = if (p.peak_mode == .ellipsis2) &self.ell2_mid else &self.path_mid;
                            const arr_high = if (p.peak_mode == .ellipsis2) &self.ell2_high else &self.path_high;
                            // Outlines only (no fill, no smoothed bands), priority: low > mid > high
                            if (onCurve(arr_low, idx, prev_idx, next_idx, r_base, ring_h, path_w, rho)) {
                                hit_layer = 3;
                            } else if (onCurve(arr_mid, idx, prev_idx, next_idx, r_base, ring_h, path_w, rho)) {
                                hit_layer = 2;
                            } else if (onCurve(arr_high, idx, prev_idx, next_idx, r_base, ring_h, path_w, rho)) {
                                hit_layer = 1;
                            }
                        } else if (p.peak_mode == .path) {
                            const prev_idx: usize = if (idx == 0) ANG - 1 else idx - 1;
                            const next_idx: usize = if (idx + 1 >= ANG) 0 else idx + 1;
                            const r_cur = r0 + ring_min + self.amp[idx] * ring_h;
                            const r_prev = r0 + ring_min + self.amp[prev_idx] * ring_h;
                            const r_next = r0 + ring_min + self.amp[next_idx] * ring_h;
                            const mid_prev = (r_cur + r_prev) * 0.5;
                            const mid_next = (r_cur + r_next) * 0.5;
                            const seg_lo = @min(r_cur, @min(mid_prev, mid_next)) - path_w;
                            const seg_hi = @max(r_cur, @max(mid_prev, mid_next)) + path_w;
                            if ((rho >= seg_lo and rho <= seg_hi) or rho <= r_cur) {
                                const pc: [3]f32 = if (p.viz_color == .freq) blk: {
                                    const right_side = th < std.math.pi;
                                    const t = if (right_side) th / std.math.pi else (TAU - th) / std.math.pi;
                                    const u = if (p.bass_top) t else 1.0 - t;
                                    break :blk pathBandColor(u);
                                } else blk: {
                                    const q = std.math.clamp((rho - r0) / ring_h, 0, 1);
                                    var bc = mix3(c1, c2, q);
                                    if (r_cur - rho < 0.6) bc = mix3(bc, white, 0.35);
                                    const dim = 0.55 + 0.45 * std.math.clamp(v * 1.4 + 0.2, 0, 1);
                                    break :blk .{ bc[0] * dim, bc[1] * dim, bc[2] * dim };
                                };
                                path_acc[0] += pc[0];
                                path_acc[1] += pc[1];
                                path_acc[2] += pc[2];
                                path_lit += 1;
                                hit_path = true;
                            }
                        }

                        var col: [3]f32 = undefined;
                        if (hit_path) {
                            bits |= dot_bits[j][i];
                            continue;
                        } else if (hit_layer > 0) {
                            bits |= dot_bits[j][i];
                            cell_layer = @max(cell_layer, hit_layer);
                            continue;
                        } else if (p.peak_mode != .peak) {
                            continue;
                        } else if (rho <= top) {
                            if (p.viz_color == .freq) {
                                const right_side = th < std.math.pi;
                                const t = if (right_side) th / std.math.pi else (TAU - th) / std.math.pi;
                                const u = if (p.bass_top) t else 1.0 - t;
                                col = pathBandColor(u);
                                const dim = 0.65 + 0.35 * std.math.clamp(v * 1.3 + 0.15, 0, 1);
                                col = .{ col[0] * dim, col[1] * dim, col[2] * dim };
                            } else {
                                const q = std.math.clamp((rho - r0) / ring_h, 0, 1);
                                col = mix3(c1, c2, q);
                                if (top - rho < 0.6) col = mix3(col, white, 0.35);
                                const dim = 0.55 + 0.45 * std.math.clamp(v * 1.4 + 0.2, 0, 1);
                                col = .{ col[0] * dim, col[1] * dim, col[2] * dim };
                            }
                        } else if (p.peak_mode == .peak) {
                            const pk = r0 + ring_min + self.peak[idx] * ring_h + peak_w * 1.5;
                            if (@abs(rho - pk) < peak_w and self.peak[idx] > v + 0.02) {
                                if (p.viz_color == .freq) {
                                    const right_side = th < std.math.pi;
                                    const t = if (right_side) th / std.math.pi else (TAU - th) / std.math.pi;
                                    const u = if (p.bass_top) t else 1.0 - t;
                                    col = mix3(pathBandColor(u), white, 0.45);
                                } else {
                                    col = mix3(c2, white, 0.5);
                                }
                            } else continue;
                        } else continue;
                        bits |= dot_bits[j][i];
                        acc[0] += col[0];
                        acc[1] += col[1];
                        acc[2] += col[2];
                        lit += 1;
                    }
                }
                if (bits == 0) continue;
                const cell = s.at(c, r);
                cell.cp = 0x2800 + @as(u21, bits);
                cell.fg = if (path_lit > 0)
                    toRgb(.{ path_acc[0] / path_lit, path_acc[1] / path_lit, path_acc[2] / path_lit })
                else switch (cell_layer) {
                    3 => band_low_col,
                    2 => band_mid_col,
                    1 => band_high_col,
                    else => toRgb(.{ acc[0] / lit, acc[1] / lit, acc[2] / lit }),
                };
            }
        }
    }

    fn drawInfo(
        self: *Renderer,
        s: *Screen,
        p: *const Params,
        vis_rows: usize,
        disc_col0: usize,
        disc_row0: usize,
        disc_cols: usize,
        disc_rows: usize,
        c1: [3]f32,
        c2: [3]f32,
        bg: Rgb,
    ) void {
        _ = self;
        _ = disc_row0;
        _ = disc_rows;
        const cols = s.cols;
        const snap = p.snap;
        const light = toRgb(mix3(c2, .{ 255, 255, 255 }, 0.6));
        const dim = toRgb(mix3(c1, .{ 150, 150, 150 }, 0.6));
        const faint = toRgb(mix3(.{ @floatFromInt(bg.r), @floatFromInt(bg.g), @floatFromInt(bg.b) }, .{ 160, 160, 160 }, 0.35));
        const warn_col = Rgb{ .r = 250, .g = 200, .b = 90 };
        var buf: [1024]u8 = undefined;

        const top_hud = p.show_fps or p.show_rpm or p.hud_msg.len > 0;
        if (p.show_fps) {
            const t = if (p.bpm > 0)
                std.fmt.bufPrint(&buf, " {d:.1} fps · {d:.1} rpm ({d:.0} bpm){s} ", .{ p.fps, p.rpm, p.bpm, if (p.hud_msg.len > 0) p.hud_msg else "" }) catch ""
            else
                std.fmt.bufPrint(&buf, " {d:.1} fps · {d:.1} rpm{s} ", .{ p.fps, p.rpm, if (p.hud_msg.len > 0) p.hud_msg else "" }) catch "";
            _ = s.text(0, 0, t, faint, false);
        } else if (p.hud_msg.len > 0) {
            _ = s.text(0, 0, p.hud_msg, light, true);
        } else if (p.show_rpm) {
            const t = std.fmt.bufPrint(&buf, " {d:.1} rpm ", .{p.rpm}) catch "";
            _ = s.text(0, 0, t, light, true);
        }
        if (p.kitty_warn) {
            const t = " Kitty graphics non supportato: solo visualizer Braille (--force-kitty) ";
            _ = s.text(0, if (top_hud) 1 else 0, t, warn_col, true);
        }
        if (!p.cava_ok) {
            const t = " cava non disponibile ";
            _ = s.text(cols -| t.len, 0, t, faint, false);
        }
        if (p.show_help) {
            const lines = [_][]const u8{
                " spazio  play/pausa",
                " n / p   traccia succ./prec.",
                " ← / →   seek ∓5s",
                " ↑ / ↓   volume ±1dB",
                " s / r   shuffle / repeat",
                " [ / ]   spin ∓5 RPM ({/} ∓1)",
                " v / 0   preset RPM / reset",
                " w       path/ellip/ellip2/peak",
                " t / k   viz 1:1/smooth / colori",
                " g       bagliore cassa on/off",
                " a       aurora sub-bass on/off",
                " c       colori fx cover/freq",
                " d / x   risoluzione / AA disco",
                " m       info auto/mostra/nascondi",
                " l       riflessi on/off",
                " b       sfondo tinta/nero",
                " i       inverti bassi su/giù",
                " f       mostra fps / rpm",
                " q       esci",
            };
            const help_w: usize = 31;
            const col_start: usize = if (disc_cols > 0 and cols >= disc_col0 + disc_cols + help_w + 1)
                cols - help_w - 1
            else if (disc_cols > 0 and disc_col0 >= help_w + 1)
                1
            else
                0;
            const row_start: usize = if (p.kitty_warn) 2 else if (top_hud) 1 else 0;
            for (lines, 0..) |l, i| _ = s.text(col_start, row_start + i, l, light, false);
        }

        if (vis_rows == s.rows or p.info_alpha <= 0.01) return;
        const ia = std.math.clamp(p.info_alpha, 0.0, 1.0);
        const r1 = vis_rows + 1;
        if (!snap.connected) {
            centeredAlpha(s, r1, "in attesa di cliamp... (avvia `cliamp` o lascia che vinyl lanci il demone)", dim, false, ia);
            return;
        }
        const title = if (snap.title.len > 0) snap.title.get() else std.fs.path.basename(snap.path.get());
        centeredAlpha(s, r1, title, light, true, ia);
        const sub = blk: {
            if (snap.artist.len > 0 and snap.album.len > 0)
                break :blk std.fmt.bufPrint(&buf, "{s} — {s}", .{ snap.artist.get(), snap.album.get() }) catch "";
            break :blk snap.artist.get();
        };
        centeredAlpha(s, r1 + 1, sub, dim, false, ia);

        if (!p.info_seekbar) return;

        const r3 = r1 + 2;
        if (r3 >= s.rows) return;
        var lb: [16]u8 = undefined;
        var rb: [16]u8 = undefined;
        const lt = fmtTime(&lb, p.position);
        const rt = if (snap.duration > 0) fmtTime(&rb, snap.duration) else "--:--";
        const icon: []const u8 = switch (snap.state) {
            .playing => "▶",
            .paused => "‖",
            else => "■",
        };
        var mb: [64]u8 = undefined;
        const modes = std.fmt.bufPrint(&mb, "{s}{s}  {d:.0}dB", .{
            if (snap.shuffle) "  shuf" else "",
            if (snap.repeat.len > 0 and !std.mem.eql(u8, snap.repeat.get(), "Off")) "  rep" else "",
            snap.volume,
        }) catch "";
        const bar_w: usize = @min(cols -| 30, 70);
        const total = 2 + lt.len + 1 + bar_w + 1 + rt.len;
        var c: usize = (cols -| total) / 2;
        c = s.textAlpha(c, r3, icon, light, true, ia);
        c = s.textAlpha(c + 1, r3, lt, dim, false, ia);
        c += 1;
        const frac: f64 = if (snap.duration > 0) std.math.clamp(p.position / snap.duration, 0, 1) else 0;
        const filled: usize = @intFromFloat(frac * @as(f64, @floatFromInt(bar_w)));
        for (0..bar_w) |i| {
            if (c >= cols) break;
            const cell = s.at(c, r3);
            const raw_fg = if (i < filled)
                toRgb(mix3(c1, c2, @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(@max(bar_w, 1)))))
            else if (i == filled)
                light
            else
                faint;
            cell.cp = if (i < filled) 0x2501 else if (i == filled) 0x25CF else 0x2500;
            cell.fg = if (ia >= 0.995) raw_fg else toRgb(mix3(toF(cell.bg), toF(raw_fg), ia));
            c += 1;
        }
        c = s.textAlpha(c + 1, r3, rt, dim, false, ia);
        _ = s.textAlpha(c, r3, modes, faint, false, ia);
    }
};

fn centeredAlpha(s: *Screen, r: usize, t: []const u8, fg: Rgb, bold: bool, alpha: f32) void {
    if (r >= s.rows or alpha <= 0.01) return;
    const n = std.unicode.utf8CountCodepoints(t) catch t.len;
    const c = (s.cols -| n) / 2;
    _ = s.textAlpha(c, r, t, fg, bold, alpha);
}

fn fmtTime(buf: []u8, secs: f64) []const u8 {
    const t: u64 = @intFromFloat(@max(0, secs));
    if (t >= 3600) return std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}", .{ t / 3600, (t / 60) % 60, t % 60 }) catch "";
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ t / 60, t % 60 }) catch "";
}

fn catmull(v: []const f32, x: f32) f32 {
    const i: isize = @intFromFloat(@floor(x));
    const t = x - @floor(x);
    const at = struct {
        fn f(arr: []const f32, j: isize) f32 {
            const jj: usize = @intCast(std.math.clamp(j, 0, @as(isize, @intCast(arr.len - 1))));
            return arr[jj];
        }
    }.f;
    const p0 = at(v, i - 1);
    const p1 = at(v, i);
    const p2 = at(v, i + 1);
    const p3 = at(v, i + 2);
    const t2 = t * t;
    const t3 = t2 * t;
    return 0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (-p0 + 3 * p1 - 3 * p2 + p3) * t3);
}

fn linSample(v: []const f32, x: f32) f32 {
    if (v.len == 0) return 0;
    if (v.len == 1) return v[0];
    const max_i: f32 = @floatFromInt(v.len - 1);
    const xc = std.math.clamp(x, 0, max_i);
    const idx0: usize = @intFromFloat(@floor(xc));
    const idx1: usize = @min(idx0 + 1, v.len - 1);
    const t = xc - @as(f32, @floatFromInt(idx0));
    return v[idx0] + (v[idx1] - v[idx0]) * t;
}

fn smoothstep(e0: f32, e1: f32, x: f32) f32 {
    if (e0 == e1) return if (x >= e1) 1 else 0;
    const t = std.math.clamp((x - e0) / (e1 - e0), 0, 1);
    return t * t * (3 - 2 * t);
}

/// Smooth color blend across the 3 frequency bands (full color in each band's core, smooth crossover between).
fn pathBandColor(u: f32) [3]f32 {
    const low = [3]f32{ 102, 51, 153 }; // rebeccapurple
    const mid = [3]f32{ 0, 128, 128 }; // teal
    const high = [3]f32{ 255, 255, 0 }; // yellow
    if (u <= 0.26) return low;
    if (u < 0.44) return mix3(low, mid, smoothstep(0.26, 0.44, u));
    if (u <= 0.56) return mid;
    if (u < 0.74) return mix3(mid, high, smoothstep(0.56, 0.74, u));
    return high;
}

inline fn mix1(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

inline fn mix3(a: [3]f32, b: [3]f32, t: f32) [3]f32 {
    return .{ a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t };
}

inline fn toF(c: Rgb) [3]f32 {
    return .{ @floatFromInt(c.r), @floatFromInt(c.g), @floatFromInt(c.b) };
}

inline fn toRgb(c: [3]f32) Rgb {
    return .{
        .r = @intFromFloat(std.math.clamp(c[0], 0, 255)),
        .g = @intFromFloat(std.math.clamp(c[1], 0, 255)),
        .b = @intFromFloat(std.math.clamp(c[2], 0, 255)),
    };
}

test "rasterizeDiscRgba produces transparent corners and spindle hole" {
    const alloc = std.testing.allocator;
    var r = Renderer{ .alloc = alloc };
    defer r.deinit();
    const img = try art.placeholder(alloc, 42);
    r.setImage(img);
    r.ensureTextures(128);

    const side: usize = 64;
    const rgba = try alloc.alloc(u8, side * side * 4);
    defer alloc.free(rgba);
    const snap = cliamp.Snapshot{};
    const p = Params{
        .aspect = 2.0,
        .angle = 0.5,
        .dt = 0.016,
        .left = &[_]f32{0} ** 16,
        .right = &[_]f32{0} ** 16,
        .snap = &snap,
        .position = 0,
        .sheen = true,
        .bass_top = false,
        .show_fps = false,
        .show_help = false,
        .fps = 60,
        .bg_mode = .tint,
        .cava_ok = true,
    };
    r.rasterizeDiscRgba(rgba, side, 20.0, 20.0, 10.0, 1.0, &p);

    // Top-left corner (0, 0) must be transparent
    try std.testing.expectEqual(@as(u8, 0), rgba[3]);
    // Center pixel (32, 32) inside spindle hole must be transparent
    const center_o = (32 * side + 32) * 4;
    try std.testing.expectEqual(@as(u8, 0), rgba[center_o + 3]);
    // Mid-radius pixel (48, 32) on disc body must be opaque
    const body_o = (32 * side + 48) * 4;
    try std.testing.expectEqual(@as(u8, 255), rgba[body_o + 3]);
}

test "render aligns Kitty disc with circular Braille ring without overlap" {
    const alloc = std.testing.allocator;
    var s = Screen.init(alloc);
    defer s.deinit();
    try s.resize(120, 40);

    var r = Renderer{ .alloc = alloc };
    defer r.deinit();
    r.setImage(try art.placeholder(alloc, 77));

    var enc = kitty.Encoder{ .alloc = alloc, .mode = .direct };
    defer enc.deinit();
    var kout: std.ArrayList(u8) = .empty;
    defer kout.deinit(alloc);

    const bars = [_]f32{0.6} ** 32;
    const snap = cliamp.Snapshot{};
    r.render(&s, .{
        .aspect = 2.0,
        .angle = 0.2,
        .dt = 0.016,
        .left = &bars,
        .right = &bars,
        .snap = &snap,
        .position = 12,
        .sheen = true,
        .bass_top = false,
        .show_fps = true,
        .show_help = true,
        .fps = 60.0,
        .bg_mode = .tint,
        .cava_ok = true,
        .kitty_enc = &enc,
        .kitty_out = &kout,
        .force_redraw = true,
    });

    try std.testing.expect(r.disc_active);
    try std.testing.expect(kout.items.len > 0);
    // Disc placement box is centered horizontally and vertically in vis_rows (36)
    try std.testing.expectEqual((120 - r.last_disc_cols) / 2, r.last_col0);
    try std.testing.expectEqual((36 - r.last_disc_rows) / 2, r.last_row0);

    // No non-space characters inside the disc circle
    const cx = @as(f32, @floatFromInt(r.last_col0)) + @as(f32, @floatFromInt(r.last_disc_cols)) * 0.5;
    const cy = (@as(f32, @floatFromInt(r.last_row0)) + @as(f32, @floatFromInt(r.last_disc_rows)) * 0.5) * 2.0;
    const rd = @min(@as(f32, @floatFromInt(r.last_disc_cols)), @as(f32, @floatFromInt(r.last_disc_rows)) * 2.0) * 0.5;
    var braille_count: usize = 0;
    for (0..36) |row| {
        for (0..120) |col| {
            const cp = s.at(col, row).cp;
            if (cp >= 0x2800 and cp <= 0x28FF) braille_count += 1;
            const dx = @as(f32, @floatFromInt(col)) + 0.5 - cx;
            const dy = (@as(f32, @floatFromInt(row)) + 0.5) * 2.0 - cy;
            if (@sqrt(dx * dx + dy * dy) < rd) {
                try std.testing.expectEqual(@as(u21, ' '), cp);
            }
        }
    }
    try std.testing.expect(braille_count > 40);
}

test "PeakMode.ellipsis draws 3-band colors and PeakMode.path draws skyblue 1:1 peaks" {
    const alloc = std.testing.allocator;
    var r = Renderer{ .alloc = alloc };
    defer r.deinit();
    r.setImage(try art.placeholder(alloc, 7));

    var s = Screen.init(alloc);
    defer s.deinit();
    try s.resize(120, 40);

    var snap = cliamp.Snapshot{ .connected = true, .state = .playing };
    const zero_bars = [_]f32{0.0} ** 16;
    const raw_bars = [_]f32{0.85} ** 16;

    r.render(&s, .{
        .aspect = 2.0,
        .angle = 0.0,
        .dt = 1.0 / 60.0,
        .left = &zero_bars,
        .right = &zero_bars,
        .raw_left = &raw_bars,
        .raw_right = &raw_bars,
        .snap = &snap,
        .position = 0,
        .sheen = false,
        .bass_top = false,
        .show_fps = false,
        .show_help = false,
        .fps = 60.0,
        .peak_mode = .ellipsis,
        .bg_mode = .black,
        .cava_ok = true,
    });

    var low_cells: usize = 0;
    var mid_cells: usize = 0;
    var high_cells: usize = 0;
    for (0..36) |row| {
        for (0..120) |col| {
            const cell = s.at(col, row);
            if (cell.cp >= 0x2800 and cell.cp <= 0x28FF) {
                if (cell.fg.r == 102 and cell.fg.g == 51 and cell.fg.b == 153) low_cells += 1;
                if (cell.fg.r == 0 and cell.fg.g == 128 and cell.fg.b == 128) mid_cells += 1;
                if (cell.fg.r == 255 and cell.fg.g == 255 and cell.fg.b == 0) high_cells += 1;
            }
        }
    }
    try std.testing.expect(low_cells > 20);
    try std.testing.expect(mid_cells > 10);
    try std.testing.expect(high_cells > 10);
    // bass_top = false => bass (path_low) is fatter at bottom (ANG/2) than top (0)
    try std.testing.expect(r.path_low[ANG / 2] > r.path_low[0] * 2.0);
    try std.testing.expect(r.path_high[0] > r.path_high[ANG / 2] * 2.0);

    // Inverting bass_top flips the reference poles for low and high ellipses
    r.render(&s, .{
        .aspect = 2.0,
        .angle = 0.0,
        .dt = 1.0 / 60.0,
        .left = &zero_bars,
        .right = &zero_bars,
        .raw_left = &raw_bars,
        .raw_right = &raw_bars,
        .snap = &snap,
        .position = 0,
        .sheen = false,
        .bass_top = true,
        .show_fps = false,
        .show_help = false,
        .fps = 60.0,
        .peak_mode = .ellipsis,
        .bg_mode = .black,
        .cava_ok = true,
    });
    try std.testing.expect(r.path_low[0] > r.path_low[ANG / 2] * 2.0);
    try std.testing.expect(r.path_high[ANG / 2] > r.path_high[0] * 2.0);

    // PeakMode.path renders 1:1 peaks partitioned into skyblue (bass), limegreen (mids), crimson (highs)
    r.render(&s, .{
        .aspect = 2.0,
        .angle = 0.0,
        .dt = 1.0 / 60.0,
        .left = &zero_bars,
        .right = &zero_bars,
        .raw_left = &raw_bars,
        .raw_right = &raw_bars,
        .snap = &snap,
        .position = 0,
        .sheen = false,
        .bass_top = false,
        .show_fps = false,
        .show_help = false,
        .fps = 60.0,
        .peak_mode = .path,
        .bg_mode = .black,
        .cava_ok = true,
    });
    var path_low: usize = 0;
    var path_mid: usize = 0;
    var path_high: usize = 0;
    for (0..36) |row| {
        for (0..120) |col| {
            const cell = s.at(col, row);
            if (cell.cp >= 0x2800 and cell.cp <= 0x28FF) {
                if (cell.fg.r == 102 and cell.fg.g == 51 and cell.fg.b == 153) path_low += 1;
                if (cell.fg.r == 0 and cell.fg.g == 128 and cell.fg.b == 128) path_mid += 1;
                if (cell.fg.r == 255 and cell.fg.g == 255 and cell.fg.b == 0) path_high += 1;
            }
        }
    }
    try std.testing.expect(path_low > 10);
    try std.testing.expect(path_mid > 10);
    try std.testing.expect(path_high > 10);
}

test "kick sidechain glow reacts stronger to sudden 100-300Hz hits and radiates past disc" {
    const alloc = std.testing.allocator;
    var r = Renderer{ .alloc = alloc };
    defer r.deinit();
    r.setImage(try art.placeholder(alloc, 11));

    var s = Screen.init(alloc);
    defer s.deinit();
    try s.resize(120, 40);

    var snap = cliamp.Snapshot{ .connected = true, .state = .playing };
    const zero_bars = [_]f32{0.0} ** 48;
    var kick_bars = [_]f32{0.0} ** 48;
    // 100-300Hz maps to u in [0.22, 0.41] on 20-16000Hz log scale => indices ~11..19 for 48 bars
    for (11..20) |i| kick_bars[i] = 0.95;

    // Sudden kick hit from silence
    r.render(&s, .{
        .aspect = 2.0,
        .angle = 0.0,
        .dt = 1.0 / 60.0,
        .left = &zero_bars,
        .right = &zero_bars,
        .raw_left = &kick_bars,
        .raw_right = &kick_bars,
        .snap = &snap,
        .position = 0,
        .sheen = false,
        .bass_top = false,
        .show_fps = false,
        .show_help = false,
        .fps = 60.0,
        .peak_mode = .path,
        .glow = true,
        .bg_mode = .black,
        .cava_ok = true,
    });
    const sudden_glow = r.kick_glow;
    try std.testing.expect(sudden_glow > 0.3);

    // Cells well outside the disc should be brightened above black (6,6,8)
    const far_cell = s.at(15, 18);
    try std.testing.expect(far_cell.bg.r > 12 or far_cell.bg.g > 12 or far_cell.bg.b > 12);

    // Sustained kick of the same loudness settles to a lower glow than the initial sudden hit
    for (0..60) |_| {
        r.render(&s, .{
            .aspect = 2.0,
            .angle = 0.0,
            .dt = 1.0 / 60.0,
            .left = &zero_bars,
            .right = &zero_bars,
            .raw_left = &kick_bars,
            .raw_right = &kick_bars,
            .snap = &snap,
            .position = 0,
            .sheen = false,
            .bass_top = false,
            .show_fps = false,
            .show_help = false,
            .fps = 60.0,
            .peak_mode = .path,
            .glow = true,
            .bg_mode = .black,
            .cava_ok = true,
        });
    }
    try std.testing.expect(r.kick_glow < sudden_glow);
}

test "sub-bass storm aurora darkens screen edges on 20-80Hz rumble" {
    const alloc = std.testing.allocator;
    var r = Renderer{ .alloc = alloc };
    defer r.deinit();
    r.setImage(try art.placeholder(alloc, 19));

    var s = Screen.init(alloc);
    defer s.deinit();
    try s.resize(120, 40);

    var snap = cliamp.Snapshot{ .connected = true, .state = .playing };
    const zero_bars = [_]f32{0.0} ** 48;
    var sub_bars = [_]f32{0.0} ** 48;
    for (0..10) |i| sub_bars[i] = 1.0; // 20-80Hz sub-bass

    // Baseline background without aurora
    r.render(&s, .{
        .aspect = 2.0,
        .angle = 0.0,
        .dt = 1.0 / 60.0,
        .left = &zero_bars,
        .right = &zero_bars,
        .raw_left = &zero_bars,
        .raw_right = &zero_bars,
        .snap = &snap,
        .position = 0,
        .sheen = false,
        .bass_top = false,
        .show_fps = false,
        .show_help = false,
        .fps = 60.0,
        .peak_mode = .path,
        .glow = false,
        .aurora = true,
        .bg_mode = .tint,
        .cava_ok = true,
    });
    const base_l = s.at(0, 18).bg;
    const base_r = s.at(119, 18).bg;

    // Pulse sub-bass for several frames and verify both side edges darken
    for (0..6) |_| {
        r.render(&s, .{
            .aspect = 2.0,
            .angle = 0.0,
            .dt = 1.0 / 60.0,
            .left = &zero_bars,
            .right = &zero_bars,
            .raw_left = &sub_bars,
            .raw_right = &sub_bars,
            .snap = &snap,
            .position = 0,
            .sheen = false,
            .bass_top = false,
            .show_fps = false,
            .show_help = false,
            .fps = 60.0,
            .peak_mode = .path,
            .glow = false,
            .aurora = true,
            .bg_mode = .tint,
            .cava_ok = true,
        });
    }
    const dark_l = s.at(0, 18).bg;
    const dark_r = s.at(119, 18).bg;
    try std.testing.expect(r.sub_l > 0.5 and r.sub_r > 0.5);
    try std.testing.expect(dark_l.r <= base_l.r and dark_l.g <= base_l.g and dark_l.b <= base_l.b);
    try std.testing.expect(dark_l.r < base_l.r or dark_l.g < base_l.g or dark_l.b < base_l.b);
    try std.testing.expect(dark_r.r < base_r.r or dark_r.g < base_r.g or dark_r.b < base_r.b);
}
