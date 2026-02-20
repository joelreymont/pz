const std = @import("std");

pub const Stream = enum {
    stdout,
    stderr,
};

pub const TruncMeta = struct {
    limit_bytes: usize,
    full_bytes: usize,
    kept_bytes: usize,
    dropped_bytes: usize,
};

pub const Slice = struct {
    chunk: []const u8,
    truncated: bool,
    meta: ?TruncMeta,
};

pub fn apply(full: []const u8, limit_bytes: usize) Slice {
    const kept_bytes = @min(full.len, limit_bytes);
    const dropped_bytes = full.len - kept_bytes;
    if (dropped_bytes == 0) {
        return .{
            .chunk = full,
            .truncated = false,
            .meta = null,
        };
    }

    return .{
        .chunk = full[0..kept_bytes],
        .truncated = true,
        .meta = .{
            .limit_bytes = limit_bytes,
            .full_bytes = full.len,
            .kept_bytes = kept_bytes,
            .dropped_bytes = dropped_bytes,
        },
    };
}

pub fn metaFor(limit_bytes: usize, full_bytes: usize) ?TruncMeta {
    const kept_bytes = @min(full_bytes, limit_bytes);
    if (full_bytes <= kept_bytes) return null;

    return .{
        .limit_bytes = limit_bytes,
        .full_bytes = full_bytes,
        .kept_bytes = kept_bytes,
        .dropped_bytes = full_bytes - kept_bytes,
    };
}

pub fn metaJsonAlloc(
    alloc: std.mem.Allocator,
    stream: Stream,
    meta: TruncMeta,
) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "{{\"type\":\"trunc\",\"stream\":\"{s}\",\"limit_bytes\":{d},\"full_bytes\":{d},\"kept_bytes\":{d},\"dropped_bytes\":{d}}}",
        .{
            streamName(stream),
            meta.limit_bytes,
            meta.full_bytes,
            meta.kept_bytes,
            meta.dropped_bytes,
        },
    );
}

fn streamName(stream: Stream) []const u8 {
    return switch (stream) {
        .stdout => "stdout",
        .stderr => "stderr",
    };
}

test "output apply keeps chunk when within limit" {
    const got = apply("abc", 3);
    try std.testing.expectEqualStrings("abc", got.chunk);
    try std.testing.expect(!got.truncated);
    try std.testing.expect(got.meta == null);
}

test "output apply truncates chunk and emits metadata" {
    const got = apply("abcd", 3);
    try std.testing.expectEqualStrings("abc", got.chunk);
    try std.testing.expect(got.truncated);

    const meta = got.meta orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 3), meta.limit_bytes);
    try std.testing.expectEqual(@as(usize, 4), meta.full_bytes);
    try std.testing.expectEqual(@as(usize, 3), meta.kept_bytes);
    try std.testing.expectEqual(@as(usize, 1), meta.dropped_bytes);
}

test "output metadata json is stable" {
    const raw = try metaJsonAlloc(std.testing.allocator, .stderr, .{
        .limit_bytes = 3,
        .full_bytes = 8,
        .kept_bytes = 3,
        .dropped_bytes = 5,
    });
    defer std.testing.allocator.free(raw);

    try std.testing.expectEqualStrings(
        "{\"type\":\"trunc\",\"stream\":\"stderr\",\"limit_bytes\":3,\"full_bytes\":8,\"kept_bytes\":3,\"dropped_bytes\":5}",
        raw,
    );
}
