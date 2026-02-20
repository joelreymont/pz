const std = @import("std");
const tools = @import("mod.zig");

pub const Err = error{
    KindMismatch,
    InvalidArgs,
    NotFound,
    Denied,
    Io,
};

pub const Opts = struct {
    now_ms: i64 = 0,
};

pub const Handler = struct {
    now_ms: i64,

    pub fn init(opts: Opts) Handler {
        return .{
            .now_ms = opts.now_ms,
        };
    }

    pub fn run(self: Handler, call: tools.Call, _: tools.Sink) Err!tools.Result {
        if (call.kind != .write) return error.KindMismatch;
        if (std.meta.activeTag(call.args) != .write) return error.KindMismatch;

        const args = call.args.write;
        if (args.path.len == 0) return error.InvalidArgs;

        var file = std.fs.cwd().createFile(args.path, .{
            .truncate = !args.append,
        }) catch |open_err| {
            return mapOpenErr(open_err);
        };
        defer file.close();

        if (args.append) {
            file.seekFromEnd(0) catch |seek_err| {
                return mapSeekErr(seek_err);
            };
        }

        file.writeAll(args.text) catch |write_err| {
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

fn mapOpenErr(err: anyerror) Err {
    return switch (err) {
        error.FileNotFound => error.NotFound,
        error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => error.Denied,
        else => error.Io,
    };
}

fn mapSeekErr(err: anyerror) Err {
    return switch (err) {
        error.AccessDenied, error.PermissionDenied => error.Denied,
        else => error.Io,
    };
}

fn mapWriteErr(err: anyerror) Err {
    return switch (err) {
        error.AccessDenied,
        error.PermissionDenied,
        error.ReadOnlyFileSystem,
        error.LockViolation,
        => error.Denied,
        else => error.Io,
    };
}

test "write handler overwrites file with deterministic timestamps" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "out.txt", .data = "old" });
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "out.txt");
    defer std.testing.allocator.free(path);

    const SinkImpl = struct {
        fn push(_: *@This(), _: tools.Event) !void {}
    };

    var sink_impl = SinkImpl{};
    const sink = tools.Sink.from(SinkImpl, &sink_impl, SinkImpl.push);

    const handler = Handler.init(.{ .now_ms = 77 });
    const call: tools.Call = .{
        .id = "w1",
        .kind = .write,
        .args = .{ .write = .{
            .path = path,
            .text = "new",
            .append = false,
        } },
        .src = .system,
        .at_ms = 1,
    };

    const res = try handler.run(call, sink);

    try std.testing.expectEqual(@as(i64, 77), res.started_at_ms);
    try std.testing.expectEqual(@as(i64, 77), res.ended_at_ms);
    try std.testing.expectEqual(@as(usize, 0), res.out.len);

    switch (res.final) {
        .ok => |ok| try std.testing.expectEqual(@as(i32, 0), ok.code),
        else => return error.TestUnexpectedResult,
    }

    const got = try tmp.dir.readFileAlloc(std.testing.allocator, "out.txt", 64);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("new", got);
}

test "write handler appends when append is true" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "out.txt", .data = "a" });
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "out.txt");
    defer std.testing.allocator.free(path);

    const SinkImpl = struct {
        fn push(_: *@This(), _: tools.Event) !void {}
    };

    var sink_impl = SinkImpl{};
    const sink = tools.Sink.from(SinkImpl, &sink_impl, SinkImpl.push);

    const handler = Handler.init(.{});
    const call: tools.Call = .{
        .id = "w2",
        .kind = .write,
        .args = .{ .write = .{
            .path = path,
            .text = "b",
            .append = true,
        } },
        .src = .system,
        .at_ms = 0,
    };

    _ = try handler.run(call, sink);

    const got = try tmp.dir.readFileAlloc(std.testing.allocator, "out.txt", 64);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("ab", got);
}

test "write handler returns invalid args for empty path" {
    const SinkImpl = struct {
        fn push(_: *@This(), _: tools.Event) !void {}
    };

    var sink_impl = SinkImpl{};
    const sink = tools.Sink.from(SinkImpl, &sink_impl, SinkImpl.push);

    const handler = Handler.init(.{});
    const call: tools.Call = .{
        .id = "w3",
        .kind = .write,
        .args = .{ .write = .{
            .path = "",
            .text = "x",
        } },
        .src = .system,
        .at_ms = 0,
    };

    try std.testing.expectError(error.InvalidArgs, handler.run(call, sink));
}

test "write handler returns not found for missing parent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    const path = try std.fs.path.join(std.testing.allocator, &.{
        dir_path,
        "missing",
        "out.txt",
    });
    defer std.testing.allocator.free(path);

    const SinkImpl = struct {
        fn push(_: *@This(), _: tools.Event) !void {}
    };

    var sink_impl = SinkImpl{};
    const sink = tools.Sink.from(SinkImpl, &sink_impl, SinkImpl.push);

    const handler = Handler.init(.{});
    const call: tools.Call = .{
        .id = "w4",
        .kind = .write,
        .args = .{ .write = .{
            .path = path,
            .text = "x",
        } },
        .src = .model,
        .at_ms = 0,
    };

    try std.testing.expectError(error.NotFound, handler.run(call, sink));
}

test "write handler returns kind mismatch for wrong call kind" {
    const SinkImpl = struct {
        fn push(_: *@This(), _: tools.Event) !void {}
    };

    var sink_impl = SinkImpl{};
    const sink = tools.Sink.from(SinkImpl, &sink_impl, SinkImpl.push);

    const handler = Handler.init(.{});
    const call: tools.Call = .{
        .id = "w5",
        .kind = .read,
        .args = .{ .read = .{
            .path = "x",
        } },
        .src = .model,
        .at_ms = 0,
    };

    try std.testing.expectError(error.KindMismatch, handler.run(call, sink));
}
