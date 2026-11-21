//! cliamp IPC client: polls the runtime snapshot and sends commands.
const std = @import("std");
const posix = std.posix;

pub fn Str(comptime N: usize) type {
    return struct {
        buf: [N]u8 = undefined,
        len: usize = 0,

        const Self = @This();

        pub fn set(self: *Self, s: []const u8) void {
            var n = @min(s.len, N);
            // don't cut a UTF-8 sequence in half
            while (n < s.len and n > 0 and (s[n] & 0xC0) == 0x80) n -= 1;
            @memcpy(self.buf[0..n], s[0..n]);
            self.len = n;
        }

        pub fn get(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }

        pub fn eql(self: *const Self, other: *const Self) bool {
            return std.mem.eql(u8, self.get(), other.get());
        }
    };
}

pub const PlayState = enum { unknown, playing, paused, stopped };

pub const Snapshot = struct {
    connected: bool = false,
    state: PlayState = .unknown,
    title: Str(256) = .{},
    artist: Str(256) = .{},
    album: Str(256) = .{},
    path: Str(2048) = .{},
    art_url: Str(4096) = .{},
    position: f64 = 0,
    duration: f64 = 0,
    volume: f64 = 0,
    bpm: f32 = 0,
    shuffle: bool = false,
    repeat: Str(8) = .{},
    /// monotonic timestamp (ns) when `position` was sampled
    stamp_ns: i128 = 0,
};

pub fn configDir(buf: []u8) ![]const u8 {
    if (posix.getenv("CLIAMP_CONFIG_DIR")) |d| return std.fmt.bufPrint(buf, "{s}", .{d});
    if (posix.getenv("XDG_CONFIG_HOME")) |d| return std.fmt.bufPrint(buf, "{s}/cliamp", .{d});
    const home = posix.getenv("HOME") orelse "/tmp";
    return std.fmt.bufPrint(buf, "{s}/.config/cliamp", .{home});
}

pub fn socketPath(buf: []u8) ![]const u8 {
    var dbuf: [480]u8 = undefined;
    const dir = try configDir(&dbuf);
    return std.fmt.bufPrint(buf, "{s}/cliamp.sock", .{dir});
}

