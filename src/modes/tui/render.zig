const std = @import("std");
const frame = @import("frame.zig");

pub const Renderer = struct {
    alloc: std.mem.Allocator,
    prev: frame.Frame,
    cold: bool = true,

    pub const InitError = frame.Frame.InitError;
    pub const RenderError = error{SizeMismatch};

    pub fn init(alloc: std.mem.Allocator, w: usize, h: usize) InitError!Renderer {
        return .{
            .alloc = alloc,
            .prev = try frame.Frame.init(alloc, w, h),
            .cold = true,
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.prev.deinit(self.alloc);
    }

    pub fn reset(self: *Renderer) void {
        self.prev.clear();
        self.cold = true;
    }

    pub fn render(self: *Renderer, next: *const frame.Frame, out: anytype) (RenderError || anyerror)!void {
        if (self.prev.w != next.w or self.prev.h != next.h) return error.SizeMismatch;

        if (self.cold) {
            try out.writeAll("\x1b[0m\x1b[2J\x1b[H");
        }

        var cur_st = frame.Style{};
        var y: usize = 0;
        while (y < next.h) : (y += 1) {
            var x: usize = 0;
            while (x < next.w) {
                const i = y * next.w + x;
                if (frame.Cell.eql(self.prev.cells[i], next.cells[i])) {
                    x += 1;
                    continue;
                }

                const run_start = x;
                x += 1;
                while (x < next.w) : (x += 1) {
                    const j = y * next.w + x;
                    if (frame.Cell.eql(self.prev.cells[j], next.cells[j])) break;
                }

                try writeFmt(out, "\x1b[{};{}H", .{ y + 1, run_start + 1 });

                var col = run_start;
                while (col < x) : (col += 1) {
                    const c = next.cells[y * next.w + col];
                    if (!frame.Style.eql(cur_st, c.style)) {
                        try writeStyle(out, c.style);
                        cur_st = c.style;
                    }
                    try writeCodepoint(out, c.cp);
                }
            }
        }

        if (!cur_st.isDefault()) {
            try out.writeAll("\x1b[0m");
        }

        try self.prev.copyFrom(next);
        self.cold = false;
    }
};

fn writeFmt(out: anytype, comptime fmt: []const u8, args: anytype) !void {
    var buf: [64]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, fmt, args);
    try out.writeAll(msg);
}

fn writeStyle(out: anytype, st: frame.Style) !void {
    if (st.isDefault()) {
        try out.writeAll("\x1b[0m");
        return;
    }

    try out.writeAll("\x1b[0");
    if (st.bold) try out.writeAll(";1");
    if (st.dim) try out.writeAll(";2");
    if (st.italic) try out.writeAll(";3");
    if (st.underline) try out.writeAll(";4");
    if (st.inverse) try out.writeAll(";7");

    const fg = fgCode(st.fg);
    if (fg != 39) try writeFmt(out, ";{}", .{fg});

    const bg = bgCode(st.bg);
    if (bg != 49) try writeFmt(out, ";{}", .{bg});

    try out.writeAll("m");
}

fn writeCodepoint(out: anytype, cp: u21) !void {
    var buf: [4]u8 = undefined;
    const n = try std.unicode.utf8Encode(cp, &buf);
    try out.writeAll(buf[0..n]);
}

fn fgCode(color: frame.Color) u8 {
    return switch (color) {
        .default => 39,
        .black => 30,
        .red => 31,
        .green => 32,
        .yellow => 33,
        .blue => 34,
        .magenta => 35,
        .cyan => 36,
        .white => 37,
        .bright_black => 90,
        .bright_red => 91,
        .bright_green => 92,
        .bright_yellow => 93,
        .bright_blue => 94,
        .bright_magenta => 95,
        .bright_cyan => 96,
        .bright_white => 97,
    };
}

fn bgCode(color: frame.Color) u8 {
    return switch (color) {
        .default => 49,
        .black => 40,
        .red => 41,
        .green => 42,
        .yellow => 43,
        .blue => 44,
        .magenta => 45,
        .cyan => 46,
        .white => 47,
        .bright_black => 100,
        .bright_red => 101,
        .bright_green => 102,
        .bright_yellow => 103,
        .bright_blue => 104,
        .bright_magenta => 105,
        .bright_cyan => 106,
        .bright_white => 107,
    };
}

const TestBuf = struct {
    buf: []u8,
    len: usize = 0,

    fn init(buf: []u8) TestBuf {
        return .{ .buf = buf };
    }

    fn clear(self: *TestBuf) void {
        self.len = 0;
    }

    fn writeAll(self: *TestBuf, bytes: []const u8) !void {
        if (self.len + bytes.len > self.buf.len) return error.NoSpaceLeft;
        @memcpy(self.buf[self.len .. self.len + bytes.len], bytes);
        self.len += bytes.len;
    }

    fn view(self: *const TestBuf) []const u8 {
        return self.buf[0..self.len];
    }
};

test "renderer first frame clears and paints dirty runs" {
    var rnd = try Renderer.init(std.testing.allocator, 6, 2);
    defer rnd.deinit();

    var frm = try frame.Frame.init(std.testing.allocator, 6, 2);
    defer frm.deinit(std.testing.allocator);

    _ = try frm.write(0, 0, "AB", .{});
    _ = try frm.write(3, 1, "Q", .{});

    var raw: [256]u8 = undefined;
    var out = TestBuf.init(raw[0..]);
    try rnd.render(&frm, &out);

    try std.testing.expectEqualStrings(
        "\x1b[0m\x1b[2J\x1b[H\x1b[1;1HAB\x1b[2;4HQ",
        out.view(),
    );
}

test "renderer only emits changed cells after initial frame" {
    var rnd = try Renderer.init(std.testing.allocator, 4, 1);
    defer rnd.deinit();

    var frm = try frame.Frame.init(std.testing.allocator, 4, 1);
    defer frm.deinit(std.testing.allocator);

    _ = try frm.write(0, 0, "AB", .{});

    var raw: [256]u8 = undefined;
    var out = TestBuf.init(raw[0..]);

    try rnd.render(&frm, &out);
    out.clear();

    try frm.set(1, 0, 'Z', .{});
    try rnd.render(&frm, &out);

    try std.testing.expectEqualStrings("\x1b[1;2HZ", out.view());
}

test "renderer emits style transitions and resets to default" {
    var rnd = try Renderer.init(std.testing.allocator, 3, 1);
    defer rnd.deinit();

    var frm = try frame.Frame.init(std.testing.allocator, 3, 1);
    defer frm.deinit(std.testing.allocator);

    const emph = frame.Style{
        .fg = .red,
        .bold = true,
    };

    _ = try frm.write(0, 0, "AB", emph);
    _ = try frm.write(2, 0, "C", .{});

    var raw: [256]u8 = undefined;
    var out = TestBuf.init(raw[0..]);
    try rnd.render(&frm, &out);

    try std.testing.expectEqualStrings(
        "\x1b[0m\x1b[2J\x1b[H\x1b[1;1H\x1b[0;1;31mAB\x1b[0mC",
        out.view(),
    );
}

test "renderer rejects size mismatch" {
    var rnd = try Renderer.init(std.testing.allocator, 2, 1);
    defer rnd.deinit();

    var frm = try frame.Frame.init(std.testing.allocator, 1, 1);
    defer frm.deinit(std.testing.allocator);

    var raw: [64]u8 = undefined;
    var out = TestBuf.init(raw[0..]);

    try std.testing.expectError(error.SizeMismatch, rnd.render(&frm, &out));
}
