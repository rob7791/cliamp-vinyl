//! Cover-art resolution and decoding (via ffmpeg / curl) on a worker thread.
const std = @import("std");
const posix = std.posix;
const cliamp = @import("cliamp.zig");
const Rgb = @import("screen.zig").Rgb;

pub const SRC = 512;
pub const bridge_path = "/tmp/cliamp-vinyl-art.txt";

pub const Image = struct {
    px: []u8, // SRC*SRC*3 RGB
    avg: Rgb = .{},
    c1: Rgb = .{},
    c2: Rgb = .{},
    is_placeholder: bool = false,

    pub fn destroy(self: *Image, alloc: std.mem.Allocator) void {
        alloc.free(self.px);
        alloc.destroy(self);
    }
};

pub const Loader = struct {
    alloc: std.mem.Allocator,
    client: *cliamp.Client,
    mutex: std.Thread.Mutex = .{},
    pending: ?*Image = null,
    bpm: f32 = 0,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    thread: ?std.Thread = null,

    // worker-private state
    track_key: u64 = 0,
    tried_urls: [3]u64 = .{ 0, 0, 0 },
    has_art: bool = false,
    tried_local: bool = false,
    tried_bpm: bool = false,
    bridge_mtime: i128 = 0,
    bridge_path_hash: u64 = 0,
    bridge_url: std.ArrayList(u8) = .empty,
    tmp_counter: u32 = 0,

    pub fn start(self: *Loader) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn stop(self: *Loader) void {
        self.running.store(false, .release);
        if (self.thread) |t| t.join();
        if (self.pending) |p| p.destroy(self.alloc);
        self.bridge_url.deinit(self.alloc);
    }

    /// Main thread: take ownership of a freshly decoded image, if any.
    pub fn take(self: *Loader) ?*Image {
        self.mutex.lock();
        defer self.mutex.unlock();
        const p = self.pending;
        self.pending = null;
        return p;
    }

    /// Main thread: latest resolved track BPM (0 if unavailable).
    pub fn getBpm(self: *Loader) f32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.bpm;
    }

    fn setBpm(self: *Loader, val: f32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.bpm = val;
    }

    fn publish(self: *Loader, img: *Image) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.pending) |old| old.destroy(self.alloc);
        self.pending = img;
    }

    fn run(self: *Loader) void {
        while (self.running.load(.acquire)) {
            self.step() catch {};
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
    }

    fn step(self: *Loader) !void {
        const snap = self.client.get();
        if (!snap.connected) return;
        if (snap.path.len == 0 and snap.title.len == 0) return;

        var h = std.hash.Wyhash.init(0);
        h.update(snap.path.get());
        h.update("\x00");
        h.update(snap.title.get());
        const key = h.final();
        if (key != self.track_key) {
            self.track_key = key;
            self.tried_urls = .{ 0, 0, 0 };
            self.has_art = false;
            self.tried_local = false;
            self.tried_bpm = false;
            self.setBpm(snap.bpm);
        }

        if (!self.tried_bpm) {
            self.tried_bpm = true;
            if (snap.bpm > 0) {
                self.setBpm(snap.bpm);
            } else {
                const resolved = self.resolveBpm(snap.path.get());
                self.setBpm(resolved);
            }
        }

        self.refreshBridge();

        // 1) URL carried by the snapshot, 2) URL published by the Lua bridge plugin,
        // 3) derived cover art URL for Navidrome/Subsonic or YouTube/YTMusic.
        var remote_buf: [4096]u8 = undefined;
        const bridge_candidate: []const u8 = if (self.bridge_url.items.len > 0 and
            self.bridge_path_hash == std.hash.Wyhash.hash(0, snap.path.get()))
            self.bridge_url.items
        else
            "";
        const derived_candidate: []const u8 = deriveRemoteArtUrl(snap.path.get(), &remote_buf) orelse "";
        const candidates = [_][]const u8{ snap.art_url.get(), bridge_candidate, derived_candidate };
        for (candidates, 0..) |url, idx| {
            if (url.len == 0) continue;
            const uh = std.hash.Wyhash.hash(1, url);
            if (uh == self.tried_urls[idx]) {
                if (self.has_art) return;
                continue;
            }
            self.tried_urls[idx] = uh;
            if (self.loadUrl(url)) |img| {
                self.has_art = true;
                self.publish(img);
                return;
            } else |_| {}
        }
        if (self.has_art or self.tried_local) return;
        self.tried_local = true;

        // 3) Embedded art / sidecar image for local files, 4) MPRIS artUrl.
        if (self.loadLocal(snap.path.get())) |img| {
            self.has_art = true;
            self.publish(img);
            return;
        } else |_| {}
        if (self.loadMpris()) |img| {
            self.has_art = true;
            self.publish(img);
            return;
        } else |_| {}
        self.publish(try placeholder(self.alloc, key));
    }

    fn refreshBridge(self: *Loader) void {
        const st = std.fs.cwd().statFile(bridge_path) catch return;
        if (st.mtime == self.bridge_mtime) return;
        self.bridge_mtime = st.mtime;
        const data = std.fs.cwd().readFileAlloc(self.alloc, bridge_path, 32 << 20) catch return;
        defer self.alloc.free(data);
        const nl = std.mem.indexOfScalar(u8, data, '\n') orelse return;
        self.bridge_path_hash = std.hash.Wyhash.hash(0, data[0..nl]);
        const url = std.mem.trim(u8, data[nl + 1 ..], " \r\n\t");
        self.bridge_url.clearRetainingCapacity();
        self.bridge_url.appendSlice(self.alloc, url) catch {};
    }

    fn tmpPath(self: *Loader, buf: []u8) ![]const u8 {
        self.tmp_counter +%= 1;
        return std.fmt.bufPrint(buf, "/tmp/vinyl-art-{d}-{d}.bin", .{ std.os.linux.getpid(), self.tmp_counter });
    }

    fn loadUrl(self: *Loader, url: []const u8) !*Image {
        if (std.mem.startsWith(u8, url, "data:")) {
            const marker = ";base64,";
            const i = std.mem.indexOf(u8, url, marker) orelse return error.Unsupported;
            const b64 = url[i + marker.len ..];
            const dec = std.base64.standard.Decoder;
            const size = try dec.calcSizeForSlice(b64);
            const bytes = try self.alloc.alloc(u8, size);
            defer self.alloc.free(bytes);
            try dec.decode(bytes, b64);
            var pb: [128]u8 = undefined;
            const tmp = try self.tmpPath(&pb);
            defer std.fs.cwd().deleteFile(tmp) catch {};
            try std.fs.cwd().writeFile(.{ .sub_path = tmp, .data = bytes });
            return self.decode(tmp);
        }
        if (std.mem.startsWith(u8, url, "file://")) {
            var pb: [4096]u8 = undefined;
            const p = percentDecode(url[7..], &pb);
            return self.decode(p);
        }
        if (std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://")) {
            var pb: [128]u8 = undefined;
            const tmp = try self.tmpPath(&pb);
            defer std.fs.cwd().deleteFile(tmp) catch {};
            const r = try std.process.Child.run(.{
                .allocator = self.alloc,
                .argv = &.{ "curl", "-sfL", "--max-time", "15", "-o", tmp, url },
            });
            self.alloc.free(r.stdout);
            self.alloc.free(r.stderr);
            if (r.term != .Exited or r.term.Exited != 0) return error.DownloadFailed;
            return self.decode(tmp);
        }
        return self.decode(url);
    }

    fn loadLocal(self: *Loader, path_in: []const u8) !*Image {
        var pb: [4096]u8 = undefined;
        const path = if (std.mem.startsWith(u8, path_in, "file://")) percentDecode(path_in[7..], &pb) else path_in;
        if (path.len == 0 or path[0] != '/') return error.NotLocal;
        if (self.decode(path)) |img| return img else |_| {}
        const dir = std.fs.path.dirname(path) orelse return error.NotFound;
        const names = [_][]const u8{
            "cover.jpg",  "cover.png",  "Cover.jpg",  "Cover.png",  "folder.jpg", "folder.png",
            "Folder.jpg", "front.jpg",  "front.png",  "Front.jpg",  "album.jpg",  "AlbumArt.jpg",
            "cover.webp", "folder.webp",
        };
        for (names) |n| {
            var nb: [4352]u8 = undefined;
            const full = std.fmt.bufPrint(&nb, "{s}/{s}", .{ dir, n }) catch continue;
            std.fs.cwd().access(full, .{}) catch continue;
            if (self.decode(full)) |img| return img else |_| {}
        }
        return error.NotFound;
    }

    fn loadMpris(self: *Loader) !*Image {
        const r = try std.process.Child.run(.{
            .allocator = self.alloc,
            .argv = &.{
                "gdbus",                                   "call", "--session", "--dest", "org.mpris.MediaPlayer2.cliamp",
                "--object-path",                           "/org/mpris/MediaPlayer2",
                "--method",                                "org.freedesktop.DBus.Properties.Get",
                "org.mpris.MediaPlayer2.Player",           "Metadata",
            },
        });
        defer self.alloc.free(r.stdout);
        defer self.alloc.free(r.stderr);
        const key = "'mpris:artUrl': <'";
        const i = std.mem.indexOf(u8, r.stdout, key) orelse return error.NotFound;
        const rest = r.stdout[i + key.len ..];
        const j = std.mem.indexOf(u8, rest, "'>") orelse return error.NotFound;
        return self.loadUrl(rest[0..j]);
    }

    fn decode(self: *Loader, path: []const u8) !*Image {
        const r = try std.process.Child.run(.{
            .allocator = self.alloc,
            .argv = &.{
                "ffmpeg",   "-v",        "error", "-nostdin", "-i", path, "-an", "-frames:v", "1",
                "-vf",      "scale=512:512:force_original_aspect_ratio=increase:flags=lanczos,crop=512:512",
                "-f",       "rawvideo",  "-pix_fmt", "rgb24", "pipe:1",
            },
            .max_output_bytes = SRC * SRC * 3 + 4096,
        });
        defer self.alloc.free(r.stderr);
        if (r.stdout.len != SRC * SRC * 3) {
            self.alloc.free(r.stdout);
            return error.DecodeFailed;
        }
        const img = try self.alloc.create(Image);
        img.* = .{ .px = r.stdout };
        computePalette(img);
        return img;
    }

    fn resolveBpm(self: *Loader, path_in: []const u8) f32 {
        if (path_in.len == 0) return 0;
        var ubuf: [4096]u8 = undefined;
        if (deriveSubsonicSongUrl(path_in, &ubuf)) |song_url| {
            const r = std.process.Child.run(.{
                .allocator = self.alloc,
                .argv = &.{ "curl", "-sfL", "--max-time", "8", song_url },
                .max_output_bytes = 256 * 1024,
            }) catch return 0;
            defer self.alloc.free(r.stdout);
            defer self.alloc.free(r.stderr);
            if (r.term == .Exited and r.term.Exited == 0) {
                return parseSubsonicBpm(self.alloc, r.stdout);
            }
            return 0;
        }
        var pb: [4096]u8 = undefined;
        const path = if (std.mem.startsWith(u8, path_in, "file://")) percentDecode(path_in[7..], &pb) else path_in;
        if (path.len > 0 and path[0] == '/') {
            const r = std.process.Child.run(.{
                .allocator = self.alloc,
                .argv = &.{
                    "ffprobe",        "-v",       "error",
                    "-show_entries",  "format_tags=bpm,TBPM,BPM:stream_tags=bpm,TBPM,BPM",
                    "-of",            "default=nw=1:nk=1",
                    path,
                },
                .max_output_bytes = 4096,
            }) catch return 0;
            defer self.alloc.free(r.stdout);
            defer self.alloc.free(r.stderr);
            if (r.term == .Exited and r.term.Exited == 0) {
                var it = std.mem.tokenizeAny(u8, r.stdout, " \r\n\t");
                while (it.next()) |tok| {
                    if (std.fmt.parseFloat(f32, tok)) |val| {
                        if (val >= 20.0 and val <= 350.0) return val;
                    } else |_| {}
                }
            }
        }
        return 0;
    }
};

