//! Kitty graphics protocol encoder (direct base64 chunked and file ring-buffer).
const std = @import("std");
const posix = std.posix;

pub const Mode = enum { direct, file };

pub fn isSupported() bool {
    if (posix.getenv("KITTY_WINDOW_ID") != null or
        posix.getenv("GHOSTTY_BIN_DIR") != null or
        posix.getenv("GHOSTTY_RESOURCES_DIR") != null or
        posix.getenv("WEZTERM_PANE") != null)
    {
        return true;
    }
    if (posix.getenv("TERM_PROGRAM")) |tp| {
        const supported = [_][]const u8{ "ghostty", "kitty", "WezTerm", "herdr", "konsole" };
        for (supported) |name| {
            if (std.mem.eql(u8, tp, name)) return true;
        }
    }
    if (posix.getenv("TERM")) |term| {
        if (std.mem.indexOf(u8, term, "kitty") != null or
            std.mem.indexOf(u8, term, "ghostty") != null)
        {
            return true;
        }
    }
    return false;
}

pub const Encoder = struct {
    alloc: std.mem.Allocator,
    mode: Mode = .direct,
    rgba: []u8 = &.{},
    b64: []u8 = &.{},
    side: usize = 0,
    slot: u8 = 0,
    last_col0: usize = 0,
    last_row0: usize = 0,
    last_cols: usize = 0,
    last_rows: usize = 0,
    placed: bool = false,
    file_used: [4]bool = .{ false, false, false, false },

    pub fn deinit(self: *Encoder) void {
        self.cleanup();
        if (self.rgba.len > 0) self.alloc.free(self.rgba);
        if (self.b64.len > 0) self.alloc.free(self.b64);
        self.* = .{ .alloc = self.alloc, .mode = self.mode };
    }

    pub fn ensureSize(self: *Encoder, side: usize) !void {
        if (self.side == side and self.rgba.len == side * side * 4) return;
        const nbytes = side * side * 4;
        if (self.rgba.len > 0) self.alloc.free(self.rgba);
        self.rgba = try self.alloc.alloc(u8, nbytes);
        self.side = side;

        if (self.mode == .direct) {
            const enc_len = std.base64.standard.Encoder.calcSize(nbytes);
            if (self.b64.len < enc_len) {
                if (self.b64.len > 0) self.alloc.free(self.b64);
                self.b64 = try self.alloc.alloc(u8, enc_len);
            }
        }
    }

    pub fn emitDeleteAll(out: *std.ArrayList(u8), alloc: std.mem.Allocator) !void {
        try out.appendSlice(alloc, "\x1b_Ga=d,d=A,q=2;\x1b\\");
    }

    pub fn emitFrame(
        self: *Encoder,
        out: *std.ArrayList(u8),
        alloc: std.mem.Allocator,
        col0: usize,
        row0: usize,
        c_cols: usize,
        c_rows: usize,
    ) !void {
        if (self.side == 0 or self.rgba.len != self.side * self.side * 4) return;
        if (self.placed and (col0 != self.last_col0 or row0 != self.last_row0 or c_cols != self.last_cols or c_rows != self.last_rows)) {
            try emitDeleteAll(out, alloc);
        }
        self.last_col0 = col0;
        self.last_row0 = row0;
        self.last_cols = c_cols;
        self.last_rows = c_rows;
        self.placed = true;

        var pos_buf: [64]u8 = undefined;
        const pos = try std.fmt.bufPrint(&pos_buf, "\x1b[{d};{d}H", .{ row0 + 1, col0 + 1 });
        try out.appendSlice(alloc, pos);

        switch (self.mode) {
            .direct => {
                const encoded = std.base64.standard.Encoder.encode(self.b64, self.rgba);
                const chunk_max: usize = 4096;
                var off: usize = 0;
                var first = true;
                while (off < encoded.len) {
                    const end = @min(encoded.len, off + chunk_max);
                    const more: u8 = if (end < encoded.len) 1 else 0;
                    if (first) {
                        var hdr_buf: [192]u8 = undefined;
                        const hdr = try std.fmt.bufPrint(
                            &hdr_buf,
                            "\x1b_Ga=T,t=d,f=32,s={d},v={d},c={d},r={d},i=1,p=1,z=0,C=1,q=2,m={d};",
                            .{ self.side, self.side, c_cols, c_rows, more },
                        );
                        try out.appendSlice(alloc, hdr);
                        first = false;
                    } else {
                        var hdr_buf: [32]u8 = undefined;
                        const hdr = try std.fmt.bufPrint(&hdr_buf, "\x1b_Gm={d};", .{more});
                        try out.appendSlice(alloc, hdr);
                    }
                    try out.appendSlice(alloc, encoded[off..end]);
                    try out.appendSlice(alloc, "\x1b\\");
                    off = end;
                }
            },
            .file => {
                self.slot = (self.slot + 1) % 4;
                var pbuf: [128]u8 = undefined;
                const pid = std.os.linux.getpid();
                const path = try std.fmt.bufPrint(&pbuf, "/tmp/vinyl-kitty-{d}-{d}.rgba", .{ pid, self.slot });
                {
                    const f = try std.fs.cwd().createFile(path, .{ .truncate = true });
                    defer f.close();
                    try f.writeAll(self.rgba);
                }
                self.file_used[self.slot] = true;

                var b64_path_buf: [256]u8 = undefined;
                const b64_path = std.base64.standard.Encoder.encode(&b64_path_buf, path);
                var hdr_buf: [192]u8 = undefined;
                const hdr = try std.fmt.bufPrint(
                    &hdr_buf,
                    "\x1b_Ga=T,t=f,f=32,s={d},v={d},c={d},r={d},i=1,p=1,z=0,C=1,q=2;",
                    .{ self.side, self.side, c_cols, c_rows },
                );
                try out.appendSlice(alloc, hdr);
                try out.appendSlice(alloc, b64_path);
                try out.appendSlice(alloc, "\x1b\\");
            },
        }
    }

    pub fn cleanup(self: *Encoder) void {
        const pid = std.os.linux.getpid();
        for (0..4) |s| {
            if (!self.file_used[s]) continue;
            var pbuf: [128]u8 = undefined;
            const path = std.fmt.bufPrint(&pbuf, "/tmp/vinyl-kitty-{d}-{d}.rgba", .{ pid, s }) catch continue;
            std.fs.cwd().deleteFile(path) catch {};
            self.file_used[s] = false;
        }
    }
};

