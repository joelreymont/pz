const std = @import("std");
const schema = @import("schema.zig");
const sid_path = @import("path.zig");

pub const Event = schema.Event;

pub const Opts = struct {
    max_line_bytes: usize = 1024 * 1024,
};

pub const ReplayReader = struct {
    alloc: std.mem.Allocator,
    raw: []u8,
    pos: usize = 0,
    arena: std.heap.ArenaAllocator,
    max_line_bytes: usize,
    line_no: usize = 0,

    pub fn init(alloc: std.mem.Allocator, dir: std.fs.Dir, sid: []const u8, opts: Opts) !ReplayReader {
        if (opts.max_line_bytes == 0) return error.InvalidMaxLineBytes;

        const path = try sid_path.sidJsonlAlloc(alloc, sid);
        defer alloc.free(path);

        const file = try dir.openFile(path, .{ .mode = .read_only });
        defer file.close();
        const size_u64 = try file.getEndPos();
        if (size_u64 > std.math.maxInt(usize)) return error.ReplayTooLarge;
        const raw = try file.readToEndAlloc(alloc, @intCast(size_u64));

        return .{
            .alloc = alloc,
            .raw = raw,
            .arena = std.heap.ArenaAllocator.init(alloc),
            .max_line_bytes = opts.max_line_bytes,
        };
    }

    pub fn next(self: *ReplayReader) !?Event {
        self.arena.deinit();
        self.arena = std.heap.ArenaAllocator.init(self.alloc);

        if (self.pos >= self.raw.len) return null;

        const start = self.pos;
        const end = std.mem.indexOfScalarPos(u8, self.raw, start, '\n') orelse self.raw.len;
        self.pos = if (end < self.raw.len) end + 1 else self.raw.len;

        const raw_line = self.raw[start..end];

        self.line_no += 1;
        if (raw_line.len == 0) return error.EmptyReplayLine;
        if (raw_line.len > self.max_line_bytes) return error.ReplayLineTooLong;

        const parsed = schema.decodeSlice(self.arena.allocator(), raw_line) catch |err| switch (err) {
            error.UnsupportedVersion => return error.UnsupportedVersion,
            else => return error.MalformedReplayLine,
        };
        // Don't deinit parsed — string slices in the Event reference memory
        // owned by self.arena, which resets at the start of the next next() call.

        return parsed.value;
    }

    pub fn line(self: *const ReplayReader) usize {
        return self.line_no;
    }

    pub fn deinit(self: *ReplayReader) void {
        self.arena.deinit();
        self.alloc.free(self.raw);
    }
};

fn expectSameEvent(expected: Event, actual: Event) !void {
    const want = try schema.encodeAlloc(std.testing.allocator, expected);
    defer std.testing.allocator.free(want);

    const got = try schema.encodeAlloc(std.testing.allocator, actual);
    defer std.testing.allocator.free(got);

    try std.testing.expectEqualStrings(want, got);
}

fn encodeLine(file: std.fs.File, ev: Event) !void {
    const raw = try schema.encodeAlloc(std.testing.allocator, ev);
    defer std.testing.allocator.free(raw);

    try file.writeAll(raw);
    try file.writeAll("\n");
}

test "jsonl replay preserves event stream exactly" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const events = [_]Event{
        .{
            .at_ms = 1,
            .data = .{ .prompt = .{ .text = "alpha" } },
        },
        .{
            .at_ms = 2,
            .data = .{ .tool_call = .{
                .id = "c1",
                .name = "read",
                .args = "{\"path\":\"a.txt\"}",
            } },
        },
        .{
            .at_ms = 3,
            .data = .{ .usage = .{
                .in_tok = 11,
                .out_tok = 7,
                .tot_tok = 18,
            } },
        },
        .{
            .at_ms = 4,
            .data = .{ .stop = .{ .reason = .done } },
        },
    };

    {
        const file = try tmp.dir.createFile("s1.jsonl", .{});
        defer file.close();
        for (events) |ev| try encodeLine(file, ev);
    }

    var rdr = try ReplayReader.init(std.testing.allocator, tmp.dir, "s1", .{});
    defer rdr.deinit();

    var idx: usize = 0;
    while (try rdr.next()) |ev| : (idx += 1) {
        if (idx >= events.len) return error.TestUnexpectedResult;
        try expectSameEvent(events[idx], ev);
    }
    try std.testing.expectEqual(@as(usize, events.len), idx);
}

fn expectMalformedReplay(dir: std.fs.Dir) !void {
    var rdr = try ReplayReader.init(std.testing.allocator, dir, "bad", .{});
    defer rdr.deinit();

    _ = (try rdr.next()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), rdr.line());
    try std.testing.expectError(error.MalformedReplayLine, rdr.next());
    try std.testing.expectEqual(@as(usize, 2), rdr.line());
}

test "jsonl replay fails malformed line deterministically" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try tmp.dir.createFile("bad.jsonl", .{});
        defer file.close();

        try encodeLine(file, .{
            .at_ms = 1,
            .data = .{ .text = .{ .text = "ok" } },
        });
        try file.writeAll("{\"version\":1,\"at_ms\":2,\"data\":{\"text\":{\"text\":\"oops\"}}\n");
        try encodeLine(file, .{
            .at_ms = 3,
            .data = .{ .err = .{ .text = "never" } },
        });
    }

    try expectMalformedReplay(tmp.dir);
    try expectMalformedReplay(tmp.dir);
}

test "jsonl replay rejects unsupported event version" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try tmp.dir.createFile("ver.jsonl", .{});
        defer file.close();
        try file.writeAll("{\"version\":7,\"at_ms\":1,\"data\":{\"noop\":{}}}\n");
    }

    var rdr = try ReplayReader.init(std.testing.allocator, tmp.dir, "ver", .{});
    defer rdr.deinit();

    try std.testing.expectError(error.UnsupportedVersion, rdr.next());
}

test "jsonl replay rejects invalid session id" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expectError(error.InvalidSessionId, ReplayReader.init(
        std.testing.allocator,
        tmp.dir,
        "",
        .{},
    ));
    try std.testing.expectError(error.InvalidSessionId, ReplayReader.init(
        std.testing.allocator,
        tmp.dir,
        "a/b",
        .{},
    ));
}

test "jsonl replay rejects zero max line bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expectError(error.InvalidMaxLineBytes, ReplayReader.init(
        std.testing.allocator,
        tmp.dir,
        "s1",
        .{ .max_line_bytes = 0 },
    ));
}