pub fn deriveSubsonicSongUrl(path: []const u8, buf: []u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, path, "http://") and !std.mem.startsWith(u8, path, "https://")) return null;
    const needles = [_][]const u8{
        "/rest/stream.view?",
        "/rest/stream?",
        "/rest/download.view?",
        "/rest/download?",
    };
    for (needles) |needle| {
        if (std.mem.indexOf(u8, path, needle)) |idx| {
            const q = path[idx + needle.len ..];
            const has_json = std.mem.indexOf(u8, q, "f=json") != null;
            return if (has_json)
                std.fmt.bufPrint(buf, "{s}/rest/getSong?{s}", .{ path[0..idx], q }) catch null
            else
                std.fmt.bufPrint(buf, "{s}/rest/getSong?{s}&f=json", .{ path[0..idx], q }) catch null;
        }
    }
    return null;
}

pub fn parseSubsonicBpm(alloc: std.mem.Allocator, body: []const u8) f32 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return 0;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return 0,
    };
    const resp = switch (root.get("subsonic-response") orelse return 0) {
        .object => |o| o,
        else => return 0,
    };
    const song = switch (resp.get("song") orelse return 0) {
        .object => |o| o,
        else => return 0,
    };
    const bpmv = song.get("bpm") orelse return 0;
    const val: f32 = switch (bpmv) {
        .integer => |i| @floatFromInt(i),
        .float => |f| @floatCast(f),
        .string => |s| std.fmt.parseFloat(f32, s) catch 0,
        else => 0,
    };
    return if (val >= 20.0 and val <= 350.0) val else 0;
}

