const std = @import("std");

pub const chars = [_]u21{
    0x280B, // ⠋
    0x2819, // ⠙
    0x2839, // ⠹
    0x2838, // ⠸
    0x283C, // ⠼
    0x2834, // ⠴
    0x2826, // ⠦
    0x2827, // ⠧
    0x2807, // ⠇
    0x280F, // ⠏
};

pub fn cp(idx: u8) u21 {
    return chars[idx % chars.len];
}

pub fn utf8(idx: u8, buf: *[4]u8) []const u8 {
    const n = std.unicode.utf8Encode(cp(idx), buf) catch unreachable;
    return buf[0..n];
}
