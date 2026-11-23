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
const MAX_STARS = 240;
const MAX_FILAMENTS = 24;
const MAX_KICK_RINGS = 12;

const KickRing = struct {
    age: f32 = 0,
    max_life: f32 = 1.15,
    strength: f32 = 0,
    dom_u: f32 = 0.34,
    active: bool = false,
};

const Filament = struct {
    x0: f32 = 0.5, // horizontal center in [0.14, 0.86]
    y_head: f32 = 1.0, // leading tip stretching upward from y_base
    y_base: f32 = 1.0, // anchored bottom origin
    max_life: f32 = 1.8, // total lifetime before fadeout completes
    width: f32 = 0.8, // thin thickness in Braille sub-dot units
    sway: f32 = 0.03, // horizontal wave amplitude
    freq: f32 = 9.0, // vertical wave spatial frequency
    speed: f32 = 0.65, // upward elongation speed (screen heights / sec)
    wave_speed: f32 = 7.5, // phase oscillation speed driven by mid pitch
    phase: f32 = 0,
    age: f32 = 0,
    strength: f32 = 0,
    active: bool = false,
};

const Star = struct {
    x: f32 = 0, // normalized 0..1 across screen
    y: f32 = 0, // normalized 0..1 across screen
    life: f32 = 0,
    max_life: f32 = 1,
    peak: f32 = 0,
    kind: u8 = 0,
    phase: f32 = 0,
};

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
pub const VizLayout = enum { circular, linear, off };
pub const VizMotion = enum { raw, smooth };
pub const VizColor = enum { freq, cover };
pub const FxColorMode = enum { cover, spectrum };
pub const RingMode = enum { off, kick, mid };
pub const InfoMode = enum { auto, show, hide };
pub const DiscStyle = enum {
    cover,
    vinyl,
    vinyl_art,
    cd,

    pub fn label(self: DiscStyle) []const u8 {
        return switch (self) {
            .cover => " disc: cover ",
            .vinyl => " disc: vinyl ",
            .vinyl_art => " disc: vinyl art ",
            .cd => " disc: CD ",
        };
    }
};
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
    viz_layout: VizLayout = .circular,
    viz_motion: VizMotion = .raw,
    viz_color: VizColor = .freq,
    glow: bool = true,
    aurora: bool = true,
    star_level: u8 = 3,
    wave_level: u8 = 4,
    ring_mode: RingMode = .off,
    glow_gain: f32 = 1.0,
    aurora_gain: f32 = 1.0,
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
    disc_style: DiscStyle = .cover,
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
    air_avg: f32 = 0,
    star_rng: u32 = 0x9E3779B9,
    star_accum: f32 = 0,
    star_cd: f32 = 0,
    stars: [MAX_STARS]Star = [_]Star{.{}} ** MAX_STARS,
    mid_hold: f32 = 0,
    mid_sustain: f32 = 0,
    fil_accum: f32 = 0,
    filaments: [MAX_FILAMENTS]Filament = [_]Filament{.{}} ** MAX_FILAMENTS,
    kick_ring_cd: f32 = 0,
    vocal_avg: f32 = 0,
    vocal_ring_cd: f32 = 0,
    kick_rings_pool: [MAX_KICK_RINGS]KickRing = [_]KickRing{.{}} ** MAX_KICK_RINGS,
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
    last_style: DiscStyle = .cover,

    // precomputed per-pixel circular mask, zone, grooves/plastic & static sheen LUT (rebuilt only on geometry/AA/style change)
    lut_side: usize = 0,
    lut_box_w: f32 = 0,
    lut_box_h: f32 = 0,
    lut_rd: f32 = 0,
    lut_rh: f32 = 0,
    lut_aa: bool = true,
    lut_style: DiscStyle = .cover,
    disc_alpha: []u8 = &.{},
    disc_sheen: []u8 = &.{},
    disc_zone: []u8 = &.{}, // 0=empty, 1=art(1x), 2=art(label), 3=static gray/plastic, 4=vinyl label
    disc_gray: []u8 = &.{},

    pub fn deinit(self: *Renderer) void {
        self.tex.deinit(self.alloc);
        self.old_tex.deinit(self.alloc);
        if (self.disc_alpha.len > 0) self.alloc.free(self.disc_alpha);
        if (self.disc_sheen.len > 0) self.alloc.free(self.disc_sheen);
        if (self.disc_zone.len > 0) self.alloc.free(self.disc_zone);
        if (self.disc_gray.len > 0) self.alloc.free(self.disc_gray);
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
        // Ultra-high frequencies (~10–16 kHz, u >= 0.93) vs tonal mid-highs (~1.2–5.5 kHz, u in [0.60, 0.85])
        // Comparing air vs tonal_hi rejects loud brass/trumpets/vocals whose upper harmonics bleed past 10 kHz
        var air_l_sum: f32 = 0;
        var air_r_sum: f32 = 0;
        var air_cnt: f32 = 0;
        var tonal_hi_sum: f32 = 0;
        var tonal_hi_cnt: f32 = 0;
        // Musical mid-range (~300 Hz – 2.2 kHz, u in [0.40, 0.72]): piano, trumpet, saxophone
        var sus_l_sum: f32 = 0;
        var sus_r_sum: f32 = 0;
        var sus_u_num: f32 = 0;
        var sus_u_den: f32 = 0;
        var sus_cnt: f32 = 0;
        // Singing vocal presence band (~700 Hz – 3.5 kHz, u in [0.52, 0.77]) weighted for center-panned voice (L ≈ R)
        var voc_sum: f32 = 0;
        var voc_u_num: f32 = 0;
        var voc_u_den: f32 = 0;
        var voc_cnt: f32 = 0;
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
            if (u >= 0.40 and u <= 0.72) {
                sus_l_sum += raw_l[i];
                sus_r_sum += raw_r[i];
                sus_u_num += u * mono;
                sus_u_den += mono;
                sus_cnt += 1.0;
            }
            if (u >= 0.38 and u <= 0.77) {
                // Spoken & sung voice (~250 Hz – 3.5 kHz): center-biased (L ≈ R) with gentle side rejection for stereo reverb
                const center = @min(raw_l[i], raw_r[i]);
                const side = @abs(raw_l[i] - raw_r[i]);
                const vbar = @max(0.0, center - side * 0.30);
                voc_sum += vbar;
                voc_u_num += u * vbar;
                voc_u_den += vbar;
                voc_cnt += 1.0;
            }
            if (u >= 0.60 and u <= 0.85) {
                tonal_hi_sum += mono;
                tonal_hi_cnt += 1.0;
            }
            if (u >= 0.93) {
                air_l_sum += raw_l[i];
                air_r_sum += raw_r[i];
                air_cnt += 1.0;
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

        // Expanding concentric rings pool (driven by kick 100-300Hz OR sustained mids 300Hz-2.2kHz)
        if (self.kick_ring_cd > 0) self.kick_ring_cd = @max(0.0, self.kick_ring_cd - p.dt);
        for (&self.kick_rings_pool) |*kr| {
            if (!kr.active) continue;
            kr.age += p.dt;
            if (kr.age >= kr.max_life) kr.active = false;
        }
        if (p.ring_mode == .kick and punch > 0.24 and flux > 0.055 and self.kick_ring_cd <= 0) {
            for (&self.kick_rings_pool) |*kr| {
                if (!kr.active) {
                    kr.* = .{
                        .age = 0,
                        .max_life = 1.15,
                        .strength = std.math.clamp(0.45 + punch * 0.65, 0.4, 1.0),
                        .dom_u = self.kick_dom_u,
                        .active = true,
                    };
                    self.kick_ring_cd = 0.14;
                    break;
                }
            }
        }

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

        // High-frequency sparkle/star emitter (~10–16 kHz, gated by spectral tilt against 1.2–5.5 kHz brass/vocals)
        const air_l: f32 = if (air_cnt > 0) std.math.clamp(air_l_sum / air_cnt, 0, 1) else 0;
        const air_r: f32 = if (air_cnt > 0) std.math.clamp(air_r_sum / air_cnt, 0, 1) else 0;
        const tonal_hi: f32 = if (tonal_hi_cnt > 0) std.math.clamp(tonal_hi_sum / tonal_hi_cnt, 0, 1) else 0;
        const air_raw: f32 = 0.5 * (air_l + air_r);
        // Only pass energy that exceeds the harmonic roll-off of tonal instruments (trumpets/brass/snares)
        const air_e: f32 = @max(0.0, air_raw - tonal_hi * 0.72);
        const air_flux: f32 = @max(0.0, air_e - self.air_avg);
        self.air_avg += (air_e - self.air_avg) * @min(1.0, p.dt * 8.0);
        self.updateStars(p.dt, air_l, air_r, air_e, air_flux, p.star_level);

        // Sustained mid-range filament emitter (~300 Hz – 2.2 kHz: piano, trumpet, sax)
        const sus_l: f32 = if (sus_cnt > 0) std.math.clamp(sus_l_sum / sus_cnt, 0, 1) else 0;
        const sus_r: f32 = if (sus_cnt > 0) std.math.clamp(sus_r_sum / sus_cnt, 0, 1) else 0;
        const sus_e: f32 = 0.5 * (sus_l + sus_r);
        const sus_dom_u: f32 = if (sus_u_den > 1e-4) sus_u_num / sus_u_den else 0.52;
        const sus_pitch: f32 = std.math.clamp((sus_dom_u - 0.40) / 0.32, 0.0, 1.0);
        self.updateFilaments(p.dt, sus_l, sus_r, sus_e, sus_pitch, p.wave_level);

        // Singing & spoken voice concentric rings (~250 Hz – 3.5 kHz, center-biased)
        if (self.vocal_ring_cd > 0) self.vocal_ring_cd = @max(0.0, self.vocal_ring_cd - p.dt);
        const voc_e: f32 = if (voc_cnt > 0) std.math.clamp(voc_sum / voc_cnt, 0, 1) else 0;
        const voc_flux: f32 = @max(0.0, voc_e - self.vocal_avg);
        self.vocal_avg += (voc_e - self.vocal_avg) * @min(1.0, p.dt * 6.0);
        const voc_dom_u: f32 = if (voc_u_den > 1e-4) voc_u_num / voc_u_den else 0.56;
        if (p.ring_mode == .mid and self.vocal_ring_cd <= 0 and
            ((voc_flux > 0.020 and voc_e > 0.055) or voc_e > 0.14))
        {
            for (&self.kick_rings_pool) |*kr| {
                if (!kr.active) {
                    kr.* = .{
                        .age = 0,
                        .max_life = 1.40,
                        .strength = std.math.clamp(0.45 + voc_e * 0.95 + voc_flux * 2.2, 0.42, 1.0),
                        .dom_u = voc_dom_u,
                        .active = true,
                    };
                    self.vocal_ring_cd = 0.16;
                    break;
                }
            }
        }

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
        const lin_rows: usize = if (p.viz_layout == .linear and rows >= 16) std.math.clamp(rows / 5, 5, 11) else 0;
        const top_pad: usize = if (p.viz_layout == .linear) info_rows else 0;
        const bot_pad: usize = if (p.viz_layout == .linear) lin_rows else info_rows;
        const vis_rows = rows -| (top_pad + bot_pad);
        const k = p.aspect;

        // Cell-aligned disc placement box centered in (0..cols, top_pad..top_pad+vis_rows).
        const cx0: f32 = @as(f32, @floatFromInt(cols)) * 0.5;
        const cy0: f32 = @as(f32, @floatFromInt(vis_rows)) * k * 0.5;
        const rmax = @min(cx0, cy0) - 0.3;
        const ring_h = rmax * 0.27;
        const margin = @max(rmax * 0.05, k * 0.8);
        const rd_raw = if (p.viz_layout == .circular)
            rmax - ring_h - margin
        else
            rmax;
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
            disc_row0 = top_pad + (vis_rows - disc_rows) / 2;

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
                self.drawGlow(s, cx, cy, rd, rmax, s.rows, k, glow_src, pal.c2, bgf, p.glow_gain);
            }
            if (p.aurora and (self.sub_l > 0.004 or self.sub_r > 0.004)) {
                self.drawAurora(s, s.rows, p.bg_mode, p.aurora_gain);
            }
            const excl_r = if (p.viz_layout == .circular) r0 + ring_min + 1.0 else rd;
            if (p.wave_level > 0) {
                self.drawFilaments(s, cx, cy, excl_r, k, s.rows, pal.c1, pal.c2, p.fx_color, p.wave_level);
            }
            if (p.ring_mode != .off) {
                const ring_start = if (p.viz_layout == .circular) r0 + ring_min + ring_h else rd;
                self.drawKickRings(s, cx, cy, ring_start, ring_start, k, s.rows, pal.c1, pal.c2, p.fx_color, p.glow_gain);
            }
            if (p.star_level > 0) {
                self.drawStars(s, cx, cy, excl_r, k, pal.c2, p.viz_color);
            }
            switch (p.viz_layout) {
                .circular => self.drawRing(s, &p, cx, cy, rd, r0, ring_h, ring_min, vis_rows, pal.c1, pal.c2, bgf),
                .linear => if (lin_rows > 0) self.drawLinear(s, &p, rows - lin_rows, lin_rows, pal.c1, pal.c2),
                .off => {},
            }

            if (p.kitty_enc) |enc| {
                const est_px: usize = if (p.cell_px_w > 0)
                    @intFromFloat(@round(@as(f32, @floatFromInt(disc_cols)) * p.cell_px_w))
                else
                    disc_cols * 14;
                const mode_cap: usize = if (enc.mode == .file) p.disc_res.maxSide() else @min(p.disc_res.maxSide(), 384);
                const side: usize = std.math.clamp(est_px, 128, mode_cap) & ~@as(usize, 1);
                self.ensureTextures(@min(art.SRC, side));
                if (self.img != null and self.tex.size > 0) {
                    const eff_angle: f32 = if (p.disc_style == .cover) 0.0 else p.angle;
                    const dirty = p.force_redraw or !self.disc_active or
                        self.last_col0 != disc_col0 or self.last_row0 != disc_row0 or
                        self.last_disc_cols != disc_cols or self.last_disc_rows != disc_rows or
                        self.last_side != side or @abs(self.last_aspect - k) > 1e-4 or
                        self.last_img_gen != self.img_gen or self.last_sheen != p.sheen or
                        self.last_aa != p.aa or self.last_style != p.disc_style or
                        self.fade < 1.0 or self.last_fade < 1.0 or
                        eff_angle != self.last_angle;
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
                            self.last_angle = eff_angle;
                            self.last_fade = self.fade;
                            self.last_img_gen = self.img_gen;
                            self.last_sheen = p.sheen;
                            self.last_aa = p.aa;
                            self.last_style = p.disc_style;
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

        self.drawInfo(s, &p, vis_rows, info_rows, disc_col0, disc_row0, disc_cols, disc_rows, pal.c1, pal.c2, bg);
    }

    fn ensureDiscLut(self: *Renderer, side: usize, box_w: f32, box_h: f32, rd: f32, rh: f32, aa: bool, style: DiscStyle) void {
        if (self.lut_side == side and
            @abs(self.lut_box_w - box_w) < 1e-4 and
            @abs(self.lut_box_h - box_h) < 1e-4 and
            @abs(self.lut_rd - rd) < 1e-4 and
            @abs(self.lut_rh - rh) < 1e-4 and
            self.lut_aa == aa and
            self.lut_style == style and
            self.disc_alpha.len == side * side)
        {
            return;
        }
        const n = side * side;
        if (self.disc_alpha.len != n) {
            if (self.disc_alpha.len > 0) self.alloc.free(self.disc_alpha);
            if (self.disc_sheen.len > 0) self.alloc.free(self.disc_sheen);
            if (self.disc_zone.len > 0) self.alloc.free(self.disc_zone);
            if (self.disc_gray.len > 0) self.alloc.free(self.disc_gray);
            self.disc_alpha = &.{};
            self.disc_sheen = &.{};
            self.disc_zone = &.{};
            self.disc_gray = &.{};
            self.lut_side = 0;

            self.disc_alpha = self.alloc.alloc(u8, n) catch return;
            self.disc_sheen = self.alloc.alloc(u8, n) catch return;
            self.disc_zone = self.alloc.alloc(u8, n) catch return;
            self.disc_gray = self.alloc.alloc(u8, n) catch return;
        }
        self.lut_side = side;
        self.lut_box_w = box_w;
        self.lut_box_h = box_h;
        self.lut_rd = rd;
        self.lut_rh = rh;
        self.lut_aa = aa;
        self.lut_style = style;

        const inv_rd = 1.0 / rd;
        const inv_side = 1.0 / @as(f32, @floatFromInt(side));
        const px_step = @max(box_w, box_h) * inv_side;
        const aa_half: f32 = if (aa) px_step * 0.5 else 0.0;
        const hole_r: f32 = switch (style) {
            .cover => 0.0,
            .cd => rd * 0.125,
            .vinyl, .vinyl_art => rh,
        };
        const outer_hi = rd + aa_half;
        const outer_lo = rd - aa_half;
        const outer_hi2 = outer_hi * outer_hi;
        const inner_lo = if (hole_r > 0.0) @max(0.0, hole_r - aa_half) else 0.0;
        const inner_hi = if (hole_r > 0.0) hole_r + aa_half else 0.0;
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
                    self.disc_zone[idx] = 0;
                    self.disc_gray[idx] = 0;
                    continue;
                }
                const rho = @sqrt(d2);
                if (hole_r > 0.0 and rho <= inner_lo) {
                    self.disc_alpha[idx] = 0;
                    self.disc_sheen[idx] = 0;
                    self.disc_zone[idx] = 0;
                    self.disc_gray[idx] = 0;
                    continue;
                }
                const outer_a: f32 = if (!aa or rho <= outer_lo) 1.0 else smoothstep(outer_hi, outer_lo, rho);
                const inner_a: f32 = if (hole_r == 0.0 or !aa or rho >= inner_hi) 1.0 else smoothstep(inner_lo, inner_hi, rho);
                const base_a = outer_a * inner_a;
                const rn = rho * inv_rd;

                if (rho > 1e-4) {
                    const cphi = (nx * sheen_cx + ny * sheen_sy) / rho;
                    const c2 = cphi * cphi;
                    const c6 = c2 * c2 * c2;
                    const w = c6 * c6 * 0.17 * smoothstep(0.10, 0.40, rn);
                    self.disc_sheen[idx] = @intFromFloat(std.math.clamp(w * 256.0, 0, 255));
                } else {
                    self.disc_sheen[idx] = 0;
                }

                switch (style) {
                    .cover => {
                        self.disc_zone[idx] = 1;
                        self.disc_gray[idx] = 0;
                        self.disc_alpha[idx] = @intFromFloat(std.math.clamp(base_a * 255.0 + 0.5, 0, 255));
                    },
                    .vinyl => {
                        if (rn < 0.34) {
                            self.disc_zone[idx] = 4; // colored vinyl label with rotation stripe
                            self.disc_gray[idx] = if (rn > 0.322) 180 else 255;
                        } else {
                            self.disc_zone[idx] = 3; // black vinyl grooves
                            const groove = 0.5 + 0.5 * @sin(rn * 260.0);
                            const v: f32 = 14.0 + 12.0 * groove + (if (rn > 0.96) @as(f32, 10.0) else 0.0);
                            self.disc_gray[idx] = @intFromFloat(std.math.clamp(v, 0, 255));
                        }
                        self.disc_alpha[idx] = @intFromFloat(std.math.clamp(base_a * 255.0 + 0.5, 0, 255));
                    },
                    .vinyl_art => {
                        if (rn < 0.36) {
                            self.disc_zone[idx] = 2; // cover art scaled inside center label
                            self.disc_gray[idx] = if (rn > 0.345) 180 else 255;
                        } else {
                            self.disc_zone[idx] = 3; // black vinyl grooves
                            const groove = 0.5 + 0.5 * @sin(rn * 260.0);
                            const v: f32 = 14.0 + 12.0 * groove + (if (rn > 0.96) @as(f32, 10.0) else 0.0);
                            self.disc_gray[idx] = @intFromFloat(std.math.clamp(v, 0, 255));
                        }
                        self.disc_alpha[idx] = @intFromFloat(std.math.clamp(base_a * 255.0 + 0.5, 0, 255));
                    },
                    .cd => {
                        if (rn < 0.258) {
                            // Flat clear polycarbonate inner hub ending directly at the inner stacking ring
                            self.disc_zone[idx] = 3;
                            var alpha_f: f32 = 0.20;
                            var tone: f32 = 200.0;

                            // Crisp thin cut-plastic inner rim around the 15mm center hole
                            if (rn < 0.140) {
                                const edge = smoothstep(0.140, 0.126, rn);
                                alpha_f = mix1(alpha_f, 0.72, edge);
                                tone = mix1(tone, 240.0, edge);
                            }
                            // Crisp inner ring right where the printed artwork meets the clear hub
                            if (rn > 0.246) {
                                const ring = smoothstep(0.246, 0.256, rn);
                                alpha_f = mix1(alpha_f, 0.78, ring);
                                tone = mix1(tone, 236.0, ring);
                            }
                            self.disc_gray[idx] = @intFromFloat(tone);
                            self.disc_alpha[idx] = @intFromFloat(std.math.clamp(base_a * alpha_f * 255.0 + 0.5, 0, 255));
                        } else if (rn > 0.970) {
                            // Flat clear polycarbonate outer rim + crisp opaque outer cut edge
                            self.disc_zone[idx] = 3;
                            const edge_thick = smoothstep(0.988, 0.998, rn);
                            const alpha_f = mix1(0.22, 0.78, edge_thick);
                            const tone = mix1(200.0, 242.0, edge_thick);
                            self.disc_gray[idx] = @intFromFloat(std.math.clamp(tone, 0, 255));
                            self.disc_alpha[idx] = @intFromFloat(std.math.clamp(base_a * alpha_f * 255.0 + 0.5, 0, 255));
                        } else {
                            // Printed CD artwork region
                            self.disc_zone[idx] = 1;
                            self.disc_gray[idx] = 0;
                            self.disc_alpha[idx] = @intFromFloat(std.math.clamp(base_a * 255.0 + 0.5, 0, 255));
                        }
                    },
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
        self.ensureDiscLut(side, box_w, box_h, rd, rh, p.aa, p.disc_style);
        if (self.disc_alpha.len != side * side) return;

        const eff_angle: f32 = if (p.disc_style == .cover) 0.0 else p.angle;
        const ca = @cos(eff_angle);
        const sa = @sin(eff_angle);
        const inv_rd = 1.0 / rd;
        const inv_side = 1.0 / @as(f32, @floatFromInt(side));
        const dx_step = box_w * inv_side;
        const du_dx = dx_step * ca * inv_rd;
        const dv_dx = -dx_step * sa * inv_rd;
        const nx0 = (0.5 * inv_side - 0.5) * box_w;
        const inv_label: f32 = 1.0 / 0.36;

        const use_old = self.fade < 1.0 and self.old_img != null and self.old_tex.size == self.tex.size;
        const fade_u: u32 = @intFromFloat(std.math.clamp(self.fade * 256.0, 0, 256));
        const ifx_u: u32 = 256 - fade_u;
        const do_sheen = p.sheen;
        const do_aa = p.aa;
        const is_cd = p.disc_style == .cd;
        const label_rgb: [3]u8 = if (self.img) |im| .{ im.c1.r, im.c1.g, im.c1.b } else .{ 190, 90, 90 };

        for (0..side) |py| {
            const ny = ((@as(f32, @floatFromInt(py)) + 0.5) * inv_side - 0.5) * box_h;
            var u = (nx0 * ca + ny * sa) * inv_rd;
            var v = (-nx0 * sa + ny * ca) * inv_rd;
            const lut_row = py * side;
            const out_row = lut_row * 4;
            for (0..side) |px| {
                const idx = lut_row + px;
                const a = self.disc_alpha[idx];
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

                const zone = self.disc_zone[idx];
                var col: [3]u8 = undefined;
                switch (zone) {
                    1 => {
                        col = if (do_aa) self.tex.sampleBilinear(u, v) else self.tex.sampleNearest(u, v);
                        if (use_old) {
                            const ocol = if (do_aa) self.old_tex.sampleBilinear(u, v) else self.old_tex.sampleNearest(u, v);
                            col = .{
                                @intCast((ifx_u * ocol[0] + fade_u * col[0] + 128) >> 8),
                                @intCast((ifx_u * ocol[1] + fade_u * col[1] + 128) >> 8),
                                @intCast((ifx_u * ocol[2] + fade_u * col[2] + 128) >> 8),
                            };
                        }
                    },
                    2 => {
                        const lu = u * inv_label;
                        const lv = v * inv_label;
                        col = if (do_aa) self.tex.sampleBilinear(lu, lv) else self.tex.sampleNearest(lu, lv);
                        if (use_old) {
                            const ocol = if (do_aa) self.old_tex.sampleBilinear(lu, lv) else self.old_tex.sampleNearest(lu, lv);
                            col = .{
                                @intCast((ifx_u * ocol[0] + fade_u * col[0] + 128) >> 8),
                                @intCast((ifx_u * ocol[1] + fade_u * col[1] + 128) >> 8),
                                @intCast((ifx_u * ocol[2] + fade_u * col[2] + 128) >> 8),
                            };
                        }
                        const g: u32 = self.disc_gray[idx];
                        if (g < 255) {
                            col = .{
                                @intCast((@as(u32, col[0]) * g) >> 8),
                                @intCast((@as(u32, col[1]) * g) >> 8),
                                @intCast((@as(u32, col[2]) * g) >> 8),
                            };
                        }
                    },
                    3 => {
                        const g = self.disc_gray[idx];
                        if (is_cd) {
                            // Subtle cool polycarbonate tint for CD clear plastic hub & rim
                            col = .{ @min(255, g -| 6), g, @min(255, @as(u16, g) + 10) };
                        } else {
                            col = .{ g, g, @min(255, @as(u16, g) + 2) };
                        }
                    },
                    4 => {
                        if (@abs(v) < 0.035 and u > 0.08 and u < 0.28) {
                            col = .{ 245, 245, 245 };
                        } else {
                            col = label_rgb;
                        }
                        const g: u32 = self.disc_gray[idx];
                        if (g < 255) {
                            col = .{
                                @intCast((@as(u32, col[0]) * g) >> 8),
                                @intCast((@as(u32, col[1]) * g) >> 8),
                                @intCast((@as(u32, col[2]) * g) >> 8),
                            };
                        }
                    },
                    else => col = .{ 0, 0, 0 },
                }

                if (do_sheen) {
                    const sw: u32 = self.disc_sheen[idx];
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
        gain: f32,
    ) void {
        _ = c2;
        // Pure 100%-saturated hue extracted from the cover's dominant color (no white washout)
        const c_mn = @min(c1[0], @min(c1[1], c1[2]));
        const c_mx = @max(c1[0], @max(c1[1], c1[2]));
        const pure: [3]f32 = if (c_mx - c_mn > 2.0) blk: {
            const inv = 1.0 / (c_mx - c_mn);
            break :blk .{ (c1[0] - c_mn) * inv, (c1[1] - c_mn) * inv, (c1[2] - c_mn) * inv };
        } else .{ 0.45, 0.55, 1.0 }; // fallback hue for greyscale covers

        const g = std.math.clamp(gain, 0.1, 3.0);
        const bg_mx = @max(bgf[0], @max(bgf[1], bgf[2]));
        const target_v = std.math.clamp(bg_mx * 3.2 * @max(1.0, g), 64.0, 215.0);
        const sat_col = [3]f32{ pure[0] * target_v, pure[1] * target_v, pure[2] * target_v };

        const spread = @max(rmax * 0.85, rd * 1.35) * (0.85 + 0.15 * g);
        const inv_spread = 1.0 / spread;
        const max_d = rd + spread * 2.2;
        const max_d2 = max_d * max_d;
        const inner_start = rd * 0.86;
        const intensity = self.kick_glow * 0.82 * g;

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
                const amt = std.math.clamp(intensity * rim_in * falloff, 0, 0.98);
                if (amt <= 0.002) continue;

                const col = toRgb(mix3(bgf, sat_col, amt));
                const cell = s.at(c, r);
                cell.bg = col;
                cell.fg = col;
            }
        }
    }

    /// Darkening storm-like aurora creeping inward from left & right screen edges on 20–80 Hz sub-bass.
    /// On black background it tints with deep rebeccapurple; on tinted background it darkens (fades) the
    /// background and any underlying glows toward black with the same intensity profile.
    fn drawAurora(self: *const Renderer, s: *Screen, vis_rows: usize, bg_mode: BgMode, gain: f32) void {
        if (s.cols < 4 or vis_rows < 2) return;
        const g = std.math.clamp(gain, 0.1, 3.0);
        const sl = std.math.clamp(self.sub_l * g, 0.0, 1.8);
        const sr = std.math.clamp(self.sub_r * g, 0.0, 1.8);
        const cols_f: f32 = @floatFromInt(s.cols);
        const rows_f: f32 = @floatFromInt(vis_rows);
        const max_span = @max(4.0, cols_f * (0.44 * (0.85 + 0.15 * g)));
        const inv_span = 1.0 / max_span;
        const phase = self.aurora_phase;
        const spec_col = pathBandColor(self.sub_dom_u);
        const tint_scale = std.math.clamp(0.30 * (0.8 + 0.2 * g), 0.15, 0.55);
        const storm_tint = [3]f32{ spec_col[0] * tint_scale, spec_col[1] * tint_scale, spec_col[2] * tint_scale };

        for (0..vis_rows) |r| {
            const ny = (@as(f32, @floatFromInt(r)) + 0.5) / rows_f;
            const sway_l = 0.5 + 0.30 * @sin(ny * 5.2 + phase * 1.1) + 0.20 * @sin(ny * 11.7 - phase * 1.9);
            const sway_r = 0.5 + 0.30 * @sin(ny * 5.6 - phase * 1.0 + 1.7) + 0.20 * @sin(ny * 11.1 + phase * 1.7);
            const reach_l = (0.28 + 0.72 * @min(1.3, sl)) * (0.62 + 0.58 * sway_l);
            const reach_r = (0.28 + 0.72 * @min(1.3, sr)) * (0.62 + 0.58 * sway_r);
            const vert_ripple_l = @sin(ny * 4.5 + phase) * 2.0;
            const vert_ripple_r = @sin(ny * 4.9 - phase * 1.1 + 1.3) * 2.0;

            for (0..s.cols) |c| {
                const edge_l = @as(f32, @floatFromInt(c)) * inv_span;
                const edge_r = @as(f32, @floatFromInt(s.cols - 1 - c)) * inv_span;
                if (edge_l > reach_l and edge_r > reach_r) continue;

                var dark: f32 = 0;
                if (sl > 0.004 and edge_l < reach_l) {
                    const mask = smoothstep(reach_l, 0.0, edge_l);
                    const ribbon = 0.65 + 0.35 * @sin(edge_l * 14.0 - phase * 2.4 + vert_ripple_l);
                    dark = @max(dark, sl * mask * ribbon);
                }
                if (sr > 0.004 and edge_r < reach_r) {
                    const mask = smoothstep(reach_r, 0.0, edge_r);
                    const ribbon = 0.65 + 0.35 * @sin(edge_r * 14.0 - phase * 2.2 + vert_ripple_r);
                    dark = @max(dark, sr * mask * ribbon);
                }
                const amt = std.math.clamp(dark * 0.94, 0.0, 0.98);
                if (amt <= 0.005) continue;

                const cell = s.at(c, r);
                // On tinted background, fade cell bg (including underlying glows) toward black;
                // on black background, tint with deep rebeccapurple storm aurora.
                const target: [3]f32 = if (bg_mode == .tint) .{ 0, 0, 0 } else storm_tint;
                const bg = toRgb(mix3(toF(cell.bg), target, amt));
                cell.bg = bg;
                if (cell.cp == ' ') cell.fg = bg;
            }
        }
    }

    fn nextRand(self: *Renderer) f32 {
        var x = self.star_rng;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.star_rng = if (x == 0) 0x9E3779B9 else x;
        return @as(f32, @floatFromInt(self.star_rng & 0xFFFFFF)) / 16777216.0;
    }

    fn updateStars(self: *Renderer, dt: f32, air_l: f32, air_r: f32, air_e: f32, air_flux: f32, level: u8) void {
        if (self.star_cd > 0) self.star_cd = @max(0.0, self.star_cd - dt);
        for (&self.stars) |*st| {
            if (st.life > 0) {
                st.life = @max(0.0, st.life - dt);
                st.phase += dt * 14.0;
            }
        }
        if (level == 0) {
            self.star_accum = 0;
            return;
        }
        const lv_f: f32 = @floatFromInt(level);
        var to_spawn: usize = 0;

        // 1) Immediate onset burst on every crisp hi-hat / cymbal transient (never skip short 1-2 frame hits!)
        if (air_flux > 0.032 and air_e > 0.06 and self.star_cd <= 0) {
            const burst_f = @max(1.0, @round(lv_f * std.math.clamp(0.45 + air_flux * 3.5, 0.45, 1.8)));
            to_spawn += @as(usize, @intFromFloat(burst_f));
            self.star_cd = 0.035; // 35ms debounce catches even rapid 16th-note hi-hats
        }

        // 2) Continuous shimmer during sustained cymbal wash/sizzle
        if (air_e > 0.09) {
            self.star_accum += dt * air_e * (lv_f * 18.0);
            while (self.star_accum >= 1.0) {
                self.star_accum -= 1.0;
                to_spawn += 1;
            }
        }

        const max_spawns: usize = @as(usize, level) * 2 + 2;
        to_spawn = @min(to_spawn, max_spawns);
        const drive = std.math.clamp(air_e * 1.1 + air_flux * 4.5, 0.2, 2.5);

        var spawned: usize = 0;
        while (spawned < to_spawn) : (spawned += 1) {
            var slot: ?*Star = null;
            for (&self.stars) |*st| {
                if (st.life <= 0) {
                    slot = st;
                    break;
                }
            }
            const st = slot orelse break;
            const total = air_l + air_r + 1e-4;
            const left_prob = air_l / total;

            // Pick a point outside the central ~36% disc zone so stars aren't silently dropped
            var sx: f32 = 0.1;
            var sy: f32 = 0.1;
            for (0..8) |_| {
                const rx = self.nextRand();
                const ry = self.nextRand();
                const side_roll = self.nextRand();
                const cx_try = if (side_roll < left_prob) rx * 0.48 else 0.52 + rx * 0.48;
                const cy_try = 0.03 + ry * 0.94;
                const ddx = (cx_try - 0.5) * 1.6;
                const ddy = (cy_try - 0.5) * 1.0;
                sx = cx_try;
                sy = cy_try;
                if (ddx * ddx + ddy * ddy > 0.16) break;
            }
            st.x = sx;
            st.y = sy;
            st.max_life = 0.30 + self.nextRand() * 0.65;
            st.life = st.max_life;
            st.peak = std.math.clamp(0.48 + drive * 0.42 + self.nextRand() * 0.22, 0.40, 1.0);
            st.phase = self.nextRand() * TAU;
            const r_kind = self.nextRand();
            st.kind = if (st.peak > 0.80 and r_kind > 0.62)
                3 // ✦ bright four-point sparkle
            else if (st.peak > 0.62 and r_kind > 0.42)
                2 // ✧ hollow sparkle
            else if (r_kind > 0.32)
                1 // ⋆ small star
            else
                0; // · fine dot
        }
    }

    fn drawStars(self: *const Renderer, s: *Screen, cx: f32, cy: f32, excl_r: f32, k: f32, c2: [3]f32, viz_color: VizColor) void {
        if (s.cols < 4 or s.rows < 4) return;
        const star_col: [3]f32 = if (viz_color == .freq)
            .{ 160, 240, 160 } // luminous starlight limegreen (coherent with high-freq limegreen)
        else
            mix3(c2, .{ 255, 255, 255 }, 0.68);
        const excl_r2 = excl_r * excl_r;
        const glyphs = [4]u21{ 0x00B7, 0x22C6, 0x2727, 0x2726 }; // · ⋆ ✧ ✦

        for (self.stars) |st| {
            if (st.life <= 0) continue;
            const col_i: usize = @min(s.cols - 1, @as(usize, @intFromFloat(st.x * @as(f32, @floatFromInt(s.cols)))));
            const row_i: usize = @min(s.rows - 1, @as(usize, @intFromFloat(st.y * @as(f32, @floatFromInt(s.rows)))));

            // Never draw inside the disc/inner ring area
            const dx = @as(f32, @floatFromInt(col_i)) + 0.5 - cx;
            const dy = (@as(f32, @floatFromInt(row_i)) + 0.5) * k - cy;
            if (dx * dx + dy * dy < excl_r2) continue;

            const cell = s.at(col_i, row_i);
            if (cell.cp != ' ') continue;

            const age = st.max_life - st.life;
            const attack = smoothstep(0.0, 0.08, age);
            const decay = st.life / st.max_life;
            const twinkle = 0.72 + 0.28 * @sin(st.phase);
            const alpha = std.math.clamp(st.peak * attack * decay * decay * twinkle, 0.0, 1.0);
            if (alpha <= 0.05) continue;

            cell.cp = glyphs[st.kind];
            cell.fg = toRgb(mix3(toF(cell.bg), star_col, alpha));
            cell.bold = alpha > 0.75 and st.kind >= 2;
        }
    }

    fn updateFilaments(self: *Renderer, dt: f32, sus_l: f32, sus_r: f32, sus_e: f32, pitch: f32, level: u8) void {
        // Sensitive sustain detector: very low sustain threshold (~40-140ms) for piano, trumpet, sax phrases
        if (sus_e > 0.06) {
            self.mid_hold = @min(2.0, self.mid_hold + dt);
            const sustain_gate = smoothstep(0.04, 0.14, self.mid_hold);
            const target = sus_e * sustain_gate;
            self.mid_sustain += (target - self.mid_sustain) * @min(1.0, dt * 6.0);
        } else {
            self.mid_hold *= @exp(-dt * 5.0);
            self.mid_sustain *= @exp(-dt * 2.8);
        }

        // Advance active propagating filaments: wave oscillation speed follows the note's frequency
        for (&self.filaments) |*f| {
            if (!f.active) continue;
            f.age += dt;
            f.y_head = @max(0.0, f.y_head - f.speed * dt);
            f.phase += dt * f.wave_speed;
            if (f.age >= f.max_life) {
                f.active = false;
            }
        }

        if (level == 0 or self.mid_sustain < 0.04) {
            self.fil_accum = 0;
            return;
        }

        const lv_f: f32 = @floatFromInt(level);
        self.fil_accum += dt * @max(0.25, self.mid_sustain) * (1.8 + lv_f * 1.15);
        var spawned: usize = 0;
        while (self.fil_accum >= 1.0 and spawned < 3) : (spawned += 1) {
            self.fil_accum -= 1.0;
            var slot: ?*Filament = null;
            for (&self.filaments) |*f| {
                if (!f.active) {
                    slot = f;
                    break;
                }
            }
            const f = slot orelse break;
            const total = sus_l + sus_r + 1e-4;
            const bal = (sus_r - sus_l) / total; // -1 left .. +1 right
            // Random anchor in central zone [0.14 .. 0.86], nudged by stereo mid balance
            const base_x = 0.20 + self.nextRand() * 0.60 + bal * 0.08;
            f.* = .{
                .x0 = std.math.clamp(base_x, 0.14, 0.86),
                .y_head = 1.0,
                .y_base = 1.0,
                .max_life = 1.35 + self.nextRand() * 1.05,
                .width = 0.65 + self.nextRand() * 0.45, // thin thickness (~1 Braille dot)
                .sway = 0.018 + self.nextRand() * 0.030,
                .freq = 6.5 + pitch * 8.5 + self.nextRand() * 2.5,
                .speed = 0.55 + self.nextRand() * 0.45,
                .wave_speed = 3.2 + pitch * 12.0 + self.nextRand() * 1.8, // slower on low sax/piano, faster on high trumpet
                .phase = self.nextRand() * TAU,
                .age = 0,
                .strength = std.math.clamp(0.45 + self.mid_sustain * 0.85, 0.4, 1.0),
                .active = true,
            };
        }
    }

    /// Renders subtle expanding concentric Braille shockwave rings triggered by 100–300 Hz kick drum hits.
    fn drawKickRings(self: *const Renderer, s: *Screen, cx: f32, cy: f32, rd: f32, excl_r: f32, k: f32, vis_rows: usize, c1: [3]f32, c2: [3]f32, fx_color: FxColorMode, glow_gain: f32) void {
        if (s.cols < 8 or vis_rows < 4) return;
        var any = false;
        for (self.kick_rings_pool) |kr| {
            if (kr.active) {
                any = true;
                break;
            }
        }
        if (!any) return;

        _ = c1;
        _ = c2;
        _ = fx_color;
        const default_col = pathBandColor(0.34);
        const dot_bits = [4][2]u8{ .{ 0x01, 0x08 }, .{ 0x02, 0x10 }, .{ 0x04, 0x20 }, .{ 0x40, 0x80 } };
        const excl_r2 = @max(0.0, excl_r - 0.5) * @max(0.0, excl_r - 0.5);
        const g = std.math.clamp(glow_gain, 0.2, 3.0);
        const base_alpha = std.math.clamp(0.095 * (0.7 + 0.3 * g), 0.05, 0.16);
        const halo_gain = base_alpha * 0.15;
        const max_expand = @max(12.0, @max(cx, cy) * 1.25 - rd);
        const ring_half_w = k * 0.16;

        for (0..vis_rows) |r| {
            const cell_y0 = @as(f32, @floatFromInt(r));
            const ddy_m = (cell_y0 + 0.5) * k - cy;
            const ddy_m2 = ddy_m * ddy_m;
            for (0..s.cols) |c| {
                const cell_x0 = @as(f32, @floatFromInt(c));
                const ddx_m = cell_x0 + 0.5 - cx;
                const d2_m = ddx_m * ddx_m + ddy_m2;
                if (d2_m < excl_r2) continue;
                const cell = s.at(c, r);
                if (cell.cp != ' ') continue;

                const rho_m = @sqrt(d2_m);
                var bits: u8 = 0;
                var max_a: f32 = 0;
                var halo_a: f32 = 0;
                var ring_col = default_col;

                for (self.kick_rings_pool) |kr| {
                    if (!kr.active) continue;
                    const prog = std.math.clamp(kr.age / kr.max_life, 0.0, 1.0);
                    const r_ring = rd + prog * max_expand;
                    if (@abs(rho_m - r_ring) > 4.2) continue;

                    const fade_in = smoothstep(0.0, 0.10, prog);
                    const fade_out = smoothstep(1.0, 0.22, prog);
                    const life_a = fade_in * fade_out;
                    if (life_a <= 0.01) continue;

                    const d_halo = @abs(rho_m - r_ring);
                    if (d_halo < 3.5) {
                        halo_a += kr.strength * life_a * @exp(-(d_halo * d_halo) / 3.2);
                        if (max_a == 0) ring_col = pathBandColor(kr.dom_u);
                    }
                    if (d_halo > k + 1.5) continue;

                    for (0..4) |j| {
                        const dy = (cell_y0 + 0.125 + 0.25 * @as(f32, @floatFromInt(j))) * k - cy;
                        const dy2 = dy * dy;
                        for (0..2) |i| {
                            const dx = cell_x0 + 0.25 + 0.5 * @as(f32, @floatFromInt(i)) - cx;
                            const rho = @sqrt(dx * dx + dy2);
                            if (@abs(rho - r_ring) <= ring_half_w) {
                                bits |= dot_bits[j][i];
                                const a = kr.strength * life_a;
                                if (a > max_a) {
                                    max_a = a;
                                    ring_col = pathBandColor(kr.dom_u);
                                }
                            }
                        }
                    }
                }
                if (halo_a > 0.02) {
                    const h_amt = std.math.clamp(halo_a * halo_gain, 0.0, 0.03);
                    const bg = toRgb(mix3(toF(cell.bg), ring_col, h_amt));
                    cell.bg = bg;
                    cell.fg = bg;
                }
                if (bits == 0 or max_a <= 0.02) continue;
                const alpha = std.math.clamp(max_a * base_alpha, 0.0, 0.16);
                cell.cp = 0x2800 + @as(u21, bits);
                cell.fg = toRgb(mix3(toF(cell.bg), ring_col, alpha));
            }
        }
    }

    /// Renders thin, crisp, low-opacity translucent Braille wave filaments elongating upward from bottom then fading out.
    fn drawFilaments(self: *const Renderer, s: *Screen, cx: f32, cy: f32, excl_r: f32, k: f32, vis_rows: usize, c1: [3]f32, c2: [3]f32, fx_color: FxColorMode, level: u8) void {
        if (s.cols < 8 or vis_rows < 4 or level == 0) return;
        var any = false;
        for (self.filaments) |f| {
            if (f.active) {
                any = true;
                break;
            }
        }
        if (!any) return;

        const fil_col: [3]f32 = if (fx_color == .spectrum)
            .{ 30, 190, 190 } // crisp translucent teal
        else
            mix3(mix3(c1, c2, 0.55), .{ 245, 240, 230 }, 0.32);

        const dot_bits = [4][2]u8{ .{ 0x01, 0x08 }, .{ 0x02, 0x10 }, .{ 0x04, 0x20 }, .{ 0x40, 0x80 } };
        const cols_f: f32 = @floatFromInt(s.cols);
        const rows_f: f32 = @floatFromInt(vis_rows);
        const inv_cols = 1.0 / cols_f;
        const inv_rows = 1.0 / rows_f;
        const excl_r2 = excl_r * excl_r;
        // Very subtle low-opacity core + even fainter soft halo around it
        const base_alpha = std.math.clamp(0.055 + @as(f32, @floatFromInt(level)) * 0.0085, 0.05, 0.14);
        const halo_gain = base_alpha * 0.15;

        for (0..vis_rows) |r| {
            const cell_y0 = @as(f32, @floatFromInt(r));
            const ny_mid = (cell_y0 + 0.5) * inv_rows;
            var row_active = false;
            for (self.filaments) |f| {
                if (f.active and ny_mid >= f.y_head - 0.03 and ny_mid <= f.y_base + 0.03) {
                    row_active = true;
                    break;
                }
            }
            if (!row_active) continue;

            for (0..s.cols) |c| {
                const ddx = @as(f32, @floatFromInt(c)) + 0.5 - cx;
                const ddy = (cell_y0 + 0.5) * k - cy;
                if (ddx * ddx + ddy * ddy < excl_r2) continue;
                const cell = s.at(c, r);
                if (cell.cp != ' ') continue;

                var bits: u8 = 0;
                var max_a: f32 = 0;
                var halo_a: f32 = 0;
                const cell_x0 = @as(f32, @floatFromInt(c));
                const sx_mid = cell_x0 + 0.5;

                for (self.filaments) |f| {
                    if (!f.active) continue;
                    if (ny_mid < f.y_head - 0.03 or ny_mid > f.y_base + 0.03) continue;
                    const nx_cell = sx_mid * inv_cols;
                    if (@abs(nx_cell - f.x0) > f.sway + 4.0 * inv_cols) continue;

                    const cur_len = @max(0.02, f.y_base - f.y_head);
                    const fade_in = smoothstep(0.0, 0.22, f.age);
                    const fade_out = smoothstep(f.max_life, f.max_life * 0.42, f.age);
                    const life_a = fade_in * fade_out;
                    if (life_a <= 0.01) continue;
                    const half_w_cols = f.width * 0.42;

                    // Faint background halo around the filament centerline
                    if (ny_mid >= f.y_head and ny_mid <= f.y_base) {
                        const along_m = (ny_mid - f.y_head) / cur_len;
                        const sway_m = 0.25 + 0.75 * (1.0 - along_m);
                        const wx_m = (f.x0 + f.sway * sway_m * @sin(ny_mid * f.freq + f.phase)) * cols_f;
                        const d_halo = @abs(sx_mid - wx_m);
                        if (d_halo < 3.5) {
                            const g_fall = @exp(-(d_halo * d_halo) / 3.2);
                            const tip_m = smoothstep(0.0, 0.14, along_m);
                            const base_m = smoothstep(1.0, 0.84, along_m);
                            halo_a += f.strength * life_a * tip_m * base_m * g_fall;
                        }
                    }

                    for (0..4) |j| {
                        const sy = cell_y0 + 0.125 + 0.25 * @as(f32, @floatFromInt(j));
                        const ny = sy * inv_rows;
                        if (ny < f.y_head or ny > f.y_base) continue;
                        // 0 at growing tip (top), 1 at anchored base (bottom)
                        const along = (ny - f.y_head) / cur_len;
                        // Wave amplitude grows gracefully as it rises away from the base
                        const sway_env = 0.25 + 0.75 * (1.0 - along);
                        const wave_x_cols = (f.x0 + f.sway * sway_env * @sin(ny * f.freq + f.phase)) * cols_f;
                        for (0..2) |i| {
                            const sx = cell_x0 + 0.25 + 0.5 * @as(f32, @floatFromInt(i));
                            if (@abs(sx - wave_x_cols) <= half_w_cols) {
                                bits |= dot_bits[j][i];
                                // Soft taper at the leading tip and bottom origin
                                const tip_fade = smoothstep(0.0, 0.12, along);
                                const base_fade = smoothstep(1.0, 0.85, along);
                                const a = f.strength * life_a * tip_fade * base_fade;
                                if (a > max_a) max_a = a;
                            }
                        }
                    }
                }
                if (halo_a > 0.02) {
                    const h_amt = std.math.clamp(halo_a * halo_gain, 0.0, 0.03);
                    const bg = toRgb(mix3(toF(cell.bg), fil_col, h_amt));
                    cell.bg = bg;
                    cell.fg = bg;
                }
                if (bits == 0 or max_a <= 0.02) continue;
                const alpha = std.math.clamp(max_a * base_alpha, 0.0, 0.15);
                cell.cp = 0x2800 + @as(u21, bits);
                cell.fg = toRgb(mix3(toF(cell.bg), fil_col, alpha));
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
        // Ellipsis 3-line colors: frequency palette (rebeccapurple/teal/limegreen) or 3 tones of cover base color
        const band_low_col: Rgb = if (p.viz_color == .freq)
            .{ .r = 102, .g = 51, .b = 153 }
        else
            toRgb(mix3(c1, .{ 16, 12, 20 }, 0.48));
        const band_mid_col: Rgb = if (p.viz_color == .freq)
            (if (p.peak_mode == .ellipsis2) Rgb{ .r = 0, .g = 185, .b = 185 } else Rgb{ .r = 0, .g = 128, .b = 128 })
        else
            (if (p.peak_mode == .ellipsis2) brightSaturate(c1) else toRgb(c1));
        const band_high_col: Rgb = if (p.viz_color == .freq)
            .{ .r = 50, .g = 205, .b = 50 }
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
                // Layer priority per cell for ellipsis: 3 = bass, 2 = mid, 1 = high, 0 = band
                var cell_layer: u8 = 0;
                // Per-layer sub-pixel bitmasks for crisp sub-cell boundaries in ellipsis2
                var e2_mid_bits: u8 = 0;
                var e2_high_bits: u8 = 0;
                var e2_low_bits: u8 = 0;
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
                            if (p.peak_mode == .ellipsis2) {
                                // ellipsis2: all 3 ellipses solidly filled, priority: mid > high > low
                                // Track per-layer dot bitmasks so fg/bg give crisp 2x4 sub-pixel boundaries
                                const mid_r = r_base + self.ell2_mid[idx] * ring_h;
                                const high_r = r_base + self.ell2_high[idx] * ring_h;
                                const low_r = r_base + self.ell2_low[idx] * ring_h;
                                const bit = dot_bits[j][i];
                                if (self.ell2_mid[idx] > 0.01 and rho <= mid_r + path_w) {
                                    e2_mid_bits |= bit;
                                } else if (self.ell2_high[idx] > 0.01 and rho <= high_r + path_w) {
                                    e2_high_bits |= bit;
                                } else if (self.ell2_low[idx] > 0.01 and rho <= low_r + path_w) {
                                    e2_low_bits |= bit;
                                }
                                continue;
                            } else {
                                // ellipsis: outlines only, priority low > mid > high
                                if (onCurve(&self.path_low, idx, prev_idx, next_idx, r_base, ring_h, path_w, rho)) {
                                    hit_layer = 3;
                                } else if (onCurve(&self.path_mid, idx, prev_idx, next_idx, r_base, ring_h, path_w, rho)) {
                                    hit_layer = 2;
                                } else if (onCurve(&self.path_high, idx, prev_idx, next_idx, r_base, ring_h, path_w, rho)) {
                                    hit_layer = 1;
                                }
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
                if (p.peak_mode == .ellipsis2) {
                    const all_e2 = e2_mid_bits | e2_high_bits | e2_low_bits;
                    if (all_e2 == 0) continue;
                    const cell = s.at(c, r);
                    cell.cp = 0x2800 + @as(u21, all_e2);
                    // Weighted anti-aliased blend across lit dots, NEVER touching cell.bg (no solid tiles!)
                    const nm: f32 = @floatFromInt(@popCount(e2_mid_bits));
                    const nh: f32 = @floatFromInt(@popCount(e2_high_bits));
                    const nl: f32 = @floatFromInt(@popCount(e2_low_bits));
                    const inv_n = 1.0 / (nm + nh + nl);
                    const cm = toF(band_mid_col);
                    const ch = toF(band_high_col);
                    const cl = toF(band_low_col);
                    cell.fg = toRgb(.{
                        (cm[0] * nm + ch[0] * nh + cl[0] * nl) * inv_n,
                        (cm[1] * nm + ch[1] * nh + cl[1] * nl) * inv_n,
                        (cm[2] * nm + ch[2] * nh + cl[2] * nl) * inv_n,
                    });
                    continue;
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

    /// Renders a symmetrical stereo linear Braille spectrum along the bottom of the screen.
    fn drawLinear(self: *const Renderer, s: *Screen, p: *const Params, row0: usize, bar_rows: usize, c1: [3]f32, c2: [3]f32) void {
        if (s.cols < 4 or bar_rows == 0 or row0 >= s.rows) return;
        const dot_bits = [4][2]u8{ .{ 0x01, 0x08 }, .{ 0x02, 0x10 }, .{ 0x04, 0x20 }, .{ 0x40, 0x80 } };
        const white = [3]f32{ 255, 255, 255 };
        const total_h: f32 = @floatFromInt(bar_rows * 4);
        const half_w: f32 = @as(f32, @floatFromInt(s.cols)) * 0.5;
        const inv_half: f32 = 1.0 / @max(1.0, half_w);
        const half_ang = ANG / 2;

        const band_low_col: Rgb = if (p.viz_color == .freq) .{ .r = 102, .g = 51, .b = 153 } else toRgb(mix3(c1, .{ 16, 12, 20 }, 0.48));
        const band_mid_col: Rgb = if (p.viz_color == .freq)
            (if (p.peak_mode == .ellipsis2) Rgb{ .r = 0, .g = 185, .b = 185 } else Rgb{ .r = 0, .g = 128, .b = 128 })
        else
            (if (p.peak_mode == .ellipsis2) brightSaturate(c1) else toRgb(c1));
        const band_high_col: Rgb = if (p.viz_color == .freq) .{ .r = 50, .g = 205, .b = 50 } else toRgb(mix3(c2, white, 0.52));

        for (0..bar_rows) |dr| {
            const r = row0 + dr;
            if (r >= s.rows) break;
            for (0..s.cols) |c| {
                var bits: u8 = 0;
                var acc = [3]f32{ 0, 0, 0 };
                var lit: f32 = 0;
                for (0..2) |i| {
                    const sx = @as(f32, @floatFromInt(c)) + 0.25 + 0.5 * @as(f32, @floatFromInt(i));
                    const right_side = sx >= half_w;
                    // Symmetrical stereo: center = bass (or highs if inverted with 'i'), outer edges = highs
                    const dist_center = std.math.clamp(@abs(sx - half_w) * inv_half, 0.0, 1.0);
                    const u = if (p.bass_top) 1.0 - dist_center else dist_center;
                    // Map (right_side, u) to existing ANG array index
                    const t_ang = if (p.bass_top) u else 1.0 - u;
                    const sub_idx: usize = @min(@as(usize, half_ang - 1), @as(usize, @intFromFloat(t_ang * @as(f32, @floatFromInt(half_ang)))));
                    const idx: usize = if (right_side) sub_idx else (ANG - 1) - sub_idx;

                    const v = self.amp[idx];
                    const h_val = 0.6 + v * (total_h - 1.2);
                    const pk_val = 0.6 + self.peak[idx] * (total_h - 1.2);

                    for (0..4) |j| {
                        // Height from bottom edge of linear visualizer (0 at bottom .. total_h at top)
                        const y_from_bot = total_h - (@as(f32, @floatFromInt(dr * 4 + j)) + 0.5);
                        var col: [3]f32 = undefined;
                        if (p.peak_mode == .ellipsis or p.peak_mode == .ellipsis2) {
                            const h_low = 0.6 + (if (p.peak_mode == .ellipsis2) self.ell2_low[idx] else self.path_low[idx]) * (total_h - 1.2);
                            const h_mid = 0.6 + (if (p.peak_mode == .ellipsis2) self.ell2_mid[idx] else self.path_mid[idx]) * (total_h - 1.2);
                            const h_high = 0.6 + (if (p.peak_mode == .ellipsis2) self.ell2_high[idx] else self.path_high[idx]) * (total_h - 1.2);
                            if (p.peak_mode == .ellipsis2) {
                                if (self.ell2_mid[idx] > 0.01 and y_from_bot <= h_mid) {
                                    col = toF(band_mid_col);
                                } else if (self.ell2_high[idx] > 0.01 and y_from_bot <= h_high) {
                                    col = toF(band_high_col);
                                } else if (self.ell2_low[idx] > 0.01 and y_from_bot <= h_low) {
                                    col = toF(band_low_col);
                                } else continue;
                            } else {
                                if (self.path_low[idx] > 0.01 and @abs(y_from_bot - h_low) <= 0.75) {
                                    col = toF(band_low_col);
                                } else if (self.path_mid[idx] > 0.01 and @abs(y_from_bot - h_mid) <= 0.75) {
                                    col = toF(band_mid_col);
                                } else if (self.path_high[idx] > 0.01 and @abs(y_from_bot - h_high) <= 0.75) {
                                    col = toF(band_high_col);
                                } else continue;
                            }
                        } else if (y_from_bot <= h_val) {
                            if (p.viz_color == .freq) {
                                col = pathBandColor(u);
                                if (p.peak_mode == .peak) {
                                    const dim = 0.65 + 0.35 * std.math.clamp(v * 1.3 + 0.15, 0, 1);
                                    col = .{ col[0] * dim, col[1] * dim, col[2] * dim };
                                }
                            } else {
                                const q = std.math.clamp(y_from_bot / total_h, 0, 1);
                                col = mix3(c1, c2, q);
                                if (h_val - y_from_bot < 1.2) col = mix3(col, white, 0.35);
                                const dim = 0.55 + 0.45 * std.math.clamp(v * 1.4 + 0.2, 0, 1);
                                col = .{ col[0] * dim, col[1] * dim, col[2] * dim };
                            }
                        } else if (p.peak_mode == .peak and @abs(y_from_bot - (pk_val + 1.0)) <= 0.75 and self.peak[idx] > v + 0.02) {
                            col = if (p.viz_color == .freq) mix3(pathBandColor(u), white, 0.45) else mix3(c2, white, 0.5);
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
                cell.fg = toRgb(.{ acc[0] / lit, acc[1] / lit, acc[2] / lit });
            }
        }
    }

    fn drawInfo(
        self: *Renderer,
        s: *Screen,
        p: *const Params,
        vis_rows: usize,
        info_rows: usize,
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
                " u       bande cerchio/basso/off",
                " t / k   viz 1:1/smooth / colori",
                " g / a   bagliore / aurora on/off",
                " 1/2 3/4 intensità glow / aurora",
                " 5 / 6   quantità stelline (0..10)",
                " 7 / 8   filamenti medi (0..10)",
                " 9       cerchi kick / vocal / off",
                " c       colori fx cover/freq",
                " d / x   risoluzione / AA disco",
                " o       stile cover/vinyl/v.art/CD",
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

        if (info_rows == 0 or p.info_alpha <= 0.01) return;
        const ia = std.math.clamp(p.info_alpha, 0.0, 1.0);
        // In linear layout (spectrum at bottom), move track info + seekbar to the top of the screen
        const r1: usize = if (p.viz_layout == .linear)
            (if (top_hud or p.kitty_warn) 1 else 0)
        else
            vis_rows + 1;
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
    const high = [3]f32{ 50, 205, 50 }; // limegreen
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

/// Lightens a color while boosting saturation so it pops vividly without washing out.
fn brightSaturate(c: [3]f32) Rgb {
    const avg = (c[0] + c[1] + c[2]) / 3.0;
    var s = [3]f32{
        std.math.clamp(avg + (c[0] - avg) * 1.45, 0, 255),
        std.math.clamp(avg + (c[1] - avg) * 1.45, 0, 255),
        std.math.clamp(avg + (c[2] - avg) * 1.45, 0, 255),
    };
    const mx = @max(s[0], @max(s[1], s[2]));
    const gain: f32 = if (mx > 1.0) @max(1.20, 248.0 / mx) else 1.0;
    s = .{ s[0] * gain, s[1] * gain, s[2] * gain };
    return toRgb(s);
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
        .disc_style = .vinyl,
    };
    r.rasterizeDiscRgba(rgba, side, 20.0, 20.0, 10.0, 1.0, &p);

    // Top-left corner (0, 0) must be transparent
    try std.testing.expectEqual(@as(u8, 0), rgba[3]);
    // Center pixel (32, 32) inside spindle hole must be transparent in vinyl mode
    const center_o = (32 * side + 32) * 4;
    try std.testing.expectEqual(@as(u8, 0), rgba[center_o + 3]);
    // Mid-radius pixel (48, 32) on disc body must be opaque
    const body_o = (32 * side + 48) * 4;
    try std.testing.expectEqual(@as(u8, 255), rgba[body_o + 3]);

    // Cover mode has no center hole and never rotates regardless of angle
    var p_cov = p;
    p_cov.disc_style = .cover;
    p_cov.angle = 0.0;
    r.rasterizeDiscRgba(rgba, side, 20.0, 20.0, 10.0, 1.0, &p_cov);
    try std.testing.expectEqual(@as(u8, 255), rgba[center_o + 3]);
    const ref_r = rgba[(20 * side + 28) * 4];
    p_cov.angle = 1.7;
    r.rasterizeDiscRgba(rgba, side, 20.0, 20.0, 10.0, 1.0, &p_cov);
    try std.testing.expectEqual(ref_r, rgba[(20 * side + 28) * 4]);
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
                if (cell.fg.r == 50 and cell.fg.g == 205 and cell.fg.b == 50) high_cells += 1;
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
                if (cell.fg.r == 50 and cell.fg.g == 205 and cell.fg.b == 50) path_high += 1;
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
    // On tinted background, storm aurora darkens both screen edges toward black
    try std.testing.expect(dark_l.r < base_l.r and dark_l.g < base_l.g and dark_l.b < base_l.b);
    try std.testing.expect(dark_r.r < base_r.r and dark_r.g < base_r.g and dark_r.b < base_r.b);

    // On black background, storm aurora tints both screen edges with deep rebeccapurple (b > r > g)
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
        .bg_mode = .black,
        .cava_ok = true,
    });
    const purple_l = s.at(0, 18).bg;
    const purple_r = s.at(119, 18).bg;
    try std.testing.expect(purple_l.b > purple_l.r and purple_l.r > purple_l.g);
    try std.testing.expect(purple_r.b > purple_r.r and purple_r.r > purple_r.g);
}