test "direct chunking and placement delete on geometry change" {
    const alloc = std.testing.allocator;
    var enc = Encoder{ .alloc = alloc, .mode = .direct };
    defer enc.deinit();

    try enc.ensureSize(32); // 32*32*4 = 4096 raw -> > 4096 b64 (5464 bytes, 2 chunks)
    @memset(enc.rgba, 0xaa);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try enc.emitFrame(&out, alloc, 4, 2, 10, 5);
    try std.testing.expect(std.mem.startsWith(u8, out.items, "\x1b[3;5H\x1b_Ga=T,t=d,f=32,s=32,v=32,c=10,r=5,i=1,p=1,z=0,C=1,q=2,m=1;"));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b_Gm=0;") != null);

    out.clearRetainingCapacity();
    try enc.emitFrame(&out, alloc, 5, 2, 10, 5);
    try std.testing.expect(std.mem.startsWith(u8, out.items, "\x1b_Ga=d,d=A,q=2;\x1b\\"));
}

test "file mode writes slot and deletes on cleanup" {
    const alloc = std.testing.allocator;
    var enc = Encoder{ .alloc = alloc, .mode = .file };
    defer enc.deinit();

    try enc.ensureSize(4);
    @memset(enc.rgba, 0xff);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try enc.emitFrame(&out, alloc, 0, 0, 4, 2);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "a=T,t=f,f=32,s=4,v=4,c=4,r=2,i=1,p=1,z=0,C=1,q=2;") != null);
    try std.testing.expect(enc.file_used[1]);
    enc.cleanup();
    try std.testing.expect(!enc.file_used[1]);
}
