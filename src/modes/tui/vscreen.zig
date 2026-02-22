const std = @import("std");
const wc = @import("wcwidth.zig");

/// Terminal color — default, 256-index, or 24-bit RGB.
pub const Color = union(enum) {
    default,
    idx: u8,
    rgb: u24,

    pub fn eql(a: Color, b: Color) bool {
        return switch (a) {
            .default => b == .default,
            .idx => |ai| switch (b) {
                .idx => |bi| ai == bi,
                else => false,
            },
            .rgb => |ar| switch (b) {
                .rgb => |br| ar == br,
                else => false,
            },
        };
    }
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
        return Color.eql(a.fg, b.fg) and
            Color.eql(a.bg, b.bg) and
            a.bold == b.bold and
            a.dim == b.dim and
            a.italic == b.italic and
            a.underline == b.underline and
            a.inverse == b.inverse;
    }
};

pub const Cell = struct {
    cp: u21 = ' ',
    style: Style = .{},
};

/// Virtual terminal screen for testing. Feed it ANSI output, then query cells.
pub const VScreen = struct {
    alloc: std.mem.Allocator,
    w: usize,
    h: usize,
    cells: []Cell,
    row: usize = 0,
    col: usize = 0,
    style: Style = .{},

    pub fn init(alloc: std.mem.Allocator, w: usize, h: usize) !VScreen {
        const cells = try alloc.alloc(Cell, w * h);
        @memset(cells, .{});
        return .{ .alloc = alloc, .w = w, .h = h, .cells = cells };
    }

    pub fn deinit(self: *VScreen) void {
        self.alloc.free(self.cells);
        self.* = undefined;
    }

    pub fn clear(self: *VScreen) void {
        @memset(self.cells, .{});
        self.row = 0;
        self.col = 0;
        self.style = .{};
    }

    pub fn cellAt(self: *const VScreen, r: usize, c: usize) Cell {
        if (r >= self.h or c >= self.w) return .{};
        return self.cells[r * self.w + c];
    }

    /// Extract text from a row range as a trimmed string.
    pub fn rowText(self: *const VScreen, alloc: std.mem.Allocator, r: usize) ![]u8 {
        if (r >= self.h) return try alloc.alloc(u8, 0);
        var buf = std.ArrayListUnmanaged(u8).empty;
        errdefer buf.deinit(alloc);
        var c: usize = 0;
        while (c < self.w) : (c += 1) {
            const cp = self.cells[r * self.w + c].cp;
            var enc: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &enc) catch 1;
            try buf.appendSlice(alloc, enc[0..n]);
        }
        // Trim trailing spaces.
        var end = buf.items.len;
        while (end > 0 and buf.items[end - 1] == ' ') end -= 1;
        buf.items.len = end;
        return try buf.toOwnedSlice(alloc);
    }

    // ── Feeding ──

    /// Feed raw ANSI bytes (renderer output with cursor movements).
    pub fn feed(self: *VScreen, data: []const u8) void {
        var i: usize = 0;
        while (i < data.len) {
            if (data[i] == 0x1b) {
                i = self.parseEsc(data, i);
            } else {
                self.putByte(data, &i);
            }
        }
    }

    /// Feed component output lines (one per row, starting at row 0).
    pub fn feedLines(self: *VScreen, lines: []const []const u8) void {
        self.row = 0;
        self.col = 0;
        self.style = .{};
        for (lines) |line| {
            self.col = 0;
            self.feed(line);
            self.row += 1;
            if (self.row >= self.h) break;
        }
    }

    fn putByte(self: *VScreen, data: []const u8, i: *usize) void {
        if (data[i.*] == '\n') {
            self.row += 1;
            self.col = 0;
            i.* += 1;
            return;
        }
        if (data[i.*] == '\r') {
            self.col = 0;
            i.* += 1;
            return;
        }
        // Decode UTF-8 codepoint.
        const n = std.unicode.utf8ByteSequenceLength(data[i.*]) catch {
            i.* += 1;
            return;
        };
        if (i.* + n > data.len) {
            i.* = data.len;
            return;
        }
        const cp = std.unicode.utf8Decode(data[i.* .. i.* + n]) catch {
            i.* += n;
            return;
        };
        const cw = wc.wcwidth(cp);
        if (self.row < self.h and self.col + cw <= self.w) {
            self.cells[self.row * self.w + self.col] = .{
                .cp = cp,
                .style = self.style,
            };
            // Fill trailing cells for wide chars with space placeholder
            var k: usize = 1;
            while (k < cw) : (k += 1) {
                self.cells[self.row * self.w + self.col + k] = .{
                    .cp = ' ',
                    .style = self.style,
                };
            }
            self.col += cw;
        }
        i.* += n;
    }

    fn parseEsc(self: *VScreen, data: []const u8, start: usize) usize {
        var i = start + 1; // skip ESC
        if (i >= data.len) return i;
        if (data[i] != '[') return i; // Only CSI supported.
        i += 1; // skip '['

        // Skip DEC private mode prefix (?  >  =)
        const is_private = i < data.len and (data[i] == '?' or data[i] == '>' or data[i] == '=');
        if (is_private) i += 1;

        // Collect params.
        var params: [16]u16 = .{0} ** 16;
        var pc: usize = 0;
        while (i < data.len) {
            if (data[i] >= '0' and data[i] <= '9') {
                if (pc < params.len) {
                    params[pc] = params[pc] *| 10 +| @as(u16, data[i] - '0');
                }
                i += 1;
            } else if (data[i] == ';') {
                pc += 1;
                i += 1;
            } else {
                break;
            }
        }
        if (i >= data.len) return i;
        pc += 1; // param count

        const final = data[i];
        i += 1;

        // Ignore DEC private mode sequences (e.g. ?25h, ?1049h, ?2026h)
        if (is_private) return i;

        switch (final) {
            'm' => self.applySgr(params[0..pc]),
            'H' => { // CUP
                self.row = if (pc >= 1 and params[0] > 0) params[0] - 1 else 0;
                self.col = if (pc >= 2 and params[1] > 0) params[1] - 1 else 0;
            },
            'A' => { // CUU
                const n: usize = if (pc >= 1 and params[0] > 0) params[0] else 1;
                self.row -|= n;
            },
            'B' => { // CUD
                const n: usize = if (pc >= 1 and params[0] > 0) params[0] else 1;
                self.row = @min(self.h -| 1, self.row + n);
            },
            'C' => { // CUF
                const n: usize = if (pc >= 1 and params[0] > 0) params[0] else 1;
                self.col = @min(self.w -| 1, self.col + n);
            },
            'D' => { // CUB
                const n: usize = if (pc >= 1 and params[0] > 0) params[0] else 1;
                self.col -|= n;
            },
            'J' => { // ED
                const mode: u16 = if (pc >= 1) params[0] else 0;
                if (mode == 2 or mode == 3) {
                    @memset(self.cells, .{});
                }
            },
            'K' => { // EL
                const mode: u16 = if (pc >= 1) params[0] else 0;
                if (mode == 0 or mode == 2) {
                    // Clear from cursor to end of line.
                    if (self.row < self.h) {
                        var c = self.col;
                        while (c < self.w) : (c += 1) {
                            self.cells[self.row * self.w + c] = .{};
                        }
                    }
                }
                if (mode == 1 or mode == 2) {
                    // Clear from start of line to cursor.
                    if (self.row < self.h) {
                        var c: usize = 0;
                        while (c <= self.col and c < self.w) : (c += 1) {
                            self.cells[self.row * self.w + c] = .{};
                        }
                    }
                }
            },
            else => {},
        }

        return i;
    }

    fn applySgr(self: *VScreen, params: []const u16) void {
        var i: usize = 0;
        while (i < params.len) {
            const p = params[i];
            switch (p) {
                0 => self.style = .{},
                1 => self.style.bold = true,
                2 => self.style.dim = true,
                3 => self.style.italic = true,
                4 => self.style.underline = true,
                7 => self.style.inverse = true,
                22 => {
                    self.style.bold = false;
                    self.style.dim = false;
                },
                23 => self.style.italic = false,
                24 => self.style.underline = false,
                27 => self.style.inverse = false,
                30...37 => self.style.fg = .{ .idx = @intCast(p - 30) },
                38 => {
                    i += 1;
                    self.style.fg = parseExtColor(params, &i);
                    continue; // i already advanced
                },
                39 => self.style.fg = .default,
                40...47 => self.style.bg = .{ .idx = @intCast(p - 40) },
                48 => {
                    i += 1;
                    self.style.bg = parseExtColor(params, &i);
                    continue;
                },
                49 => self.style.bg = .default,
                90...97 => self.style.fg = .{ .idx = @intCast(p - 90 + 8) },
                100...107 => self.style.bg = .{ .idx = @intCast(p - 100 + 8) },
                else => {},
            }
            i += 1;
        }
    }

    // ── Assertions ──

    pub fn expectText(self: *const VScreen, r: usize, c: usize, expected: []const u8) !void {
        var col = c;
        var it = (std.unicode.Utf8View.init(expected) catch return error.InvalidUtf8).iterator();
        while (it.nextCodepoint()) |exp_cp| {
            if (col >= self.w) return error.TestExpectedEqual;
            const cell = self.cellAt(r, col);
            if (cell.cp != exp_cp) {
                std.debug.print("expectText({},{}) codepoint mismatch: expected 0x{x} got 0x{x}\n", .{
                    r, col, @as(u21, exp_cp), cell.cp,
                });
                return error.TestExpectedEqual;
            }
            col += wc.wcwidth(exp_cp);
        }
    }

    pub fn expectFg(self: *const VScreen, r: usize, c: usize, expected: Color) !void {
        const cell = self.cellAt(r, c);
        if (!Color.eql(cell.style.fg, expected)) {
            std.debug.print("expectFg({},{}) mismatch\n", .{ r, c });
            return error.TestExpectedEqual;
        }
    }

    pub fn expectBg(self: *const VScreen, r: usize, c: usize, expected: Color) !void {
        const cell = self.cellAt(r, c);
        if (!Color.eql(cell.style.bg, expected)) {
            std.debug.print("expectBg({},{}) mismatch\n", .{ r, c });
            return error.TestExpectedEqual;
        }
    }

    pub fn expectBold(self: *const VScreen, r: usize, c: usize, expected: bool) !void {
        const cell = self.cellAt(r, c);
        if (cell.style.bold != expected) {
            std.debug.print("expectBold({},{}) expected {} got {}\n", .{ r, c, expected, cell.style.bold });
            return error.TestExpectedEqual;
        }
    }

    pub fn expectDim(self: *const VScreen, r: usize, c: usize, expected: bool) !void {
        const cell = self.cellAt(r, c);
        if (cell.style.dim != expected) return error.TestExpectedEqual;
    }

    pub fn expectItalic(self: *const VScreen, r: usize, c: usize, expected: bool) !void {
        const cell = self.cellAt(r, c);
        if (cell.style.italic != expected) return error.TestExpectedEqual;
    }
};

