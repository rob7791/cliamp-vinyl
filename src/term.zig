//! Terminal setup: raw mode, alternate screen, window size, signal flags.
const std = @import("std");
const posix = std.posix;

pub var quit_requested = std.atomic.Value(bool).init(false);

var orig_termios: ?posix.termios = null;

fn onSignal(_: i32) callconv(.c) void {
    quit_requested.store(true, .release);
}

pub const Size = struct {
    cols: u16,
    rows: u16,
    xpix: u16,
    ypix: u16,
};

pub fn getSize() Size {
    var ws: posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const rc = posix.system.ioctl(posix.STDOUT_FILENO, posix.T.IOCGWINSZ, @intFromPtr(&ws));
    if (rc != 0 or ws.col == 0 or ws.row == 0) return .{ .cols = 80, .rows = 24, .xpix = 0, .ypix = 0 };
    return .{ .cols = ws.col, .rows = ws.row, .xpix = ws.xpixel, .ypix = ws.ypixel };
}

pub fn enter() !void {
    const fd = posix.STDIN_FILENO;
    const t = try posix.tcgetattr(fd);
    orig_termios = t;
    var raw = t;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.lflag.IEXTEN = false;
    raw.lflag.ISIG = false; // we handle ctrl-c ourselves
    raw.iflag.IXON = false;
    raw.iflag.ICRNL = false;
    raw.cc[@intFromEnum(posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;
    try posix.tcsetattr(fd, .FLUSH, raw);

    var act: posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &act, null);
    posix.sigaction(posix.SIG.TERM, &act, null);
    posix.sigaction(posix.SIG.HUP, &act, null);
    act.handler = .{ .handler = posix.SIG.IGN };
    posix.sigaction(posix.SIG.PIPE, &act, null);

    // alt screen, hide cursor, disable line wrap, clear
    writeAll("\x1b[?1049h\x1b[?25l\x1b[?7l\x1b[2J");
}

pub fn leave() void {
    writeAll("\x1b_Ga=d,d=A,q=2;\x1b\\\x1b[0m\x1b[2J\x1b[?7h\x1b[?25h\x1b[?1049l");
    if (orig_termios) |t| posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, t) catch {};
}

pub fn writeAll(bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = posix.write(posix.STDOUT_FILENO, bytes[off..]) catch |err| switch (err) {
            error.WouldBlock => {
                std.Thread.sleep(200 * std.time.ns_per_us);
                continue;
            },
            else => return,
        };
        off += n;
    }
}

/// Non-blocking read of pending input bytes.
pub fn readInput(buf: []u8) usize {
    return posix.read(posix.STDIN_FILENO, buf) catch 0;
}

/// Detects the active monitor refresh rate (Hz) on Linux (X11/XWayland/Wayland),
/// falling back to 60 if unavailable.
pub fn detectRefreshRate(alloc: std.mem.Allocator) u32 {
    if (runAndParse(alloc, &.{ "xrandr", "--current" }, parseXrandrHz)) |hz| return hz;
    if (runAndParse(alloc, &.{ "hyprctl", "monitors" }, parseAtHz)) |hz| return hz;
    if (runAndParse(alloc, &.{ "wlr-randr" }, parseWlrRandrHz)) |hz| return hz;
    return 60;
}

fn runAndParse(alloc: std.mem.Allocator, argv: []const []const u8, parser: fn ([]const u8) ?u32) ?u32 {
    const r = std.process.Child.run(.{
        .allocator = alloc,
        .argv = argv,
        .max_output_bytes = 256 * 1024,
    }) catch return null;
    defer alloc.free(r.stdout);
    defer alloc.free(r.stderr);
    if (r.term != .Exited or r.term.Exited != 0) return null;
    return parser(r.stdout);
}

fn parseXrandrHz(out: []const u8) ?u32 {
    var best: u32 = 0;
    var it = std.mem.tokenizeAny(u8, out, " \t\r\n");
    while (it.next()) |tok| {
        const star = std.mem.indexOfScalar(u8, tok, '*') orelse continue;
        if (star == 0) continue;
        const val = std.fmt.parseFloat(f32, tok[0..star]) catch continue;
        if (val >= 24.0 and val <= 360.0) {
            const hz: u32 = @intFromFloat(@round(val));
            if (hz > best) best = hz;
        }
    }
    if (best == 0) return null;
    return std.math.clamp(best, 30, 240);
}

fn parseAtHz(out: []const u8) ?u32 {
    var best: u32 = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, out, i, "@")) |at| {
        i = at + 1;
        var end = i;
        while (end < out.len and ((out[end] >= '0' and out[end] <= '9') or out[end] == '.')) : (end += 1) {}
        if (end == i) continue;
        const val = std.fmt.parseFloat(f32, out[i..end]) catch continue;
        if (val >= 24.0 and val <= 360.0) {
            const hz: u32 = @intFromFloat(@round(val));
            if (hz > best) best = hz;
        }
    }
    if (best == 0) return null;
    return std.math.clamp(best, 30, 240);
}

fn parseWlrRandrHz(out: []const u8) ?u32 {
    var best: u32 = 0;
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "current") == null) continue;
        const hz_pos = std.mem.indexOf(u8, line, " Hz") orelse continue;
        var start = hz_pos;
        while (start > 0 and ((line[start - 1] >= '0' and line[start - 1] <= '9') or line[start - 1] == '.')) : (start -= 1) {}
        if (start == hz_pos) continue;
        const val = std.fmt.parseFloat(f32, line[start..hz_pos]) catch continue;
        if (val >= 24.0 and val <= 360.0) {
            const hz: u32 = @intFromFloat(@round(val));
            if (hz > best) best = hz;
        }
    }
    if (best == 0) return null;
    return std.math.clamp(best, 30, 240);
}

test "refresh rate parsers extract active Hz" {
    try std.testing.expectEqual(@as(?u32, 120), parseXrandrHz("DP-2 connected\n   3840x2400    119.98*+  60.00\n"));
    try std.testing.expectEqual(@as(?u32, 144), parseAtHz("Monitor DP-1:\n\t2560x1440@143.99800 at 0x0\n"));
    try std.testing.expectEqual(@as(?u32, 120), parseWlrRandrHz("  2880x1800 px, 120.000000 Hz (preferred, current)\n"));
    try std.testing.expectEqual(@as(?u32, null), parseXrandrHz("no modes here\n"));
}
