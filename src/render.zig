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
    data: []f32 = &.{}, // size*size*3

    fn deinit(self: *Texture, alloc: std.mem.Allocator) void {
        alloc.free(self.data);
        self.* = .{};
    }

    /// Area-resample the 512x512 source into a `size`x`size` float texture.
    fn build(self: *Texture, alloc: std.mem.Allocator, img: *const art.Image, size: usize) !void {
        self.deinit(alloc);
        self.size = size;
        self.data = try alloc.alloc(f32, size * size * 3);
        const s: f32 = @as(f32, art.SRC) / @as(f32, @floatFromInt(size));
        for (0..size) |y| {
            const y0: usize = @intFromFloat(@floor(@as(f32, @floatFromInt(y)) * s));
            const y1: usize = @max(y0 + 1, @min(art.SRC, @as(usize, @intFromFloat(@floor(@as(f32, @floatFromInt(y + 1)) * s)))));
            for (0..size) |x| {
                const x0: usize = @intFromFloat(@floor(@as(f32, @floatFromInt(x)) * s));
                const x1: usize = @max(x0 + 1, @min(art.SRC, @as(usize, @intFromFloat(@floor(@as(f32, @floatFromInt(x + 1)) * s)))));
                var acc = [3]f32{ 0, 0, 0 };
                var yy = y0;
                while (yy < y1) : (yy += 1) {
                    var xx = x0;
                    while (xx < x1) : (xx += 1) {
                        const i = (yy * art.SRC + xx) * 3;
                        acc[0] += @floatFromInt(img.px[i]);
                        acc[1] += @floatFromInt(img.px[i + 1]);
                        acc[2] += @floatFromInt(img.px[i + 2]);
                    }
                }
                const n: f32 = @floatFromInt((y1 - y0) * (x1 - x0));
                const o = (y * size + x) * 3;
                self.data[o] = acc[0] / n;
                self.data[o + 1] = acc[1] / n;
                self.data[o + 2] = acc[2] / n;
            }
        }
    }

    /// Bilinear sample, u/v in [-1, 1].
    inline fn sample(self: *const Texture, u: f32, v: f32) [3]f32 {
        const fs: f32 = @floatFromInt(self.size - 1);
        const fx = std.math.clamp((u + 1) * 0.5 * fs, 0, fs);
        const fy = std.math.clamp((v + 1) * 0.5 * fs, 0, fs);
        const x0: usize = @intFromFloat(fx);
        const y0: usize = @intFromFloat(fy);
        const x1 = @min(x0 + 1, self.size - 1);
        const y1 = @min(y0 + 1, self.size - 1);
        const tx = fx - @as(f32, @floatFromInt(x0));
        const ty = fy - @as(f32, @floatFromInt(y0));
        const a = self.data[(y0 * self.size + x0) * 3 ..][0..3];
        const b = self.data[(y0 * self.size + x1) * 3 ..][0..3];
        const c = self.data[(y1 * self.size + x0) * 3 ..][0..3];
        const d = self.data[(y1 * self.size + x1) * 3 ..][0..3];
        var out: [3]f32 = undefined;
        inline for (0..3) |k| {
            const top = a[k] + (b[k] - a[k]) * tx;
            const bot = c[k] + (d[k] - c[k]) * tx;
            out[k] = top + (bot - top) * ty;
        }
        return out;
    }
};

pub const BgMode = enum { tint, black };
pub const PeakMode = enum { path, peak };

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
    rpm: f32 = 33.333,
    show_rpm: bool = false,
    peak_mode: PeakMode = .path,
    glow: bool = true,
    hud_msg: []const u8 = "",
    bg_mode: BgMode,
    cava_ok: bool,
    kitty_enc: ?*kitty.Encoder = null,
    kitty_out: ?*std.ArrayList(u8) = null,
    kitty_warn: bool = false,
    force_redraw: bool = false,
};