fn parseExtColor(params: []const u16, i: *usize) Color {
    if (i.* >= params.len) return .default;
    const mode = params[i.*];
    i.* += 1;
    switch (mode) {
        5 => { // 256-color
            if (i.* >= params.len) return .default;
            const idx = params[i.*];
            i.* += 1;
            return .{ .idx = @intCast(idx & 0xff) };
        },
        2 => { // truecolor
            if (i.* + 2 >= params.len) {
                i.* = params.len;
                return .default;
            }
            const r: u24 = @intCast(params[i.*] & 0xff);
            const g: u24 = @intCast(params[i.* + 1] & 0xff);
            const b: u24 = @intCast(params[i.* + 2] & 0xff);
            i.* += 3;
            return .{ .rgb = (r << 16) | (g << 8) | b };
        },
        else => return .default,
    }
}

// ── Tests ──

test "vscreen basic text rendering" {
    var vs = try VScreen.init(std.testing.allocator, 20, 3);
    defer vs.deinit();

    vs.feed("hello");
    try vs.expectText(0, 0, "hello");
    try std.testing.expectEqual(@as(usize, 0), vs.row);
    try std.testing.expectEqual(@as(usize, 5), vs.col);
}

test "vscreen cursor positioning" {
    var vs = try VScreen.init(std.testing.allocator, 20, 5);
    defer vs.deinit();

    vs.feed("\x1b[3;5Hxy");
    try vs.expectText(2, 4, "xy");
}

