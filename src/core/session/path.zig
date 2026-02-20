const std = @import("std");

pub fn sidJsonlAlloc(alloc: std.mem.Allocator, sid: []const u8) ![]u8 {
    return sidExtAlloc(alloc, sid, ".jsonl");
}

pub fn sidExtAlloc(
    alloc: std.mem.Allocator,
    sid: []const u8,
    ext: []const u8,
) ![]u8 {
    try validateSid(sid);
    if (ext.len == 0) return error.InvalidExtension;
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ sid, ext });
}

pub fn validateSid(sid: []const u8) !void {
    if (sid.len == 0) return error.InvalidSessionId;
    for (sid) |ch| {
        if (ch == '/' or ch == '\\' or ch == 0) return error.InvalidSessionId;
    }
}

test "sid path helpers validate ids and extension" {
    const good = try sidJsonlAlloc(std.testing.allocator, "s1");
    defer std.testing.allocator.free(good);
    try std.testing.expectEqualStrings("s1.jsonl", good);

    try std.testing.expectError(error.InvalidSessionId, sidJsonlAlloc(std.testing.allocator, ""));
    try std.testing.expectError(error.InvalidSessionId, sidJsonlAlloc(std.testing.allocator, "a/b"));
    try std.testing.expectError(error.InvalidExtension, sidExtAlloc(std.testing.allocator, "s1", ""));
}
