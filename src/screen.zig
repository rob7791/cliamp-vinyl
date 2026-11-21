//! Cell buffer with diff-based truecolor emitter.
const std = @import("std");

pub const Rgb = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,

    pub fn eql(a: Rgb, b: Rgb) bool {
        return a.r == b.r and a.g == b.g and a.b == b.b;
    }
};

pub const Cell = struct {
    cp: u21 = ' ',
    fg: Rgb = .{},
    bg: Rgb = .{},
    bold: bool = false,

    fn eql(a: Cell, b: Cell) bool {
        return a.cp == b.cp and a.fg.eql(b.fg) and a.bg.eql(b.bg) and a.bold == b.bold;
    }
};

pub const Screen = struct {
    alloc: std.mem.Allocator,
    cols: usize = 0,
    rows: usize = 0,
    cells: []Cell = &.{},
    prev: []Cell = &.{},
    force: bool = true,
    out: std.ArrayList(u8) = .empty,

    pub fn init(alloc: std.mem.Allocator) Screen {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Screen) void {
        self.alloc.free(self.cells);
        self.alloc.free(self.prev);
        self.out.deinit(self.alloc);
    }

    pub fn resize(self: *Screen, cols: usize, rows: usize) !void {
        if (cols == self.cols and rows == self.rows) return;
        self.alloc.free(self.cells);
        self.alloc.free(self.prev);
        self.cells = try self.alloc.alloc(Cell, cols * rows);
        self.prev = try self.alloc.alloc(Cell, cols * rows);
        @memset(self.cells, .{});
        @memset(self.prev, .{});
        self.cols = cols;
        self.rows = rows;
        self.force = true;
    }

    pub inline fn at(self: *Screen, c: usize, r: usize) *Cell {
        return &self.cells[r * self.cols + c];
    }

    pub fn fill(self: *Screen, cell: Cell) void {
        @memset(self.cells, cell);
    }

    /// Writes UTF-8 text at (c, r); returns the column after the text.
    pub fn text(self: *Screen, c0: usize, r: usize, s: []const u8, fg: Rgb, bold: bool) usize {
        return self.textAlpha(c0, r, s, fg, bold, 1.0);
    }

    /// Writes UTF-8 text at (c, r) blended against each cell's existing background by `alpha` (0..1).
    /// Preserves cell.bg so the text floats with no background box.
    pub fn textAlpha(self: *Screen, c0: usize, r: usize, s: []const u8, fg: Rgb, bold: bool, alpha: f32) usize {
        if (r >= self.rows or alpha <= 0.01) return c0;
        const a = std.math.clamp(alpha, 0.0, 1.0);
        const ia = 1.0 - a;
        var c = c0;
        var it = (std.unicode.Utf8View.init(s) catch return c0).iterator();
        while (it.nextCodepoint()) |cp| {
            if (c >= self.cols) break;
            const cell = self.at(c, r);
            cell.cp = if (cp < 0x20) ' ' else cp;
            if (a >= 0.995) {
                cell.fg = fg;
            } else {
                cell.fg = .{
                    .r = @intFromFloat(@as(f32, @floatFromInt(cell.bg.r)) * ia + @as(f32, @floatFromInt(fg.r)) * a),
                    .g = @intFromFloat(@as(f32, @floatFromInt(cell.bg.g)) * ia + @as(f32, @floatFromInt(fg.g)) * a),
                    .b = @intFromFloat(@as(f32, @floatFromInt(cell.bg.b)) * ia + @as(f32, @floatFromInt(fg.b)) * a),
                };
            }
            cell.bold = bold and a >= 0.35;
            c += 1;
        }
        return c;
    }

    fn put(self: *Screen, bytes: []const u8) !void {
        try self.out.appendSlice(self.alloc, bytes);
    }

    fn putNum(self: *Screen, v: usize) !void {
        var buf: [20]u8 = undefined;
        var i: usize = buf.len;
        var n = v;
        if (n == 0) {
            i -= 1;
            buf[i] = '0';
        }
        while (n > 0) : (n /= 10) {
            i -= 1;
            buf[i] = @intCast('0' + n % 10);
        }
        try self.put(buf[i..]);
    }

    fn putRgb(self: *Screen, c: Rgb) !void {
        try self.putNum(c.r);
        try self.put(";");
        try self.putNum(c.g);
        try self.put(";");
        try self.putNum(c.b);
    }

    /// Builds the escape stream for changed cells plus optional Kitty payload. Returns bytes to write.
    pub fn flush(self: *Screen, kitty_payload: []const u8) ![]const u8 {
        self.out.clearRetainingCapacity();
        try self.put("\x1b[?2026h"); // begin synchronized update
        if (self.force) try self.put("\x1b[0m");

        var cur_fg: ?Rgb = null;
        var cur_bg: ?Rgb = null;
        var cur_bold = false;
        var cur_r: usize = std.math.maxInt(usize);
        var cur_c: usize = std.math.maxInt(usize);

        for (0..self.rows) |r| {
            for (0..self.cols) |c| {
                const i = r * self.cols + c;
                const cell = self.cells[i];
                if (!self.force and cell.eql(self.prev[i])) continue;
                if (r != cur_r or c != cur_c) {
                    try self.put("\x1b[");
                    try self.putNum(r + 1);
                    try self.put(";");
                    try self.putNum(c + 1);
                    try self.put("H");
                }
                if (cell.bold != cur_bold) {
                    try self.put(if (cell.bold) "\x1b[1m" else "\x1b[22m");
                    cur_bold = cell.bold;
                }
                const need_fg = cur_fg == null or !cur_fg.?.eql(cell.fg);
                const need_bg = cur_bg == null or !cur_bg.?.eql(cell.bg);
                if (need_fg or need_bg) {
                    try self.put("\x1b[");
                    if (need_fg) {
                        try self.put("38;2;");
                        try self.putRgb(cell.fg);
                        if (need_bg) try self.put(";");
                    }
                    if (need_bg) {
                        try self.put("48;2;");
                        try self.putRgb(cell.bg);
                    }
                    try self.put("m");
                    cur_fg = cell.fg;
                    cur_bg = cell.bg;
                }
                var u: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cell.cp, &u) catch blk: {
                    u[0] = '?';
                    break :blk 1;
                };
                try self.put(u[0..len]);
                cur_r = r;
                cur_c = c + 1;
            }
        }
        if (kitty_payload.len > 0) try self.put(kitty_payload);
        try self.put("\x1b[?2026l");
        @memcpy(self.prev, self.cells);
        self.force = false;
        return self.out.items;
    }
};
