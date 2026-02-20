const std = @import("std");
const sid_path = @import("path.zig");

pub const version_current: u16 = 1;

pub const ErrKind = enum {
    none,
    transient,
    fatal,
    parse,
    tool,
    internal,
};

pub const State = struct {
    version: u16 = version_current,
    tries_done: u16 = 0,
    fail_ct: u16 = 0,
    next_wait_ms: u64 = 0,
    last_err: ErrKind = .none,
};

pub fn save(
    alloc: std.mem.Allocator,
    dir: std.fs.Dir,
    sid: []const u8,
    state: State,
) !void {
    var out = state;
    out.version = version_current;
    if (out.fail_ct > out.tries_done) return error.InvalidRetryState;

    const path = try sid_path.sidExtAlloc(alloc, sid, ".retry.json");
    defer alloc.free(path);

    const raw = try std.json.Stringify.valueAlloc(alloc, out, .{});
    defer alloc.free(raw);

    var file = try dir.createFile(path, .{
        .truncate = true,
    });
    defer file.close();
    try file.writeAll(raw);
    try file.writeAll("\n");
    try file.sync();
}

pub fn load(
    alloc: std.mem.Allocator,
    dir: std.fs.Dir,
    sid: []const u8,
) !?State {
    const path = try sid_path.sidExtAlloc(alloc, sid, ".retry.json");
    defer alloc.free(path);

    const raw = dir.readFileAlloc(alloc, path, 64 * 1024) catch |read_err| switch (read_err) {
        error.FileNotFound => return null,
        else => return read_err,
    };
    defer alloc.free(raw);

    const parsed = try std.json.parseFromSlice(State, alloc, raw, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    if (parsed.value.version != version_current) return error.UnsupportedRetryStateVersion;
    if (parsed.value.fail_ct > parsed.value.tries_done) return error.InvalidRetryState;

    return parsed.value;
}

test "retry state persists and restores counters after reload" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const in = State{
        .tries_done = 4,
        .fail_ct = 3,
        .next_wait_ms = 250,
        .last_err = .transient,
    };
    try save(std.testing.allocator, tmp.dir, "s1", in);

    const out = (try load(std.testing.allocator, tmp.dir, "s1")) orelse {
        return error.TestUnexpectedResult;
    };
    try std.testing.expectEqual(@as(u16, version_current), out.version);
    try std.testing.expectEqual(@as(u16, 4), out.tries_done);
    try std.testing.expectEqual(@as(u16, 3), out.fail_ct);
    try std.testing.expectEqual(@as(u64, 250), out.next_wait_ms);
    try std.testing.expect(out.last_err == .transient);
}

test "retry state load returns null when file is absent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expect((try load(std.testing.allocator, tmp.dir, "missing")) == null);
}

test "retry state rejects invalid counters" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expectError(error.InvalidRetryState, save(
        std.testing.allocator,
        tmp.dir,
        "s1",
        .{
            .tries_done = 1,
            .fail_ct = 2,
        },
    ));
}
