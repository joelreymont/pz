const std = @import("std");
const tools = @import("mod.zig");

pub const Err = error{
    KindMismatch,
    InvalidArgs,
    NotFound,
    Denied,
    TooLarge,
    Io,
    OutOfMemory,
};

pub const Opts = struct {
    alloc: std.mem.Allocator,
    max_bytes: usize,
    now_ms: i64 = 0,
};

pub const Handler = struct {
    alloc: std.mem.Allocator,
    max_bytes: usize,
    now_ms: i64,

    pub fn init(opts: Opts) Handler {
        return .{
            .alloc = opts.alloc,
            .max_bytes = opts.max_bytes,
            .now_ms = opts.now_ms,
        };
    }

    pub fn run(self: Handler, call: tools.Call, _: tools.Sink) Err!tools.Result {
        if (call.kind != .edit) return error.KindMismatch;
        if (std.meta.activeTag(call.args) != .edit) return error.KindMismatch;

        const args = call.args.edit;
        if (args.path.len == 0) return error.InvalidArgs;
        if (args.old.len == 0) return error.InvalidArgs;

        const full = std.fs.cwd().readFileAlloc(self.alloc, args.path, self.max_bytes) catch |read_err| {
            return mapReadErr(read_err);
        };
        defer self.alloc.free(full);

        const updated = if (args.all)
            try replaceAllAlloc(self.alloc, full, args.old, args.new)
        else
            try replaceFirstAlloc(self.alloc, full, args.old, args.new);
        defer self.alloc.free(updated);

        var file = std.fs.cwd().openFile(args.path, .{ .mode = .write_only }) catch |open_err| {
            return mapWriteErr(open_err);
        };
        defer file.close();

        file.setEndPos(0) catch |truncate_err| {
            return mapWriteErr(truncate_err);
        };
        file.seekTo(0) catch |seek_err| {
            return mapWriteErr(seek_err);
        };
        file.writeAll(updated) catch |write_err| {
            return mapWriteErr(write_err);
        };

        return .{
            .call_id = call.id,
            .started_at_ms = self.now_ms,
            .ended_at_ms = self.now_ms,
            .out = &.{},
            .final = .{ .ok = .{ .code = 0 } },
        };
    }
};

fn replaceFirstAlloc(
    alloc: std.mem.Allocator,
    full: []const u8,
    old: []const u8,
    new: []const u8,
) Err![]u8 {
    const idx = std.mem.indexOf(u8, full, old) orelse return error.NotFound;

    const out_len = full.len - old.len + new.len;
    const out = alloc.alloc(u8, out_len) catch {
        return error.OutOfMemory;
    };

    const pre = full[0..idx];
    const post = full[idx + old.len ..];
    std.mem.copyForwards(u8, out[0..pre.len], pre);
    std.mem.copyForwards(u8, out[pre.len .. pre.len + new.len], new);
    std.mem.copyForwards(u8, out[pre.len + new.len ..], post);
    return out;
}

fn replaceAllAlloc(
    alloc: std.mem.Allocator,
    full: []const u8,
    old: []const u8,
    new: []const u8,
) Err![]u8 {
    if (std.mem.count(u8, full, old) == 0) return error.NotFound;
    return std.mem.replaceOwned(u8, alloc, full, old, new) catch {
        return error.OutOfMemory;
    };
}

fn mapReadErr(err: anyerror) Err {
    return switch (err) {
        error.FileNotFound => error.NotFound,
        error.AccessDenied, error.PermissionDenied => error.Denied,
        error.FileTooBig => error.TooLarge,
        error.OutOfMemory => error.OutOfMemory,
        else => error.Io,
    };
}

fn mapWriteErr(err: anyerror) Err {
    return switch (err) {
        error.FileNotFound, error.NotDir => error.NotFound,
        error.AccessDenied,
        error.PermissionDenied,
        error.ReadOnlyFileSystem,
        error.LockViolation,
        => error.Denied,
        else => error.Io,
    };
}

test "edit handler replaces first match with deterministic timestamps" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "in.txt", .data = "a x a x" });
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "in.txt");
    defer std.testing.allocator.free(path);

    const SinkImpl = struct {
        fn push(_: *@This(), _: tools.Event) !void {}
    };

    var sink_impl = SinkImpl{};
    const sink = tools.Sink.from(SinkImpl, &sink_impl, SinkImpl.push);

    const handler = Handler.init(.{
        .alloc = std.testing.allocator,
        .max_bytes = 1024,
        .now_ms = 123,
    });
    const call: tools.Call = .{
        .id = "e1",
        .kind = .edit,
        .args = .{ .edit = .{
            .path = path,
            .old = "x",
            .new = "y",
            .all = false,
        } },
        .src = .model,
        .at_ms = 0,
    };

    const res = try handler.run(call, sink);

    try std.testing.expectEqual(@as(i64, 123), res.started_at_ms);
    try std.testing.expectEqual(@as(i64, 123), res.ended_at_ms);
    try std.testing.expectEqual(@as(usize, 0), res.out.len);
    switch (res.final) {
        .ok => |ok| try std.testing.expectEqual(@as(i32, 0), ok.code),
        else => return error.TestUnexpectedResult,
    }

    const got = try tmp.dir.readFileAlloc(std.testing.allocator, "in.txt", 64);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("a y a x", got);
}