fn percentDecode(s: []const u8, buf: []u8) []const u8 {
    var o: usize = 0;
    var i: usize = 0;
    while (i < s.len and o < buf.len) : (o += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            if (std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16)) |val| {
                buf[o] = val;
                i += 3;
                continue;
            } else |_| {}
        }
        buf[o] = s[i];
        i += 1;
    }
    return buf[0..o];
}

/// Derives a cover art URL from remote stream/track URLs when album_art_url is omitted
/// (e.g. Navidrome/Subsonic /rest/stream and YouTube / YouTube Music watch URLs in cliamp v2.3.0 headless).
pub fn deriveRemoteArtUrl(path: []const u8, buf: []u8) ?[]const u8 {
    if (std.mem.startsWith(u8, path, "http://") or std.mem.startsWith(u8, path, "https://")) {
        const subsonic_needles = [_][]const u8{
            "/rest/stream.view?",
            "/rest/stream?",
            "/rest/download.view?",
            "/rest/download?",
        };
        for (subsonic_needles) |needle| {
            if (std.mem.indexOf(u8, path, needle)) |idx| {
                return std.fmt.bufPrint(buf, "{s}/rest/getCoverArt?{s}", .{ path[0..idx], path[idx + needle.len ..] }) catch null;
            }
        }

        if (std.mem.indexOf(u8, path, "youtube.com/watch") != null) {
            const vkey = if (std.mem.indexOf(u8, path, "?v=")) |i| i + 3 else if (std.mem.indexOf(u8, path, "&v=")) |i| i + 3 else return null;
            const rest = path[vkey..];
            const end = std.mem.indexOfAny(u8, rest, "&?#/") orelse rest.len;
            const id = rest[0..end];
            if (id.len == 11) {
                return std.fmt.bufPrint(buf, "https://i.ytimg.com/vi/{s}/hqdefault.jpg", .{id}) catch null;
            }
        } else if (std.mem.indexOf(u8, path, "youtu.be/")) |idx| {
            const rest = path[idx + "youtu.be/".len ..];
            const end = std.mem.indexOfAny(u8, rest, "&?#/") orelse rest.len;
            const id = rest[0..end];
            if (id.len == 11) {
                return std.fmt.bufPrint(buf, "https://i.ytimg.com/vi/{s}/hqdefault.jpg", .{id}) catch null;
            }
        }
    }
    return null;
}

