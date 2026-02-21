const std = @import("std");
const frame = @import("frame.zig");

pub const ColorCap = enum {
    none,
    basic,
    c256,
    truecolor,
};

pub fn detect() ColorCap {
    if (std.posix.getenv("NO_COLOR") != null) return .none;

    if (std.posix.getenv("COLORTERM")) |ct| {
        if (std.mem.eql(u8, ct, "truecolor") or std.mem.eql(u8, ct, "24bit"))
            return .truecolor;
    }

    if (std.posix.getenv("TERM")) |term| {
        if (std.mem.eql(u8, term, "dumb")) return .none;
        if (std.mem.indexOf(u8, term, "256color") != null) return .c256;
        // Known limited terminals get basic
        if (std.mem.eql(u8, term, "linux") or std.mem.eql(u8, term, "vt100"))
            return .basic;
    }

    // Most modern terminals support truecolor even without advertising it
    return .truecolor;
}

/// Convert 0-255 channel to 6-level cube index.
fn chanTo6(v: u8) u8 {
    if (v < 48) return 0;
    return @intCast((@as(u16, v) - 35) / 40);
}

/// Reverse: cube index → representative 0-255 value.
fn cubeVal(i: u8) u8 {
    if (i == 0) return 0;
    return @as(u8, i) * 40 + 55;
}

/// Squared distance between two u8 values.
fn sq(a: u8, b: u8) u32 {
    const d: i32 = @as(i32, a) - @as(i32, b);
    return @intCast(d * d);
}

pub fn rgbTo256(r: u8, g: u8, b: u8) u8 {
    // Cube approximation
    const cr = chanTo6(r);
    const cg = chanTo6(g);
    const cb = chanTo6(b);
    const cube_idx: u8 = 16 + 36 * cr + 6 * cg + cb;
    const cube_dist = sq(r, cubeVal(cr)) + sq(g, cubeVal(cg)) + sq(b, cubeVal(cb));

    // Grayscale approximation (values 8, 18, 28, ..., 238)
    const avg: u8 = @intCast((@as(u16, r) + @as(u16, g) + @as(u16, b)) / 3);
    const gi: u8 = if (avg < 4) 0 else if (avg > 243) 23 else @intCast((@as(u16, avg) - 3) / 10);
    const gv: u8 = gi * 10 + 8;
    const gray_dist = sq(r, gv) + sq(g, gv) + sq(b, gv);

    if (gray_dist < cube_dist) {
        return 232 + gi;
    }
    return cube_idx;
}

/// Map RGB to nearest basic color (0-7).
pub fn rgbToBasic(r: u8, g: u8, b: u8) u3 {
    // Basic ANSI: 0=black 1=red 2=green 3=yellow 4=blue 5=magenta 6=cyan 7=white
    // Use simple threshold decomposition.
    const rb: u1 = if (r >= 128) 1 else 0;
    const gb: u1 = if (g >= 128) 1 else 0;
    const bb: u1 = if (b >= 128) 1 else 0;
    // ANSI order: bit0=red, bit1=green, bit2=blue
    return @as(u3, bb) << 2 | @as(u3, gb) << 1 | rb;
}

pub fn writeColor(out: anytype, layer: Layer, c: frame.Color, cap: ColorCap) !void {
    const base = @intFromEnum(layer);
    switch (cap) {
        .none => {},
        .truecolor => switch (c) {
            .default => {},
            .idx => |n| try writeFmt(out, ";{};5;{}", .{ base, n }),
            .rgb => |v| try writeFmt(out, ";{};2;{};{};{}", .{
                base, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff,
            }),
        },
        .c256 => switch (c) {
            .default => {},
            .idx => |n| try writeFmt(out, ";{};5;{}", .{ base, n }),
            .rgb => |v| {
                const r: u8 = @intCast((v >> 16) & 0xff);
                const g: u8 = @intCast((v >> 8) & 0xff);
                const b: u8 = @intCast(v & 0xff);
                try writeFmt(out, ";{};5;{}", .{ base, rgbTo256(r, g, b) });
            },
        },
        .basic => switch (c) {
            .default => {},
            .idx => |n| {
                // idx 0-7 → basic, 8-15 → bright basic, else → convert
                if (n < 8) {
                    const off: u8 = if (base == 38) 30 else 40;
                    try writeFmt(out, ";{}", .{off + n});
                } else if (n < 16) {
                    const off: u8 = if (base == 38) 90 else 100;
                    try writeFmt(out, ";{}", .{off + n - 8});
                } else {
                    // Convert 256-color idx to rgb, then to basic
                    const rgb = idx256ToRgb(n);
                    const bi = rgbToBasic(rgb[0], rgb[1], rgb[2]);
                    const off: u8 = if (base == 38) 30 else 40;
                    try writeFmt(out, ";{}", .{off + @as(u8, bi)});
                }
            },
            .rgb => |v| {
                const r: u8 = @intCast((v >> 16) & 0xff);
                const g: u8 = @intCast((v >> 8) & 0xff);
                const b: u8 = @intCast(v & 0xff);
                const bi = rgbToBasic(r, g, b);
                const off: u8 = if (base == 38) 30 else 40;
                try writeFmt(out, ";{}", .{off + @as(u8, bi)});
            },
        },
    }
}

