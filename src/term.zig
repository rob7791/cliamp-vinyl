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