fn connect(path: []const u8) !posix.socket_t {
    const s = try std.net.connectUnixSocket(path);
    const tv = posix.timeval{ .sec = 2, .usec = 0 };
    posix.setsockopt(s.handle, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
    return s.handle;
}

pub fn isAlive() bool {
    var pbuf: [512]u8 = undefined;
    const path = socketPath(&pbuf) catch return false;
    const fd = connect(path) catch return false;
    posix.close(fd);
    return true;
}

pub const Client = struct {
    alloc: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    snap: Snapshot = .{},
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    thread: ?std.Thread = null,

    cmd_mutex: std.Thread.Mutex = .{},
    cmds: [16]Str(256) = undefined,
    cmd_count: usize = 0,

    fd: ?posix.socket_t = null,
    line: std.ArrayList(u8) = .empty,
    rbuf: [65536]u8 = undefined,
    rlen: usize = 0,
    next_id: u64 = 1,

    pub fn start(self: *Client) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn stop(self: *Client) void {
        self.running.store(false, .release);
        if (self.thread) |t| t.join();
        if (self.fd) |fd| posix.close(fd);
        self.line.deinit(self.alloc);
    }

    pub fn get(self: *Client) Snapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.snap;
    }

    /// Queue an operation. `params_json` must be a JSON object literal.
    pub fn op(self: *Client, operation: []const u8, params_json: []const u8) void {
        self.cmd_mutex.lock();
        defer self.cmd_mutex.unlock();
        if (self.cmd_count >= self.cmds.len) return;
        var tmp: [256]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{s}\x00{s}", .{ operation, params_json }) catch return;
        self.cmds[self.cmd_count].set(s);
        self.cmd_count += 1;
    }

    fn disconnect(self: *Client) void {
        if (self.fd) |fd| posix.close(fd);
        self.fd = null;
        self.rlen = 0;
        self.mutex.lock();
        self.snap.connected = false;
        self.mutex.unlock();
    }

    fn send(self: *Client, bytes: []const u8) !void {
        const fd = self.fd orelse return error.NotConnected;
        var off: usize = 0;
        while (off < bytes.len) off += try posix.write(fd, bytes[off..]);
    }

    /// Reads one NDJSON line into self.line.
    fn readLine(self: *Client) ![]const u8 {
        const fd = self.fd orelse return error.NotConnected;
        self.line.clearRetainingCapacity();
        while (true) {
            if (std.mem.indexOfScalar(u8, self.rbuf[0..self.rlen], '\n')) |nl| {
                try self.line.appendSlice(self.alloc, self.rbuf[0..nl]);
                const rest = self.rlen - nl - 1;
                std.mem.copyForwards(u8, self.rbuf[0..rest], self.rbuf[nl + 1 .. self.rlen]);
                self.rlen = rest;
                return self.line.items;
            }
            try self.line.appendSlice(self.alloc, self.rbuf[0..self.rlen]);
            self.rlen = 0;
            if (self.line.items.len > 4 << 20) return error.LineTooLong;
            const n = try posix.read(fd, &self.rbuf);
            if (n == 0) return error.EndOfStream;
            self.rlen = n;
        }
    }

    fn request(self: *Client, body: []const u8) ![]const u8 {
        try self.send(body);
        return self.readLine();
    }

    fn run(self: *Client) void {
        var pbuf: [512]u8 = undefined;
        const path = socketPath(&pbuf) catch return;
        var last_state: i128 = 0;
        while (self.running.load(.acquire)) {
            if (self.fd == null) {
                self.fd = connect(path) catch null;
                if (self.fd == null) {
                    std.Thread.sleep(400 * std.time.ns_per_ms);
                    continue;
                }
            }
            self.flushCommands() catch {
                self.disconnect();
                continue;
            };
            const now = std.time.nanoTimestamp();
            if (now - last_state >= 150 * std.time.ns_per_ms) {
                last_state = now;
                self.pollState() catch {
                    self.disconnect();
                    continue;
                };
            }
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }

    fn flushCommands(self: *Client) !void {
        var local: [16]Str(256) = undefined;
        var n: usize = 0;
        {
            self.cmd_mutex.lock();
            defer self.cmd_mutex.unlock();
            n = self.cmd_count;
            for (0..n) |i| local[i] = self.cmds[i];
            self.cmd_count = 0;
        }
        for (local[0..n]) |*c| {
            const s = c.get();
            const sep = std.mem.indexOfScalar(u8, s, 0) orelse continue;
            var tmp: [512]u8 = undefined;
            const body = try std.fmt.bufPrint(&tmp,
                "{{\"version\":2,\"id\":\"c{d}\",\"method\":\"operation.submit\",\"operation\":\"{s}\",\"params\":{s}}}\n",
                .{ self.next_id, s[0..sep], s[sep + 1 ..] });
            self.next_id += 1;
            _ = try self.request(body);
        }
    }

    fn pollState(self: *Client) !void {
        const t0 = std.time.nanoTimestamp();
        const line = try self.request("{\"version\":2,\"id\":\"s\",\"method\":\"state.get\"}\n");
        const t1 = std.time.nanoTimestamp();

        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, line, .{}) catch return;
        defer parsed.deinit();
        const root = switch (parsed.value) {
            .object => |o| o,
            else => return,
        };
        const snapv = root.get("snapshot") orelse return;
        const snap = switch (snapv) {
            .object => |o| o,
            else => return,
        };

        var s = Snapshot{ .connected = true, .stamp_ns = @divTrunc(t0 + t1, 2) };
        if (getStr(snap, "state")) |st| {
            s.state = if (std.mem.eql(u8, st, "playing")) .playing else if (std.mem.eql(u8, st, "paused")) .paused else .stopped;
        }
        s.position = getNum(snap, "position");
        s.duration = getNum(snap, "duration");
        s.volume = getNum(snap, "volume");
        if (snap.get("shuffle")) |v| s.shuffle = v == .bool and v.bool;
        if (getStr(snap, "repeat")) |r| s.repeat.set(r);

        if (snap.get("track")) |tv| if (tv == .object) {
            const t = tv.object;
            if (getStr(t, "title")) |x| s.title.set(x);
            if (getStr(t, "artist")) |x| s.artist.set(x);
            if (getStr(t, "album")) |x| s.album.set(x);
            if (getStr(t, "path")) |x| s.path.set(x);
            const tbpm = getNum(t, "bpm");
            if (tbpm > 0) s.bpm = @floatCast(tbpm);
            // Any field that looks like a cover URL (never match "artist"!).
            var it = t.iterator();
            while (it.next()) |e| {
                const k = e.key_ptr.*;
                if (e.value_ptr.* != .string) continue;
                const v = e.value_ptr.string;
                if (v.len == 0 or v.len > 4096) continue;
                if (isArtUrlField(k, v)) {
                    s.art_url.set(v);
                    break;
                }
            }
        };

        self.mutex.lock();
        self.snap = s;
        self.mutex.unlock();
    }
};

fn getStr(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn getNum(o: std.json.ObjectMap, key: []const u8) f64 {
    const v = o.get(key) orelse return 0;
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => 0,
    };
}

fn isArtUrlField(k: []const u8, v: []const u8) bool {
    const key_match =
        std.mem.indexOf(u8, k, "art_url") != null or
        std.mem.indexOf(u8, k, "artUrl") != null or
        std.mem.indexOf(u8, k, "artwork") != null or
        std.mem.indexOf(u8, k, "cover") != null or
        std.mem.indexOf(u8, k, "image") != null or
        std.mem.indexOf(u8, k, "thumb") != null;
    if (!key_match) return false;
    return std.mem.startsWith(u8, v, "http://") or
        std.mem.startsWith(u8, v, "https://") or
        std.mem.startsWith(u8, v, "file://") or
        std.mem.startsWith(u8, v, "data:") or
        std.mem.startsWith(u8, v, "/");
}

test "isArtUrlField ignores artist and accepts real art URLs" {
    try std.testing.expect(!isArtUrlField("artist", "Toto"));
    try std.testing.expect(!isArtUrlField("album_artist", "Toto"));
    try std.testing.expect(!isArtUrlField("cover_id", "al-123"));
    try std.testing.expect(isArtUrlField("album_art_url", "https://i.scdn.co/image/abc"));
    try std.testing.expect(isArtUrlField("artUrl", "file:///tmp/cover.jpg"));
    try std.testing.expect(isArtUrlField("cover_path", "/home/user/cover.png"));
    try std.testing.expect(isArtUrlField("artwork", "data:image/png;base64,AAAA"));
}
