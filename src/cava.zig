//! Spawns cava in raw binary stereo mode and keeps the latest frame.
const std = @import("std");
const posix = std.posix;

pub const max_bars = 256;

pub const Cava = struct {
    alloc: std.mem.Allocator,
    child: ?std.process.Child = null,
    fd: posix.fd_t = -1,
    per_channel: usize,
    conf_path: [256]u8 = undefined,
    conf_len: usize = 0,
    buf: [max_bars * 2 * 2 * 8]u8 = undefined,
    buf_len: usize = 0,
    /// Latest values, low -> high frequency, normalized 0..1.
    left: [max_bars]f32 = [_]f32{0} ** max_bars,
    right: [max_bars]f32 = [_]f32{0} ** max_bars,
    ok: bool = false,

    pub fn start(alloc: std.mem.Allocator, per_channel: usize, fps: u32, source: ?[]const u8) Cava {
        var self = Cava{ .alloc = alloc, .per_channel = @min(per_channel, max_bars) };
        self.spawn(fps, source) catch {
            self.ok = false;
        };
        return self;
    }

    fn spawn(self: *Cava, fps: u32, source: ?[]const u8) !void {
        const pid = std.os.linux.getpid();
        const path = try std.fmt.bufPrint(&self.conf_path, "/tmp/vinyl-cava-{d}.conf", .{pid});
        self.conf_len = path.len;

        var conf_buf: [1024]u8 = undefined;
        const conf = try std.fmt.bufPrint(&conf_buf,
            \\[general]
            \\framerate = {d}
            \\bars = {d}
            \\autosens = 1
            \\sleep_timer = 0
            \\lower_cutoff_freq = 40
            \\higher_cutoff_freq = 16000
            \\[input]
            \\method = pulse
            \\source = {s}
            \\[output]
            \\method = raw
            \\channels = stereo
            \\raw_target = /dev/stdout
            \\data_format = binary
            \\bit_format = 16bit
            \\[smoothing]
            \\noise_reduction = 0
            \\
        , .{ @min(fps, 240), self.per_channel * 2, source orelse "auto" });
        {
            const f = try std.fs.cwd().createFile(path, .{ .truncate = true });
            defer f.close();
            try f.writeAll(conf);
        }

        var child = std.process.Child.init(&.{ "cava", "-p", path }, self.alloc);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        try child.spawn();
        self.fd = child.stdout.?.handle;
        const flags = try posix.fcntl(self.fd, posix.F.GETFL, 0);
        const nonblock: usize = @as(u32, @bitCast(posix.O{ .NONBLOCK = true }));
        _ = try posix.fcntl(self.fd, posix.F.SETFL, flags | nonblock);
        self.child = child;
        self.ok = true;
    }

    /// Drains the pipe and decodes the most recent complete frame.
    /// Returns true if a new frame arrived.
    pub fn poll(self: *Cava) bool {
        if (!self.ok) return false;
        const frame_bytes = self.per_channel * 2 * 2;
        var got_frame = false;
        while (true) {
            if (self.buf_len == self.buf.len) {
                // keep only the trailing partial frame
                const keep = self.buf_len % frame_bytes;
                std.mem.copyForwards(u8, self.buf[0..keep], self.buf[self.buf_len - keep .. self.buf_len]);
                self.buf_len = keep;
            }
            const n = posix.read(self.fd, self.buf[self.buf_len..]) catch |err| switch (err) {
                error.WouldBlock => break,
                else => {
                    self.ok = false;
                    break;
                },
            };
            if (n == 0) {
                self.ok = false;
                break;
            }
            self.buf_len += n;
        }
        const frames = self.buf_len / frame_bytes;
        if (frames > 0) {
            const off = (frames - 1) * frame_bytes;
            self.decode(self.buf[off .. off + frame_bytes]);
            const rest = self.buf_len - frames * frame_bytes;
            std.mem.copyForwards(u8, self.buf[0..rest], self.buf[frames * frame_bytes .. self.buf_len]);
            self.buf_len = rest;
            got_frame = true;
        }
        return got_frame;
    }

    fn decode(self: *Cava, frame: []const u8) void {
        // cava stereo layout: [L high..low][R low..high]
        const n = self.per_channel;
        for (0..n) |i| {
            const li = (n - 1 - i) * 2;
            const ri = (n + i) * 2;
            const lv = std.mem.readInt(u16, frame[li..][0..2], .little);
            const rv = std.mem.readInt(u16, frame[ri..][0..2], .little);
            self.left[i] = @as(f32, @floatFromInt(lv)) / 65535.0;
            self.right[i] = @as(f32, @floatFromInt(rv)) / 65535.0;
        }
    }

    pub fn stop(self: *Cava) void {
        if (self.child) |*c| {
            _ = c.kill() catch {};
            self.child = null;
        }
        if (self.conf_len > 0) std.fs.cwd().deleteFile(self.conf_path[0..self.conf_len]) catch {};
    }
};