fn rgbToHsv(r: f32, g: f32, b: f32) [3]f32 {
    const mx = @max(r, @max(g, b));
    const mn = @min(r, @min(g, b));
    const d = mx - mn;
    var h: f32 = 0;
    if (d > 1e-5) {
        if (mx == r) {
            h = @mod((g - b) / d, 6.0);
        } else if (mx == g) {
            h = (b - r) / d + 2.0;
        } else {
            h = (r - g) / d + 4.0;
        }
        h /= 6.0;
    }
    const s: f32 = if (mx > 1e-5) d / mx else 0;
    return .{ h, s, mx };
}

fn boost(c: [3]f32, min_peak: f32) Rgb {
    const mx = @max(c[0], @max(c[1], c[2]));
    const k: f32 = if (mx > 1e-3 and mx < min_peak) min_peak / mx else 1.0;
    return .{
        .r = @intFromFloat(@min(255.0, c[0] * k)),
        .g = @intFromFloat(@min(255.0, c[1] * k)),
        .b = @intFromFloat(@min(255.0, c[2] * k)),
    };
}

pub fn computePalette(img: *Image) void {
    const NB = 18;
    var w = [_]f32{0} ** NB;
    var sum = [_][3]f32{.{ 0, 0, 0 }} ** NB;
    var avg = [3]f32{ 0, 0, 0 };
    var n: f32 = 0;
    var i: usize = 0;
    while (i < SRC * SRC) : (i += 7) {
        const r: f32 = @floatFromInt(img.px[i * 3]);
        const g: f32 = @floatFromInt(img.px[i * 3 + 1]);
        const b: f32 = @floatFromInt(img.px[i * 3 + 2]);
        avg[0] += r;
        avg[1] += g;
        avg[2] += b;
        n += 1;
        const hsv = rgbToHsv(r / 255, g / 255, b / 255);
        const weight = hsv[1] * hsv[1] * hsv[2];
        const bi: usize = @min(NB - 1, @as(usize, @intFromFloat(hsv[0] * NB)));
        w[bi] += weight;
        sum[bi][0] += r * weight;
        sum[bi][1] += g * weight;
        sum[bi][2] += b * weight;
    }
    for (&avg) |*a| a.* /= n;
    img.avg = .{ .r = @intFromFloat(avg[0]), .g = @intFromFloat(avg[1]), .b = @intFromFloat(avg[2]) };

    var b1: usize = 0;
    for (0..NB) |k| if (w[k] > w[b1]) {
        b1 = k;
    };
    var b2: ?usize = null;
    for (0..NB) |k| {
        const dist = @min((k + NB - b1) % NB, (b1 + NB - k) % NB);
        if (dist < 3) continue;
        if (w[k] < w[b1] * 0.08) continue;
        if (b2 == null or w[k] > w[b2.?]) b2 = k;
    }
    const total_w = blk: {
        var t: f32 = 0;
        for (w) |x| t += x;
        break :blk t;
    };
    if (total_w / n < 0.02) {
        // nearly greyscale cover
        img.c1 = boost(avg, 230);
        img.c2 = .{ .r = 235, .g = 235, .b = 235 };
        return;
    }
    const c1 = [3]f32{ sum[b1][0] / w[b1], sum[b1][1] / w[b1], sum[b1][2] / w[b1] };
    img.c1 = boost(c1, 235);
    if (b2) |k| {
        img.c2 = boost(.{ sum[k][0] / w[k], sum[k][1] / w[k], sum[k][2] / w[k] }, 235);
    } else {
        // lighter variant of the main color
        img.c2 = boost(.{ c1[0] * 0.5 + 127, c1[1] * 0.5 + 127, c1[2] * 0.5 + 127 }, 240);
    }
}