fn idx256ToRgb(n: u8) [3]u8 {
    if (n < 16) {
        // Standard colors - approximate
        const table = [16][3]u8{
            .{ 0, 0, 0 },       .{ 128, 0, 0 },   .{ 0, 128, 0 },   .{ 128, 128, 0 },
            .{ 0, 0, 128 },     .{ 128, 0, 128 }, .{ 0, 128, 128 }, .{ 192, 192, 192 },
            .{ 128, 128, 128 }, .{ 255, 0, 0 },   .{ 0, 255, 0 },   .{ 255, 255, 0 },
            .{ 0, 0, 255 },     .{ 255, 0, 255 }, .{ 0, 255, 255 }, .{ 255, 255, 255 },
        };
        return table[n];
    } else if (n < 232) {
        const ci = n - 16;
        const ri = ci / 36;
        const gi = (ci % 36) / 6;
        const bi = ci % 6;
        return .{ cubeVal(ri), cubeVal(gi), cubeVal(bi) };
    } else {
        const v = (n - 232) * 10 + 8;
        return .{ v, v, v };
    }
}

pub const Layer = enum(u8) {
    fg = 38,
    bg = 48,
};

fn writeFmt(out: anytype, comptime fmt: []const u8, args: anytype) !void {
    var buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return error.NoSpaceLeft;
    try out.writeAll(msg);
}

// ---- Tests ----

test "rgbTo256 pure black" {
    try std.testing.expectEqual(@as(u8, 16), rgbTo256(0, 0, 0));
}

test "rgbTo256 pure white" {
    try std.testing.expectEqual(@as(u8, 231), rgbTo256(255, 255, 255));
}

test "rgbTo256 midgray hits grayscale ramp" {
    const idx = rgbTo256(128, 128, 128);
    // Should be in grayscale range 232-255
    try std.testing.expect(idx >= 232 and idx <= 255);
    // Value should be close to 128: idx 232+12 = 244, val = 128
    try std.testing.expectEqual(@as(u8, 244), idx);
}

test "rgbTo256 saturated red" {
    // Pure red (255,0,0) → cube index 16 + 36*5 + 0 + 0 = 196
    try std.testing.expectEqual(@as(u8, 196), rgbTo256(255, 0, 0));
}

test "rgbTo256 saturated green" {
    try std.testing.expectEqual(@as(u8, 46), rgbTo256(0, 255, 0));
}

test "rgbTo256 saturated blue" {
    try std.testing.expectEqual(@as(u8, 21), rgbTo256(0, 0, 255));
}

test "rgbToBasic thresholds" {
    try std.testing.expectEqual(@as(u3, 0), rgbToBasic(0, 0, 0)); // black
    try std.testing.expectEqual(@as(u3, 7), rgbToBasic(255, 255, 255)); // white
    try std.testing.expectEqual(@as(u3, 1), rgbToBasic(255, 0, 0)); // red
    try std.testing.expectEqual(@as(u3, 2), rgbToBasic(0, 255, 0)); // green
    try std.testing.expectEqual(@as(u3, 4), rgbToBasic(0, 0, 255)); // blue
    try std.testing.expectEqual(@as(u3, 3), rgbToBasic(255, 255, 0)); // yellow
    try std.testing.expectEqual(@as(u3, 5), rgbToBasic(255, 0, 255)); // magenta
    try std.testing.expectEqual(@as(u3, 6), rgbToBasic(0, 255, 255)); // cyan
}

test "writeColor truecolor emits rgb" {
    var buf: [64]u8 = undefined;
    var out = TestBuf.init(&buf);
    try writeColor(&out, .fg, .{ .rgb = 0xff8000 }, .truecolor);
    try std.testing.expectEqualStrings(";38;2;255;128;0", out.view());
}

test "writeColor c256 converts rgb to index" {
    var buf: [64]u8 = undefined;
    var out = TestBuf.init(&buf);
    try writeColor(&out, .fg, .{ .rgb = 0xff0000 }, .c256);
    try std.testing.expectEqualStrings(";38;5;196", out.view());
}

test "writeColor basic converts rgb" {
    var buf: [64]u8 = undefined;
    var out = TestBuf.init(&buf);
    try writeColor(&out, .fg, .{ .rgb = 0xff0000 }, .basic);
    try std.testing.expectEqualStrings(";31", out.view());
}

test "writeColor none emits nothing" {
    var buf: [64]u8 = undefined;
    var out = TestBuf.init(&buf);
    try writeColor(&out, .fg, .{ .rgb = 0xff0000 }, .none);
    try std.testing.expectEqualStrings("", out.view());
}

test "writeColor basic idx passthrough for 0-7" {
    var buf: [64]u8 = undefined;
    var out = TestBuf.init(&buf);
    try writeColor(&out, .fg, .{ .idx = 3 }, .basic);
    try std.testing.expectEqualStrings(";33", out.view());
}

test "writeColor basic bg idx" {
    var buf: [64]u8 = undefined;
    var out = TestBuf.init(&buf);
    try writeColor(&out, .bg, .{ .idx = 1 }, .basic);
    try std.testing.expectEqualStrings(";41", out.view());
}

const TestBuf = struct {
    buf: []u8,
    len: usize = 0,

    fn init(buf: []u8) TestBuf {
        return .{ .buf = buf };
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