pub const Renderer = struct {
    alloc: std.mem.Allocator,
    img: ?*art.Image = null,
    old_img: ?*art.Image = null,
    tex: Texture = .{},
    old_tex: Texture = .{},
    fade: f32 = 1.0,
    amp: [ANG]f32 = [_]f32{0} ** ANG,
    path_low: [ANG]f32 = [_]f32{0} ** ANG,
    path_mid: [ANG]f32 = [_]f32{0} ** ANG,
    path_high: [ANG]f32 = [_]f32{0} ** ANG,
    peak: [ANG]f32 = [_]f32{0} ** ANG,
    kick_avg: f32 = 0,
    kick_glow: f32 = 0,
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

    pub fn deinit(self: *Renderer) void {
        self.tex.deinit(self.alloc);
        self.old_tex.deinit(self.alloc);
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
        const decay = p.dt * 0.55;

        // 1:1 raw band energies (low / mid / high) per channel, zero temporal smoothing
        var low_l: f32 = 0;
        var low_r: f32 = 0;
        var low_w: f32 = 0;
        var mid_l: f32 = 0;
        var mid_r: f32 = 0;
        var mid_w: f32 = 0;
        var high_l: f32 = 0;
        var high_r: f32 = 0;
        var high_w: f32 = 0;
        // Kick drum band: 100Hz–300Hz on cava's 40Hz–16000Hz log scale => u in [0.153, 0.336]
        var kick_sum: f32 = 0;
        var kick_cnt: f32 = 0;
        for (0..n) |i| {
            const u = if (n > 1) @as(f32, @floatFromInt(i)) / nf else 0.0;
            if (u >= 0.14 and u <= 0.35) {
                kick_sum += 0.5 * (raw_l[i] + raw_r[i]);
                kick_cnt += 1.0;
            }
            const dl = (u - 0.12) / 0.20;
            const dm = (u - 0.50) / 0.22;
            const dh = (u - 0.86) / 0.20;
            const wl = @exp(-(dl * dl));
            const wm = @exp(-(dm * dm));
            const wh = @exp(-(dh * dh));
            low_l += raw_l[i] * wl;
            low_r += raw_r[i] * wl;
            low_w += wl;
            mid_l += raw_l[i] * wm;
            mid_r += raw_r[i] * wm;
            mid_w += wm;
            high_l += raw_l[i] * wh;
            high_r += raw_r[i] * wh;
            high_w += wh;
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

        for (0..ANG) |a| {
            const th = (@as(f32, @floatFromInt(a)) + 0.5) / ANG * TAU;
            const right_side = th < std.math.pi;
            const t = if (right_side) th / std.math.pi else (TAU - th) / std.math.pi; // 0 top, 1 bottom
            const u = if (p.bass_top) t else 1.0 - t; // 0 = bass pole, 0.5 = mid sides, 1 = high pole
            const fpos = u * nf;
            const vr = catmull(p.right, fpos);
            const vl = catmull(p.left, fpos);
            const s = smoothstep(0, 0.12, @min(t, 1 - t));
            const own = 0.5 + 0.5 * s;
            var v = if (right_side) vr * own + vl * (1 - own) else vl * own + vr * (1 - own);
            v = std.math.clamp(v, 0, 1);
            self.amp[a] = v;
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

            const raw_here = std.math.clamp(if (right_side) linSample(raw_r, fpos) else linSample(raw_l, fpos), 0, 1);
            const deform = 0.88 + 0.22 * raw_here;

            const ell_low = el * env_low * deform * 1.15;
            const ell_mid = em * env_mid * deform * 1.15;
            const ell_high = eh * env_high * deform * 1.15;

            // Union with direct 1:1 raw frequency peaks, partitioned by frequency zone (follows bass_top)
            const mask_low = 1.0 - smoothstep(0.32, 0.48, u);
            const mask_mid = smoothstep(0.22, 0.36, u) * (1.0 - smoothstep(0.64, 0.78, u));
            const mask_high = smoothstep(0.52, 0.68, u);

            self.path_low[a] = std.math.clamp(@max(ell_low, raw_here * mask_low), 0, 1.0);
            self.path_mid[a] = std.math.clamp(@max(ell_mid, raw_here * mask_mid), 0, 1.0);
            self.path_high[a] = std.math.clamp(@max(ell_high, raw_here * mask_high), 0, 1.0);
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
                self.drawGlow(s, cx, cy, rd, rmax, vis_rows, k, pal.c1, pal.c2, bgf);
            }
            self.drawRing(s, &p, cx, cy, rd, r0, ring_h, ring_min, vis_rows, pal.c1, pal.c2, bgf);

            if (p.kitty_enc) |enc| {
                const side: usize = std.math.clamp(disc_cols * 6, 96, 320) & ~@as(usize, 1);
                self.ensureTextures(@min(art.SRC, side * 2));
                if (self.img != null and self.tex.size > 0) {
                    const dirty = p.force_redraw or !self.disc_active or
                        self.last_col0 != disc_col0 or self.last_row0 != disc_row0 or
                        self.last_disc_cols != disc_cols or self.last_disc_rows != disc_rows or
                        self.last_side != side or @abs(self.last_aspect - k) > 1e-4 or
                        self.last_img_gen != self.img_gen or self.last_sheen != p.sheen or
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

    pub fn rasterizeDiscRgba(
        self: *const Renderer,
        rgba: []u8,
        side: usize,
        box_w: f32,
        box_h: f32,
        rd: f32,
        rh: f32,
        p: *const Params,
    ) void {
        const ca = @cos(p.angle);
        const sa = @sin(p.angle);
        const inv_rd = 1.0 / rd;
        const inv_side = 1.0 / @as(f32, @floatFromInt(side));
        const px_step = @max(box_w, box_h) * inv_side;
        const aa_half = px_step * 0.75;
        const outer_hi = rd + aa_half;
        const outer_lo = rd - aa_half;
        const outer_hi2 = outer_hi * outer_hi;
        const inner_lo = @max(0.0, rh - aa_half);
        const inner_hi = rh + aa_half;
        const use_old = self.fade < 1.0 and self.old_img != null and self.old_tex.size == self.tex.size;

        // cos(0.85) and sin(0.85) for fast specular sheen without atan2
        const sheen_cx: f32 = 0.65998315;
        const sheen_sy: f32 = 0.7512804;

        for (0..side) |py| {
            const ny = ((@as(f32, @floatFromInt(py)) + 0.5) * inv_side - 0.5) * box_h;
            const ny2 = ny * ny;
            const row_off = py * side * 4;
            for (0..side) |px| {
                const nx = ((@as(f32, @floatFromInt(px)) + 0.5) * inv_side - 0.5) * box_w;
                const d2 = nx * nx + ny2;
                const o = row_off + px * 4;
                if (d2 >= outer_hi2) {
                    rgba[o] = 0;
                    rgba[o + 1] = 0;
                    rgba[o + 2] = 0;
                    rgba[o + 3] = 0;
                    continue;
                }
                const rho = @sqrt(d2);
                if (rho <= inner_lo) {
                    rgba[o] = 0;
                    rgba[o + 1] = 0;
                    rgba[o + 2] = 0;
                    rgba[o + 3] = 0;
                    continue;
                }

                const outer_a = if (rho <= outer_lo) 1.0 else smoothstep(outer_hi, outer_lo, rho);
                const inner_a = if (rho >= inner_hi) 1.0 else smoothstep(inner_lo, inner_hi, rho);
                const alpha = outer_a * inner_a;

                const u = (nx * ca + ny * sa) * inv_rd;
                const v = (-nx * sa + ny * ca) * inv_rd;
                var col = self.tex.sample(u, v);
                if (use_old) col = mix3(self.old_tex.sample(u, v), col, self.fade);

                const rn = rho * inv_rd;

                if (p.sheen and rho > 1e-4) {
                    const cphi = (nx * sheen_cx + ny * sheen_sy) / rho;
                    const c2 = cphi * cphi;
                    const c6 = c2 * c2 * c2;
                    const w = c6 * c6 * 0.17 * smoothstep(0.10, 0.40, rn);
                    col = .{
                        col[0] + (255.0 - col[0]) * w,
                        col[1] + (255.0 - col[1]) * w,
                        col[2] + (255.0 - col[2]) * w,
                    };
                }

                rgba[o] = @intFromFloat(std.math.clamp(col[0], 0, 255));
                rgba[o + 1] = @intFromFloat(std.math.clamp(col[1], 0, 255));
                rgba[o + 2] = @intFromFloat(std.math.clamp(col[2], 0, 255));
                rgba[o + 3] = @intFromFloat(std.math.clamp(alpha * 255.0, 0, 255));
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
        const glow_col = mix3(mix3(c1, c2, 0.5), .{ 255, 255, 255 }, 0.38);
        const spread = @max(rmax * 0.85, rd * 1.35);
        const inv_spread = 1.0 / spread;
        const max_d = rd + spread * 2.2;
        const max_d2 = max_d * max_d;
        const inner_start = rd * 0.86;
        const intensity = self.kick_glow * 0.56;

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
                const amt = std.math.clamp(intensity * rim_in * falloff, 0, 0.82);
                if (amt <= 0.002) continue;

                const col = toRgb(mix3(bgf, glow_col, amt));
                const cell = s.at(c, r);
                cell.bg = col;
                cell.fg = col;
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
        const skyblue = Rgb{ .r = 135, .g = 206, .b = 235 };
        const limegreen = Rgb{ .r = 50, .g = 205, .b = 50 };
        const crimson = Rgb{ .r = 220, .g = 20, .b = 60 };

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
                // Layer priority per cell: 3 = bass (skyblue), 2 = mid (limegreen), 1 = high (crimson), 0 = band
                var cell_layer: u8 = 0;
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
                        if (p.peak_mode == .path) {
                            const r_low = r0 + ring_min + self.path_low[idx] * ring_h;
                            const r_mid = r0 + ring_min + self.path_mid[idx] * ring_h;
                            const r_high = r0 + ring_min + self.path_high[idx] * ring_h;
                            const has_low = self.path_low[idx] > 0.01;
                            const has_mid = self.path_mid[idx] > 0.01;
                            const has_high = self.path_high[idx] > 0.01;

                            if (rho > top) {
                                // Fill gaps in priority order: bass (skyblue) > mids (limegreen) > highs (crimson)
                                if (has_low and rho <= r_low + path_w) {
                                    hit_layer = 3;
                                } else if (has_mid and rho <= r_mid + path_w) {
                                    hit_layer = 2;
                                } else if (has_high and rho <= r_high + path_w) {
                                    hit_layer = 1;
                                }
                            } else {
                                // Inside smoothed band: overlay contour lines in priority order
                                if (has_low and @abs(rho - r_low) <= path_w) {
                                    hit_layer = 3;
                                } else if (has_mid and @abs(rho - r_mid) <= path_w) {
                                    hit_layer = 2;
                                } else if (has_high and @abs(rho - r_high) <= path_w) {
                                    hit_layer = 1;
                                }
                            }
                        }

                        var col: [3]f32 = undefined;
                        if (hit_layer > 0) {
                            bits |= dot_bits[j][i];
                            cell_layer = @max(cell_layer, hit_layer);
                            continue;
                        } else if (rho <= top) {
                            const q = std.math.clamp((rho - r0) / ring_h, 0, 1);
                            col = mix3(c1, c2, q);
                            if (top - rho < 0.6) col = mix3(col, white, 0.35);
                            const dim = 0.55 + 0.45 * std.math.clamp(v * 1.4 + 0.2, 0, 1);
                            col = .{ col[0] * dim, col[1] * dim, col[2] * dim };
                        } else if (p.peak_mode == .peak) {
                            const pk = r0 + ring_min + self.peak[idx] * ring_h + peak_w * 1.5;
                            if (@abs(rho - pk) < peak_w and self.peak[idx] > v + 0.02) {
                                col = mix3(c2, white, 0.5);
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
                cell.fg = switch (cell_layer) {
                    3 => skyblue,
                    2 => limegreen,
                    1 => crimson,
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
            const t = std.fmt.bufPrint(&buf, " {d:.1} fps · {d:.1} rpm{s} ", .{ p.fps, p.rpm, if (p.hud_msg.len > 0) p.hud_msg else "" }) catch "";
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
                " w       path 1:1 / peak",
                " g       bagliore cassa on/off",
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

        if (vis_rows == s.rows) return;
        const r1 = vis_rows + 1;
        if (!snap.connected) {
            centered(s, r1, "in attesa di cliamp... (avvia `cliamp` o lascia che vinyl lanci il demone)", dim, false);
            return;
        }
        const title = if (snap.title.len > 0) snap.title.get() else std.fs.path.basename(snap.path.get());
        centered(s, r1, title, light, true);
        const sub = blk: {
            if (snap.artist.len > 0 and snap.album.len > 0)
                break :blk std.fmt.bufPrint(&buf, "{s} — {s}", .{ snap.artist.get(), snap.album.get() }) catch "";
            break :blk snap.artist.get();
        };
        centered(s, r1 + 1, sub, dim, false);

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
        c = s.text(c, r3, icon, light, true);
        c = s.text(c + 1, r3, lt, dim, false);
        c += 1;
        const frac: f64 = if (snap.duration > 0) std.math.clamp(p.position / snap.duration, 0, 1) else 0;
        const filled: usize = @intFromFloat(frac * @as(f64, @floatFromInt(bar_w)));
        for (0..bar_w) |i| {
            if (c >= cols) break;
            const cell = s.at(c, r3);
            if (i < filled) {
                cell.cp = 0x2501; // ━
                cell.fg = toRgb(mix3(c1, c2, @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(@max(bar_w, 1)))));
            } else if (i == filled) {
                cell.cp = 0x25CF; // ●
                cell.fg = light;
            } else {
                cell.cp = 0x2500; // ─
                cell.fg = faint;
            }
            c += 1;
        }
        c = s.text(c + 1, r3, rt, dim, false);
        _ = s.text(c, r3, modes, faint, false);
    }
};

fn centered(s: *Screen, r: usize, t: []const u8, fg: Rgb, bold: bool) void {
    if (r >= s.rows) return;
    const n = std.unicode.utf8CountCodepoints(t) catch t.len;
    const c = (s.cols -| n) / 2;
    _ = s.text(c, r, t, fg, bold);
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

test "PeakMode.path draws skyblue 1:1 path from raw spectrum without smoothing" {
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
        .peak_mode = .path,
        .bg_mode = .black,
        .cava_ok = true,
    });

    var skyblue_cells: usize = 0;
    var lime_cells: usize = 0;
    var crimson_cells: usize = 0;
    for (0..36) |row| {
        for (0..120) |col| {
            const cell = s.at(col, row);
            if (cell.cp >= 0x2800 and cell.cp <= 0x28FF) {
                if (cell.fg.r == 135 and cell.fg.g == 206 and cell.fg.b == 235) skyblue_cells += 1;
                if (cell.fg.r == 50 and cell.fg.g == 205 and cell.fg.b == 50) lime_cells += 1;
                if (cell.fg.r == 220 and cell.fg.g == 20 and cell.fg.b == 60) crimson_cells += 1;
            }
        }
    }
    try std.testing.expect(skyblue_cells > 20);
    try std.testing.expect(lime_cells > 10);
    try std.testing.expect(crimson_cells > 10);
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
        .peak_mode = .path,
        .bg_mode = .black,
        .cava_ok = true,
    });
    try std.testing.expect(r.path_low[0] > r.path_low[ANG / 2] * 2.0);
    try std.testing.expect(r.path_high[ANG / 2] > r.path_high[0] * 2.0);
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
    // 100-300Hz maps to u in [0.14, 0.35] => indices ~7..16 for 48 bars
    for (7..17) |i| kick_bars[i] = 0.95;

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
