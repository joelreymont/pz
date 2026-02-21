const std = @import("std");

pub const Ev = union(enum) {
    scroll_up,
    scroll_down,
    press: Pos,
    release: Pos,

    pub const Pos = struct {
        x: usize,
        y: usize,
        btn: u8,
    };
};

pub const Result = struct {
    ev: Ev,
    len: usize,
};

/// Parse SGR mouse sequence: \x1b[<btn;x;yM or \x1b[<btn;x;ym
pub fn parse(buf: []const u8) ?Result {
    if (buf.len < 6) return null;
    if (buf[0] != '\x1b' or buf[1] != '[' or buf[2] != '<') return null;

    var i: usize = 3;
    const btn = parseNum(buf, &i) orelse return null;
    if (i >= buf.len or buf[i] != ';') return null;
    i += 1;
    const x = parseNum(buf, &i) orelse return null;
    if (i >= buf.len or buf[i] != ';') return null;
    i += 1;
    const y = parseNum(buf, &i) orelse return null;
    if (i >= buf.len) return null;

    const final = buf[i];
    if (final != 'M' and final != 'm') return null;
    i += 1;

    const is_press = final == 'M';
    const ev: Ev = switch (btn) {
        64 => .scroll_up,
        65 => .scroll_down,
        else => if (is_press) .{ .press = .{
            .x = if (x > 0) x - 1 else 0,
            .y = if (y > 0) y - 1 else 0,
            .btn = @intCast(btn & 0xff),
        } } else .{ .release = .{
            .x = if (x > 0) x - 1 else 0,
            .y = if (y > 0) y - 1 else 0,
            .btn = @intCast(btn & 0xff),
        } },
    };

    return .{ .ev = ev, .len = i };
}

fn parseNum(buf: []const u8, pos: *usize) ?usize {
    var i = pos.*;
    if (i >= buf.len or buf[i] < '0' or buf[i] > '9') return null;
    var val: usize = 0;
    while (i < buf.len and buf[i] >= '0' and buf[i] <= '9') {
        val = val * 10 + @as(usize, buf[i] - '0');
        i += 1;
    }
    pos.* = i;
    return val;
}

// ============================================================
// Tests
// ============================================================

test "parse scroll up" {
    const buf = "\x1b[<64;10;5M";
    const r = parse(buf).?;
    try std.testing.expect(r.ev == .scroll_up);
    try std.testing.expectEqual(buf.len, r.len);
}

test "parse scroll down" {
    const buf = "\x1b[<65;1;1M";
    const r = parse(buf).?;
    try std.testing.expect(r.ev == .scroll_down);
    try std.testing.expectEqual(buf.len, r.len);
}

test "parse button press" {
    const buf = "\x1b[<0;5;10M";
    const r = parse(buf).?;
    switch (r.ev) {
        .press => |p| {
            try std.testing.expectEqual(@as(usize, 4), p.x);
            try std.testing.expectEqual(@as(usize, 9), p.y);
            try std.testing.expectEqual(@as(u8, 0), p.btn);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse button release" {
    const buf = "\x1b[<0;3;7m";
    const r = parse(buf).?;
    switch (r.ev) {
        .release => |p| {
            try std.testing.expectEqual(@as(usize, 2), p.x);
            try std.testing.expectEqual(@as(usize, 6), p.y);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse returns null on short buf" {
    try std.testing.expect(parse("\x1b[<") == null);
    try std.testing.expect(parse("") == null);
    try std.testing.expect(parse("\x1b") == null);
}

test "parse returns null on bad prefix" {
    try std.testing.expect(parse("hello world") == null);
}

test "parse returns null on missing final" {
    try std.testing.expect(parse("\x1b[<0;1;1") == null);
}

test "parse returns null on bad final char" {
    try std.testing.expect(parse("\x1b[<0;1;1X") == null);
}

test "parse consumes exact length" {
    const buf = "\x1b[<64;1;1Mtrailing";
    const r = parse(buf).?;
    try std.testing.expectEqual(@as(usize, 10), r.len);
    try std.testing.expect(r.ev == .scroll_up);
}