/// Procedural black vinyl with a colored label, used when there is no cover.
pub fn placeholder(alloc: std.mem.Allocator, seed: u64) !*Image {
    const px = try alloc.alloc(u8, SRC * SRC * 3);
    const hue: f32 = @as(f32, @floatFromInt(seed % 360)) / 360.0;
    const label = hsvToRgb(hue, 0.75, 0.9);
    const c: f32 = @as(f32, SRC - 1) / 2.0;
    for (0..SRC) |y| {
        for (0..SRC) |x| {
            const dx = (@as(f32, @floatFromInt(x)) - c) / c;
            const dy = (@as(f32, @floatFromInt(y)) - c) / c;
            const r = @sqrt(dx * dx + dy * dy);
            var col: [3]f32 = undefined;
            if (r < 0.34) {
                col = label;
                // a stripe on the label makes the rotation visible
                if (@abs(dy) < 0.035 and dx > 0.08 and dx < 0.28) col = .{ 245, 245, 245 };
                if (r > 0.32) col = .{ col[0] * 0.7, col[1] * 0.7, col[2] * 0.7 };
            } else {
                const groove = 0.5 + 0.5 * @sin(r * 260.0);
                const v: f32 = 14 + 12 * groove + (if (r > 0.95) @as(f32, 10) else 0);
                col = .{ v, v, v + 2 };
            }
            const i = (y * SRC + x) * 3;
            px[i] = @intFromFloat(col[0]);
            px[i + 1] = @intFromFloat(col[1]);
            px[i + 2] = @intFromFloat(col[2]);
        }
    }
    const img = try alloc.create(Image);
    img.* = .{ .px = px, .is_placeholder = true };
    const l = Rgb{ .r = @intFromFloat(label[0]), .g = @intFromFloat(label[1]), .b = @intFromFloat(label[2]) };
    img.avg = .{ .r = l.r / 4, .g = l.g / 4, .b = l.b / 4 };
    img.c1 = l;
    img.c2 = boost(.{ label[0] * 0.5 + 127, label[1] * 0.5 + 127, label[2] * 0.5 + 127 }, 240);
    return img;
}

