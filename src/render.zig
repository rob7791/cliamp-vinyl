//! Frame composition: rotating picture-disc + circular stereo spectrum + info.
const std = @import("std");
const scr = @import("screen.zig");
const art = @import("art.zig");
const cliamp = @import("cliamp.zig");
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

pub const Params = struct {
    aspect: f32, // cell height / cell width
    angle: f32,
    dt: f32,
    left: []const f32,
    right: []const f32,
    snap: *const cliamp.Snapshot,
    position: f64,
    sheen: bool,
    bass_top: bool,
    show_fps: bool,
    show_help: bool,
    fps: f32,
    bg_mode: BgMode,
    cava_ok: bool,
};

pub const Renderer = struct {
    alloc: std.mem.Allocator,
    img: ?*art.Image = null,
    old_img: ?*art.Image = null,
    tex: Texture = .{},
    old_tex: Texture = .{},
    fade: f32 = 1.0,
    amp: [ANG]f32 = [_]f32{0} ** ANG,
    peak: [ANG]f32 = [_]f32{0} ** ANG,
    tex_size_for: usize = 0,

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
    }

    fn ensureTextures(self: *Renderer, disc_px: usize) void {
        const want = std.math.clamp(disc_px, 16, art.SRC);
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
        const decay = p.dt * 0.55;
        for (0..ANG) |a| {
            const th = (@as(f32, @floatFromInt(a)) + 0.5) / ANG * TAU;
            const right_side = th < std.math.pi;
            const t = if (right_side) th / std.math.pi else (TAU - th) / std.math.pi; // 0 top, 1 bottom
            const fpos = (if (p.bass_top) t else 1.0 - t) * nf;
            const vr = catmull(p.right, fpos);
            const vl = catmull(p.left, fpos);
            const s = smoothstep(0, 0.12, @min(t, 1 - t));
            const own = 0.5 + 0.5 * s;
            var v = if (right_side) vr * own + vl * (1 - own) else vl * own + vr * (1 - own);
            v = std.math.clamp(v, 0, 1);
            self.amp[a] = v;
            self.peak[a] = @max(v, self.peak[a] - decay);
        }
    }

    pub fn render(self: *Renderer, s: *Screen, p: Params) void {
        if (self.fade < 1.0) self.fade = @min(1.0, self.fade + p.dt / 0.8);

        const pal: Palette = if (self.img != null) self.palette() else .{ .c1 = [3]f32{ 200, 200, 200 }, .c2 = [3]f32{ 255, 255, 255 }, .avg = [3]f32{ 40, 40, 40 } };
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

        // Geometry, in units of one cell width.
        const cx: f32 = @as(f32, @floatFromInt(cols)) / 2.0;
        const cy: f32 = @as(f32, @floatFromInt(vis_rows)) * k / 2.0;
        const rmax = @min(cx, cy) - 0.3;
        const ring_h = rmax * 0.27;
        const margin = @max(rmax * 0.05, k * 0.8);
        const rd = rmax - ring_h - margin; // disc radius
        const r0 = rd + margin; // ring base
        const rh = @max(rd * 0.045, 0.8); // spindle hole
        const ring_min: f32 = 0.35;

        if (rd > 2) {
            self.ensureTextures(@intFromFloat(rd * 4));
            self.updateRing(&p);
            self.drawDisc(s, &p, cx, cy, rd, rh, vis_rows, bgf);
            self.drawRing(s, &p, cx, cy, rd, r0, ring_h, ring_min, vis_rows, pal.c1, pal.c2, bgf);
        }
        self.drawInfo(s, &p, vis_rows, pal.c1, pal.c2, bg);
    }

    fn drawDisc(self: *Renderer, s: *Screen, p: *const Params, cx: f32, cy: f32, rd: f32, rh: f32, vis_rows: usize, bgf: [3]f32) void {
        if (self.img == null or self.tex.size == 0) return;
        const k = p.aspect;
        const ca = @cos(p.angle);
        const sa = @sin(p.angle);
        const r_lo: usize = @intFromFloat(@max(0, @floor((cy - rd) / k)));
        const r_hi: usize = @min(vis_rows, @as(usize, @intFromFloat(@ceil((cy + rd) / k))) + 1);
        const c_lo: usize = @intFromFloat(@max(0, @floor(cx - rd)));
        const c_hi: usize = @min(s.cols, @as(usize, @intFromFloat(@ceil(cx + rd))) + 1);
        const use_old = self.fade < 1.0 and self.old_img != null and self.old_tex.size == self.tex.size;
        const inv_rd = 1.0 / rd;
        const sub_x = [2]f32{ 0.25, 0.75 };
        const sub_y = [2]f32{ 0.25, 0.75 };

        var r = r_lo;
        while (r < r_hi) : (r += 1) {
            var c = c_lo;
            while (c < c_hi) : (c += 1) {
                var halves: [2][3]f32 = undefined;
                var any = false;
                inline for (0..2) |h| {
                    var acc = [3]f32{ 0, 0, 0 };
                    var cover: f32 = 0;
                    for (sub_y) |oy| {
                        for (sub_x) |ox| {
                            const sx = @as(f32, @floatFromInt(c)) + ox - cx;
                            const sy = (@as(f32, @floatFromInt(r)) + (@as(f32, @floatFromInt(h)) + oy) * 0.5) * k - cy;
                            const rho = @sqrt(sx * sx + sy * sy);
                            if (rho > rd or rho < rh) continue;
                            const u = (sx * ca + sy * sa) * inv_rd;
                            const v = (-sx * sa + sy * ca) * inv_rd;
                            var col = self.tex.sample(u, v);
                            if (use_old) col = mix3(self.old_tex.sample(u, v), col, self.fade);
                            // shading: rim, spindle shadow, static sheen
                            const rn = rho * inv_rd;
                            var shade: f32 = 1.0;
                            if (rn > 0.965) shade *= 0.72;
                            if (rho < rh * 1.8) shade *= 0.55;
                            col = .{ col[0] * shade, col[1] * shade, col[2] * shade };
                            if (p.sheen) {
                                const phi = std.math.atan2(sy, sx);
                                const cphi = @cos(phi - 0.85);
                                const c2 = cphi * cphi;
                                const w = c2 * c2 * c2 * c2 * c2 * c2 * 0.16 * rn;
                                col = .{ col[0] + (255 - col[0]) * w, col[1] + (255 - col[1]) * w, col[2] + (255 - col[2]) * w };
                            }
                            acc[0] += col[0];
                            acc[1] += col[1];
                            acc[2] += col[2];
                            cover += 1;
                        }
                    }
                    if (cover > 0) any = true;
                    const bgw = (4 - cover) / 4;
                    halves[h] = .{
                        acc[0] / 4 + bgf[0] * bgw,
                        acc[1] / 4 + bgf[1] * bgw,
                        acc[2] / 4 + bgf[2] * bgw,
                    };
                }
                if (!any) continue;
                const cell = s.at(c, r);
                cell.cp = 0x2580; // ▀
                cell.fg = toRgb(halves[0]);
                cell.bg = toRgb(halves[1]);
            }
        }
    }

    fn drawRing(self: *Renderer, s: *Screen, p: *const Params, cx: f32, cy: f32, rd: f32, r0: f32, ring_h: f32, ring_min: f32, vis_rows: usize, c1: [3]f32, c2: [3]f32, bgf: [3]f32) void {
        const k = p.aspect;
        const outer_max = r0 + ring_min + ring_h + 0.5;
        const r_lo: usize = @intFromFloat(@max(0, @floor((cy - outer_max) / k)));
        const r_hi: usize = @min(vis_rows, @as(usize, @intFromFloat(@ceil((cy + outer_max) / k))) + 1);
        const c_lo: usize = @intFromFloat(@max(0, @floor(cx - outer_max)));
        const c_hi: usize = @min(s.cols, @as(usize, @intFromFloat(@ceil(cx + outer_max))) + 1);
        const dot_bits = [4][2]u8{ .{ 0x01, 0x08 }, .{ 0x02, 0x10 }, .{ 0x04, 0x20 }, .{ 0x40, 0x80 } };
        const peak_w = k * 0.13;
        const white = [3]f32{ 255, 255, 255 };

        var r = r_lo;
        while (r < r_hi) : (r += 1) {
            var c = c_lo;
            while (c < c_hi) : (c += 1) {
                // skip cells owned by the disc
                const ccx = @as(f32, @floatFromInt(c)) + 0.5 - cx;
                const ccy = (@as(f32, @floatFromInt(r)) + 0.5) * k - cy;
                const cd = @sqrt(ccx * ccx + ccy * ccy);
                if (cd < rd + k * 0.6 or cd > outer_max + k) continue;

                var bits: u8 = 0;
                var acc = [3]f32{ 0, 0, 0 };
                var lit: f32 = 0;
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
                        const pk = r0 + ring_min + self.peak[idx] * ring_h + peak_w * 1.5;
                        var col: [3]f32 = undefined;
                        if (rho <= top) {
                            const q = std.math.clamp((rho - r0) / ring_h, 0, 1);
                            col = mix3(c1, c2, q);
                            // brighten the crest of the wave
                            if (top - rho < 0.6) col = mix3(col, white, 0.35);
                            const dim = 0.55 + 0.45 * std.math.clamp(v * 1.4 + 0.2, 0, 1);
                            col = .{ col[0] * dim, col[1] * dim, col[2] * dim };
                        } else if (@abs(rho - pk) < peak_w and self.peak[idx] > v + 0.02) {
                            col = mix3(c2, white, 0.5);
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
                cell.bg = toRgb(bgf);
            }
        }
    }

    fn drawInfo(self: *Renderer, s: *Screen, p: *const Params, vis_rows: usize, c1: [3]f32, c2: [3]f32, bg: Rgb) void {
        _ = self;
        const cols = s.cols;
        const snap = p.snap;
        const light = toRgb(mix3(c2, .{ 255, 255, 255 }, 0.6));
        const dim = toRgb(mix3(c1, .{ 150, 150, 150 }, 0.6));
        const faint = toRgb(mix3(.{ @floatFromInt(bg.r), @floatFromInt(bg.g), @floatFromInt(bg.b) }, .{ 160, 160, 160 }, 0.35));
        var buf: [1024]u8 = undefined;

        if (p.show_fps) {
            const t = std.fmt.bufPrint(&buf, " {d:.1} fps ", .{p.fps}) catch "";
            _ = s.text(0, 0, t, faint, false);
        }
        if (!p.cava_ok) {
            const t = " cava non disponibile ";
            _ = s.text(cols -| t.len, 0, t, faint, false);
        }
        if (p.show_help) {
            const lines = [_][]const u8{
                " spazio  play/pausa",  " n / p   traccia succ./prec.",
                " ← / →   seek ∓5s",    " ↑ / ↓   volume ±1dB",
                " s / r   shuffle / repeat", " l       riflessi on/off",
                " b       sfondo tinta/nero", " i       inverti bassi su/giù",
                " f       mostra fps",  " q       esci",
            };
            for (lines, 0..) |l, i| _ = s.text(0, i + 1, l, light, false);
        }

        if (vis_rows == s.rows) return; // no room for info
        const r1 = vis_rows + 1;
        if (!snap.connected) {
            centered(s, r1, "in attesa di cliamp…  (avvia `cliamp` o lascia che vinyl lanci il demone)", dim, false);
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

        // progress line
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
    const n = v.len;
    const i: isize = @intFromFloat(@floor(x));
    const t = x - @floor(x);
    const at = struct {
        fn f(arr: []const f32, j: isize) f32 {
            const jj: usize = @intCast(std.math.clamp(j, 0, @as(isize, @intCast(arr.len - 1))));
            return arr[jj];
        }
    }.f;
    _ = n;
    const p0 = at(v, i - 1);
    const p1 = at(v, i);
    const p2 = at(v, i + 1);
    const p3 = at(v, i + 2);
    const t2 = t * t;
    const t3 = t2 * t;
    return 0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (-p0 + 3 * p1 - 3 * p2 + p3) * t3);
}

fn smoothstep(e0: f32, e1: f32, x: f32) f32 {
    const t = std.math.clamp((x - e0) / (e1 - e0), 0, 1);
    return t * t * (3 - 2 * t);
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
