const std = @import("std");
const schema = @import("schema.zig");
const reader = @import("reader.zig");
const sid_path = @import("path.zig");

pub const checkpoint_version: u16 = 1;

pub const Checkpoint = struct {
    version: u16 = checkpoint_version,
    in_lines: u64 = 0,
    out_lines: u64 = 0,
    in_bytes: u64 = 0,
    out_bytes: u64 = 0,
    compacted_at_ms: i64 = 0,
};

pub fn run(
    alloc: std.mem.Allocator,
    dir: std.fs.Dir,
    sid: []const u8,
    compacted_at_ms: i64,
) !Checkpoint {
    const src_path = try sid_path.sidJsonlAlloc(alloc, sid);
    defer alloc.free(src_path);

    const tmp_path = try sid_path.sidExtAlloc(alloc, sid, ".jsonl.compact.tmp");
    defer alloc.free(tmp_path);
    errdefer dir.deleteFile(tmp_path) catch |err| {
        std.debug.print("warning: temp file cleanup failed: {s}\n", .{@errorName(err)});
    };

    const in_file = try dir.openFile(src_path, .{ .mode = .read_only });
    const in_bytes = try in_file.getEndPos();
    in_file.close();

    var rdr = try reader.ReplayReader.init(alloc, dir, sid, .{});
    defer rdr.deinit();

    var out_file = try dir.createFile(tmp_path, .{
        .truncate = true,
    });
    defer out_file.close();

    var in_lines: u64 = 0;
    var out_lines: u64 = 0;
    var out_bytes: u64 = 0;
    while (try rdr.next()) |ev| {
        in_lines += 1;
        if (ev.data == .noop) continue;

        const raw = try schema.encodeAlloc(alloc, ev);
        defer alloc.free(raw);

        try out_file.writeAll(raw);
        try out_file.writeAll("\n");
        out_lines += 1;
        out_bytes += raw.len + 1;
    }
    try out_file.sync();

    try dir.rename(tmp_path, src_path);

    const ck = Checkpoint{
        .in_lines = in_lines,
        .out_lines = out_lines,
        .in_bytes = in_bytes,
        .out_bytes = out_bytes,
        .compacted_at_ms = compacted_at_ms,
    };
    try saveCheckpoint(alloc, dir, sid, ck);
    return ck;
}

pub fn loadCheckpoint(
    alloc: std.mem.Allocator,
    dir: std.fs.Dir,
    sid: []const u8,
) !?Checkpoint {
    const path = try sid_path.sidExtAlloc(alloc, sid, ".compact.json");
    defer alloc.free(path);

    const raw = dir.readFileAlloc(alloc, path, 64 * 1024) catch |read_err| switch (read_err) {
        error.FileNotFound => return null,
        else => return read_err,
    };
    defer alloc.free(raw);

    const parsed = try std.json.parseFromSlice(Checkpoint, alloc, raw, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    if (parsed.value.version != checkpoint_version) return error.UnsupportedCheckpointVersion;
    return parsed.value;
}

fn saveCheckpoint(
    alloc: std.mem.Allocator,
    dir: std.fs.Dir,
    sid: []const u8,
    ck: Checkpoint,
) !void {
    const path = try sid_path.sidExtAlloc(alloc, sid, ".compact.json");
    defer alloc.free(path);

    const raw = try std.json.Stringify.valueAlloc(alloc, ck, .{});
    defer alloc.free(raw);

    var file = try dir.createFile(path, .{
        .truncate = true,
    });
    defer file.close();
    try file.writeAll(raw);
    try file.writeAll("\n");
    try file.sync();
}

fn collectSemanticJson(
    alloc: std.mem.Allocator,
    dir: std.fs.Dir,
    sid: []const u8,
) ![][]u8 {
    var rdr = try reader.ReplayReader.init(alloc, dir, sid, .{});
    defer rdr.deinit();

    var out: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (out.items) |item| alloc.free(item);
        out.deinit(alloc);
    }

    while (try rdr.next()) |ev| {
        if (ev.data == .noop) continue;
        const raw = try schema.encodeAlloc(alloc, ev);
        try out.append(alloc, raw);
    }

    return try out.toOwnedSlice(alloc);
}

fn freeJsonSlice(alloc: std.mem.Allocator, rows: [][]u8) void {
    for (rows) |row| alloc.free(row);
    alloc.free(rows);
}

test "compaction rewrites stream and preserves semantic events" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const writer = @import("writer.zig");
    var wr = try writer.Writer.init(std.testing.allocator, tmp.dir, .{
        .flush = .{ .always = {} },
    });

    try wr.append("s1", .{
        .at_ms = 1,
        .data = .{ .prompt = .{ .text = "a" } },
    });
    try wr.append("s1", .{
        .at_ms = 2,
        .data = .{ .noop = {} },
    });
    try wr.append("s1", .{
        .at_ms = 3,
        .data = .{ .text = .{ .text = "b" } },
    });
    try wr.append("s1", .{
        .at_ms = 4,
        .data = .{ .noop = {} },
    });
    try wr.append("s1", .{
        .at_ms = 5,
        .data = .{ .stop = .{ .reason = .done } },
    });

    const before = try collectSemanticJson(std.testing.allocator, tmp.dir, "s1");
    defer freeJsonSlice(std.testing.allocator, before);

    const ck = try run(std.testing.allocator, tmp.dir, "s1", 777);
    try std.testing.expectEqual(@as(u64, 5), ck.in_lines);
    try std.testing.expectEqual(@as(u64, 3), ck.out_lines);
    try std.testing.expectEqual(@as(i64, 777), ck.compacted_at_ms);
    try std.testing.expect(ck.in_bytes > ck.out_bytes);

    const after = try collectSemanticJson(std.testing.allocator, tmp.dir, "s1");
    defer freeJsonSlice(std.testing.allocator, after);

    try std.testing.expectEqual(before.len, after.len);
    for (before, after) |lhs, rhs| {
        try std.testing.expectEqualStrings(lhs, rhs);
    }

    const loaded = (try loadCheckpoint(std.testing.allocator, tmp.dir, "s1")) orelse {
        return error.TestUnexpectedResult;
    };
    try std.testing.expectEqual(@as(u16, checkpoint_version), loaded.version);
    try std.testing.expectEqual(@as(u64, 5), loaded.in_lines);
    try std.testing.expectEqual(@as(u64, 3), loaded.out_lines);
}

test "compaction checkpoint returns null when absent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expect((try loadCheckpoint(std.testing.allocator, tmp.dir, "missing")) == null);
}
