const std = @import("std");
const schema = @import("schema.zig");
const reader = @import("reader.zig");

const replay_golden =
    \\{"version":1,"at_ms":1,"data":{"prompt":{"text":"hello"}}}
    \\{"version":1,"at_ms":2,"data":{"text":{"text":"world"}}}
    \\{"version":1,"at_ms":3,"data":{"tool_call":{"id":"c1","name":"read","args":"{\"path\":\"a.txt\"}"}}}
    \\{"version":1,"at_ms":4,"data":{"tool_result":{"id":"c1","out":"ok","is_err":false}}}
    \\{"version":1,"at_ms":5,"data":{"stop":{"reason":"done"}}}
    \\
;

fn replayJson(alloc: std.mem.Allocator, dir: std.fs.Dir, sid: []const u8) ![][]u8 {
    var rdr = try reader.ReplayReader.init(alloc, dir, sid, .{});
    defer rdr.deinit();

    var out: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (out.items) |item| alloc.free(item);
        out.deinit(alloc);
    }

    while (try rdr.next()) |ev| {
        const line = try schema.encodeAlloc(alloc, ev);
        try out.append(alloc, line);
    }
    return try out.toOwnedSlice(alloc);
}

fn freeRows(alloc: std.mem.Allocator, rows: [][]u8) void {
    for (rows) |row| alloc.free(row);
    alloc.free(rows);
}

test "session replay golden fixture is stable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{
        .sub_path = "gold.jsonl",
        .data = replay_golden,
    });

    const got = try replayJson(std.testing.allocator, tmp.dir, "gold");
    defer freeRows(std.testing.allocator, got);

    var it = std.mem.splitScalar(u8, replay_golden, '\n');
    var idx: usize = 0;
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (idx >= got.len) return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(line, got[idx]);
        idx += 1;
    }
    try std.testing.expectEqual(idx, got.len);
}

test "session replay golden fixture is deterministic across runs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{
        .sub_path = "gold.jsonl",
        .data = replay_golden,
    });

    const a = try replayJson(std.testing.allocator, tmp.dir, "gold");
    defer freeRows(std.testing.allocator, a);
    const b = try replayJson(std.testing.allocator, tmp.dir, "gold");
    defer freeRows(std.testing.allocator, b);

    try std.testing.expectEqual(a.len, b.len);
    for (a, b) |lhs, rhs| {
        try std.testing.expectEqualStrings(lhs, rhs);
    }
}