test "edit handler replaces all matches when all is true" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "in.txt", .data = "ab ab ab" });
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "in.txt");
    defer std.testing.allocator.free(path);

    const SinkImpl = struct {
        fn push(_: *@This(), _: tools.Event) !void {}
    };

    var sink_impl = SinkImpl{};
    const sink = tools.Sink.from(SinkImpl, &sink_impl, SinkImpl.push);

    const handler = Handler.init(.{
        .alloc = std.testing.allocator,
        .max_bytes = 1024,
    });
    const call: tools.Call = .{
        .id = "e2",
        .kind = .edit,
        .args = .{ .edit = .{
            .path = path,
            .old = "ab",
            .new = "cd",
            .all = true,
        } },
        .src = .model,
        .at_ms = 0,
    };

    _ = try handler.run(call, sink);

    const got = try tmp.dir.readFileAlloc(std.testing.allocator, "in.txt", 64);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("cd cd cd", got);
}

test "edit handler returns not found when old text is absent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "in.txt", .data = "abc" });
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "in.txt");
    defer std.testing.allocator.free(path);

    const SinkImpl = struct {
        fn push(_: *@This(), _: tools.Event) !void {}
    };

    var sink_impl = SinkImpl{};
    const sink = tools.Sink.from(SinkImpl, &sink_impl, SinkImpl.push);

    const handler = Handler.init(.{
        .alloc = std.testing.allocator,
        .max_bytes = 128,
    });
    const call: tools.Call = .{
        .id = "e3",
        .kind = .edit,
        .args = .{ .edit = .{
            .path = path,
            .old = "zzz",
            .new = "x",
        } },
        .src = .model,
        .at_ms = 0,
    };

    try std.testing.expectError(error.NotFound, handler.run(call, sink));
}

test "edit handler returns invalid args for empty old pattern" {
    const SinkImpl = struct {
        fn push(_: *@This(), _: tools.Event) !void {}
    };

    var sink_impl = SinkImpl{};
    const sink = tools.Sink.from(SinkImpl, &sink_impl, SinkImpl.push);

    const handler = Handler.init(.{
        .alloc = std.testing.allocator,
        .max_bytes = 128,
    });
    const call: tools.Call = .{
        .id = "e4",
        .kind = .edit,
        .args = .{ .edit = .{
            .path = "x",
            .old = "",
            .new = "y",
        } },
        .src = .model,
        .at_ms = 0,
    };

    try std.testing.expectError(error.InvalidArgs, handler.run(call, sink));
}

test "edit handler returns not found for missing file path" {
    const SinkImpl = struct {
        fn push(_: *@This(), _: tools.Event) !void {}
    };

    var sink_impl = SinkImpl{};
    const sink = tools.Sink.from(SinkImpl, &sink_impl, SinkImpl.push);

    const handler = Handler.init(.{
        .alloc = std.testing.allocator,
        .max_bytes = 128,
    });
    const call: tools.Call = .{
        .id = "e5",
        .kind = .edit,
        .args = .{ .edit = .{
            .path = "this-file-should-not-exist-c8353af6.txt",
            .old = "a",
            .new = "b",
        } },
        .src = .model,
        .at_ms = 0,
    };

    try std.testing.expectError(error.NotFound, handler.run(call, sink));
}

test "edit handler returns kind mismatch for wrong call kind" {
    const SinkImpl = struct {
        fn push(_: *@This(), _: tools.Event) !void {}
    };

    var sink_impl = SinkImpl{};
    const sink = tools.Sink.from(SinkImpl, &sink_impl, SinkImpl.push);

    const handler = Handler.init(.{
        .alloc = std.testing.allocator,
        .max_bytes = 128,
    });
    const call: tools.Call = .{
        .id = "e6",
        .kind = .write,
        .args = .{ .write = .{
            .path = "x",
            .text = "y",
        } },
        .src = .model,
        .at_ms = 0,
    };

    try std.testing.expectError(error.KindMismatch, handler.run(call, sink));
}