test "vscreen sgr basic colors" {
    var vs = try VScreen.init(std.testing.allocator, 20, 1);
    defer vs.deinit();

    vs.feed("\x1b[31mR\x1b[0mN");
    try vs.expectFg(0, 0, .{ .idx = 1 }); // red
    try vs.expectText(0, 0, "R");
    try vs.expectFg(0, 1, .default);
    try vs.expectText(0, 1, "N");
}

test "vscreen sgr truecolor" {
    var vs = try VScreen.init(std.testing.allocator, 20, 1);
    defer vs.deinit();

    vs.feed("\x1b[38;2;255;128;0mX\x1b[48;2;0;64;128mY");
    try vs.expectFg(0, 0, .{ .rgb = 0xff8000 });
    try vs.expectBg(0, 1, .{ .rgb = 0x004080 });
}

test "vscreen sgr 256-color" {
    var vs = try VScreen.init(std.testing.allocator, 20, 1);
    defer vs.deinit();

    vs.feed("\x1b[38;5;196mA\x1b[48;5;22mB");
    try vs.expectFg(0, 0, .{ .idx = 196 });
    try vs.expectBg(0, 1, .{ .idx = 22 });
}

test "vscreen bold and styles" {
    var vs = try VScreen.init(std.testing.allocator, 20, 1);
    defer vs.deinit();

    vs.feed("\x1b[1;3mBI\x1b[0mN");
    try vs.expectBold(0, 0, true);
    try vs.expectItalic(0, 0, true);
    try vs.expectBold(0, 2, false);
    try vs.expectItalic(0, 2, false);
}

