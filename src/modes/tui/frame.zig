const std = @import("std");

pub const Color = enum(u5) {
    default,
    black,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,
    bright_black,
    bright_red,
    bright_green,
    bright_yellow,
    bright_blue,
    bright_magenta,
    bright_cyan,
    bright_white,
};

pub const Style = struct {
    fg: Color = .default,
    bg: Color = .default,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    inverse: bool = false,

    pub fn eql(a: Style, b: Style) bool {
        return a.fg == b.fg and
            a.bg == b.bg and
            a.bold == b.bold and
            a.dim == b.dim and
            a.italic == b.italic and
            a.underline == b.underline and
            a.inverse == b.inverse;
    }

    pub fn isDefault(self: Style) bool {
        return eql(self, .{});
    }
};

pub const Cell = struct {
    cp: u21 = ' ',
    style: Style = .{},

    pub fn eql(a: Cell, b: Cell) bool {
        return a.cp == b.cp and Style.eql(a.style, b.style);
    }
};

pub const Frame = struct {
    w: usize,
    h: usize,
    cells: []Cell,

    pub const InitError = std.mem.Allocator.Error || error{InvalidSize};
    pub const PosError = error{OutOfBounds};
    pub const WriteError = PosError || error{InvalidUtf8};
    pub const CopyError = error{SizeMismatch};

    pub fn init(alloc: std.mem.Allocator, w: usize, h: usize) InitError!Frame {
        if (w == 0 or h == 0) return error.InvalidSize;
        const ct = std.math.mul(usize, w, h) catch return error.InvalidSize;

        const cells = try alloc.alloc(Cell, ct);
        @memset(cells, .{});

        return .{
            .w = w,
            .h = h,
            .cells = cells,
        };
    }

    pub fn deinit(self: *Frame, alloc: std.mem.Allocator) void {
        alloc.free(self.cells);
        self.* = undefined;
    }

    pub fn clear(self: *Frame) void {
        @memset(self.cells, .{});
    }

    pub fn idx(self: *const Frame, x: usize, y: usize) PosError!usize {
        if (x >= self.w or y >= self.h) return error.OutOfBounds;
        return y * self.w + x;
    }

    pub fn cell(self: *const Frame, x: usize, y: usize) PosError!Cell {
        return self.cells[try self.idx(x, y)];
    }

    pub fn setCell(self: *Frame, x: usize, y: usize, c: Cell) PosError!void {
        self.cells[try self.idx(x, y)] = c;
    }

    pub fn set(self: *Frame, x: usize, y: usize, cp: u21, style: Style) PosError!void {
        return self.setCell(x, y, .{
            .cp = cp,
            .style = style,
        });
    }

    pub fn write(self: *Frame, x: usize, y: usize, text: []const u8, style: Style) WriteError!usize {
        if (x >= self.w or y >= self.h) return error.OutOfBounds;

        var col = x;
        var ct: usize = 0;
        var it = (try std.unicode.Utf8View.init(text)).iterator();
        while (col < self.w) : (col += 1) {
            const cp = it.nextCodepoint() orelse break;
            self.cells[y * self.w + col] = .{ .cp = cp, .style = style };
            ct += 1;
        }

        return ct;
    }

    pub fn copyFrom(self: *Frame, other: *const Frame) CopyError!void {
        if (self.w != other.w or self.h != other.h) return error.SizeMismatch;
        std.mem.copyForwards(Cell, self.cells, other.cells);
    }

    pub fn eql(self: *const Frame, other: *const Frame) bool {
        if (self.w != other.w or self.h != other.h) return false;
        for (self.cells, other.cells) |a, b| {
            if (!Cell.eql(a, b)) return false;
        }
        return true;
    }
};

test "frame write clips utf8 input at row width" {
    var f = try Frame.init(std.testing.allocator, 4, 2);
    defer f.deinit(std.testing.allocator);

    const st = Style{
        .fg = .green,
        .underline = true,
    };

    const text = "A\xCE\xB2ZQ";
    const wrote = try f.write(1, 0, text, st);
    try std.testing.expectEqual(@as(usize, 3), wrote);

    const c1 = try f.cell(1, 0);
    const c2 = try f.cell(2, 0);
    const c3 = try f.cell(3, 0);

    try std.testing.expectEqual(@as(u21, 'A'), c1.cp);
    try std.testing.expectEqual(@as(u21, 0x03b2), c2.cp);
    try std.testing.expectEqual(@as(u21, 'Z'), c3.cp);
    try std.testing.expect(Style.eql(st, c1.style));
    try std.testing.expect(Style.eql(st, c2.style));
    try std.testing.expect(Style.eql(st, c3.style));
}

test "frame write validates bounds and utf8" {
    var f = try Frame.init(std.testing.allocator, 2, 1);
    defer f.deinit(std.testing.allocator);

    try std.testing.expectError(error.OutOfBounds, f.write(2, 0, "x", .{}));

    const bad = [_]u8{0xff};
    try std.testing.expectError(error.InvalidUtf8, f.write(0, 0, bad[0..], .{}));
}

test "frame copy requires matching size" {
    var a = try Frame.init(std.testing.allocator, 3, 1);
    defer a.deinit(std.testing.allocator);

    var b = try Frame.init(std.testing.allocator, 3, 1);
    defer b.deinit(std.testing.allocator);

    var c = try Frame.init(std.testing.allocator, 2, 1);
    defer c.deinit(std.testing.allocator);

    _ = try a.write(0, 0, "abc", .{});
    try b.copyFrom(&a);
    try std.testing.expect(b.eql(&a));

    try std.testing.expectError(error.SizeMismatch, c.copyFrom(&a));
}