fn hsvToRgb(h: f32, s: f32, v: f32) [3]f32 {
    const i = @floor(h * 6);
    const f = h * 6 - i;
    const p = v * (1 - s);
    const q = v * (1 - f * s);
    const t = v * (1 - (1 - f) * s);
    const rgb: [3]f32 = switch (@as(u32, @intFromFloat(i)) % 6) {
        0 => .{ v, t, p },
        1 => .{ q, v, p },
        2 => .{ p, v, t },
        3 => .{ p, q, v },
        4 => .{ t, p, v },
        else => .{ v, p, q },
    };
    return .{ rgb[0] * 255, rgb[1] * 255, rgb[2] * 255 };
}

test "placeholder, percentDecode, data URL, sidecar, and bridge parsing" {
    const alloc = std.testing.allocator;

    // 1. Placeholder generation & palette
    const ph = try placeholder(alloc, 123);
    defer ph.destroy(alloc);
    try std.testing.expect(ph.is_placeholder);
    try std.testing.expectEqual(SRC * SRC * 3, ph.px.len);

    // 2. percentDecode
    var dbuf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("/a b/c%zz", percentDecode("/a%20b/c%zz", &dbuf));

    // 3. data: base64 PNG decode via ffmpeg + loadLocal sidecar
    var client = cliamp.Client{ .alloc = alloc };
    var loader = Loader{ .alloc = alloc, .client = &client };
    defer loader.bridge_url.deinit(alloc);

    // 1x1 red PNG
    const red_png_b64 = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC";
    const img_data = try loader.loadUrl(red_png_b64);
    defer img_data.destroy(alloc);
    try std.testing.expectEqual(SRC * SRC * 3, img_data.px.len);
    try std.testing.expect(img_data.avg.r > 200 and img_data.avg.g < 20);

    // 4. Sidecar cover.png + file:// URL
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const b64_part = red_png_b64["data:image/png;base64,".len..];
    const dec_len = try std.base64.standard.Decoder.calcSizeForSlice(b64_part);
    const png_bytes = try alloc.alloc(u8, dec_len);
    defer alloc.free(png_bytes);
    try std.base64.standard.Decoder.decode(png_bytes, b64_part);
    try tmp.dir.writeFile(.{ .sub_path = "cover.png", .data = png_bytes });
    try tmp.dir.writeFile(.{ .sub_path = "track.mp3", .data = "not a real mp3" });

    var pbuf: [512]u8 = undefined;
    const tmp_abs = try tmp.dir.realpath(".", &pbuf);
    var tbuf: [600]u8 = undefined;
    const track_abs = try std.fmt.bufPrint(&tbuf, "{s}/track.mp3", .{tmp_abs});
    const img_sidecar = try loader.loadLocal(track_abs);
    defer img_sidecar.destroy(alloc);
    try std.testing.expectEqual(SRC * SRC * 3, img_sidecar.px.len);
    try std.testing.expect(img_sidecar.avg.r > 200);

    var ubuf: [640]u8 = undefined;
    const file_url = try std.fmt.bufPrint(&ubuf, "file://{s}/cover.png", .{tmp_abs});
    const img_file = try loader.loadUrl(file_url);
    defer img_file.destroy(alloc);
    try std.testing.expect(img_file.avg.r > 200);

    // 5. Remote art URL derivation (Navidrome / Subsonic and YouTube Music)
    var rbuf: [512]u8 = undefined;
    const navi = deriveRemoteArtUrl("http://ubuntu01.local:30533/rest/stream?id=tr-42&u=cliamp&t=abc&s=xyz&v=1.16.1&c=cliamp", &rbuf);
    try std.testing.expectEqualStrings("http://ubuntu01.local:30533/rest/getCoverArt?id=tr-42&u=cliamp&t=abc&s=xyz&v=1.16.1&c=cliamp", navi.?);
    const yt = deriveRemoteArtUrl("https://music.youtube.com/watch?v=dQw4w9WgXcQ&list=RD1", &rbuf);
    try std.testing.expectEqualStrings("https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg", yt.?);
    try std.testing.expect(deriveRemoteArtUrl("/home/rob/Music/song.mp3", &rbuf) == null);

    // 6. Subsonic getSong URL derivation and BPM parsing
    const song_url = deriveSubsonicSongUrl("http://ubuntu01.local:30533/rest/stream?id=tr-42&u=cliamp&t=abc&s=xyz&v=1.16.1&c=cliamp", &rbuf);
    try std.testing.expectEqualStrings("http://ubuntu01.local:30533/rest/getSong?id=tr-42&u=cliamp&t=abc&s=xyz&v=1.16.1&c=cliamp&f=json", song_url.?);
    const bpm = parseSubsonicBpm(alloc, "{\"subsonic-response\":{\"status\":\"ok\",\"song\":{\"id\":\"tr-42\",\"bpm\":128}}}");
    try std.testing.expectEqual(@as(f32, 128.0), bpm);
    try std.testing.expectEqual(@as(f32, 0.0), parseSubsonicBpm(alloc, "{\"subsonic-response\":{\"status\":\"ok\",\"song\":{\"id\":\"tr-42\"}}}"));
}