test "vscreen compound sgr params" {
    var vs = try VScreen.init(std.testing.allocator, 20, 1);
    defer vs.deinit();

    // ESC[0;1;31m — reset then bold red
    vs.feed("\x1b[0;1;31mX");
    try vs.expectBold(0, 0, true);
    try vs.expectFg(0, 0, .{ .idx = 1 });
}

test "vscreen erase display and line" {
    var vs = try VScreen.init(std.testing.allocator, 10, 2);
    defer vs.deinit();

    vs.feed("ABCDE\x1b[2;1HFGHIJ");
    try vs.expectText(0, 0, "ABCDE");
    try vs.expectText(1, 0, "FGHIJ");

    vs.feed("\x1b[2J"); // clear all
    try vs.expectText(0, 0, "     ");
}

test "vscreen feedLines processes component output" {
    var vs = try VScreen.init(std.testing.allocator, 20, 3);
    defer vs.deinit();

    const lines = [_][]const u8{
        "line one",
        "\x1b[1mBOLD\x1b[0m normal",
        "third",
    };
    vs.feedLines(&lines);

    try vs.expectText(0, 0, "line one");
    try vs.expectText(1, 0, "BOLD");
    try vs.expectBold(1, 0, true);
    try vs.expectBold(1, 5, false);
    try vs.expectText(2, 0, "third");
}

test "vscreen rowText extracts trimmed row content" {
    var vs = try VScreen.init(std.testing.allocator, 20, 2);
    defer vs.deinit();

    vs.feed("hello world");
    const txt = try vs.rowText(std.testing.allocator, 0);
    defer std.testing.allocator.free(txt);
    try std.testing.expectEqualStrings("hello world", txt);
}

test "vscreen bright fg and bg colors" {
    var vs = try VScreen.init(std.testing.allocator, 10, 1);
    defer vs.deinit();

    vs.feed("\x1b[91mA\x1b[102mB");
    try vs.expectFg(0, 0, .{ .idx = 9 }); // bright red
    try vs.expectBg(0, 1, .{ .idx = 10 }); // bright green bg
}

test "vscreen cursor movement" {
    var vs = try VScreen.init(std.testing.allocator, 20, 5);
    defer vs.deinit();

    vs.feed("\x1b[3;10H*"); // row 3, col 10
    vs.feed("\x1b[2A^"); // up 2 -> row 1
    vs.feed("\x1b[3C>"); // right 3

    try vs.expectText(2, 9, "*");
    try vs.expectText(0, 10, "^");
    try vs.expectText(0, 14, ">");
}

test "vscreen handles newline and carriage return" {
    var vs = try VScreen.init(std.testing.allocator, 10, 3);
    defer vs.deinit();

    vs.feed("abc\ndef\r\nXY");
    try vs.expectText(0, 0, "abc");
    try vs.expectText(1, 0, "def");
    try vs.expectText(2, 0, "XY");
}
