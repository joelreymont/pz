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
        if (call.kind != .read) return error.KindMismatch;
        if (std.meta.activeTag(call.args) != .read) return error.KindMismatch;

        const args = call.args.read;
        const from_line = args.from_line orelse 1;

        if (args.path.len == 0) return error.InvalidArgs;
        if (from_line == 0) return error.InvalidArgs;

        if (args.to_line) |to_line| {
            if (to_line == 0) return error.InvalidArgs;
            if (to_line < from_line) return error.InvalidArgs;
        }

        const full = std.fs.cwd().readFileAlloc(self.alloc, args.path, self.max_bytes) catch |read_err| {
            return mapReadErr(read_err);
        };
        defer self.alloc.free(full);

        const selected = sliceLines(full, from_line, args.to_line);
        const chunk = self.alloc.dupe(u8, selected) catch return error.OutOfMemory;
        errdefer self.alloc.free(chunk);

        const out = self.alloc.alloc(tools.Output, 1) catch return error.OutOfMemory;
        errdefer self.alloc.free(out);

        out[0] = .{
            .call_id = call.id,
            .seq = 0,
            .at_ms = self.now_ms,
            .stream = .stdout,
            .chunk = chunk,
            .owned = true,
            .truncated = false,
        };

        return .{
            .call_id = call.id,
            .started_at_ms = self.now_ms,
            .ended_at_ms = self.now_ms,
            .out = out,
            .out_owned = true,
            .final = .{ .ok = .{ .code = 0 } },
        };
    }

    pub fn deinitResult(self: Handler, res: tools.Result) void {
        if (!res.out_owned) return;
        for (res.out) |out| {
            if (out.owned) self.alloc.free(out.chunk);
        }
        self.alloc.free(res.out);
    }
};

fn mapReadErr(err: anyerror) Err {
    return switch (err) {
        error.FileNotFound => error.NotFound,
        error.AccessDenied, error.PermissionDenied => error.Denied,
        error.FileTooBig => error.TooLarge,
        error.OutOfMemory => error.OutOfMemory,
        else => error.Io,
    };
}

fn sliceLines(full: []const u8, from_line: u32, to_line: ?u32) []const u8 {
    if (full.len == 0) return "";

    const last_line = to_line orelse std.math.maxInt(u32);
    if (from_line > last_line) return "";

    var line_num: u32 = 1;
    var line_start: usize = 0;
    var sel_start: ?usize = null;
    var sel_end: usize = 0;

    var idx: usize = 0;
    while (idx < full.len) : (idx += 1) {
        if (full[idx] != '\n') continue;

        const line_end = idx + 1;
        if (line_num >= from_line and line_num <= last_line) {
            if (sel_start == null) sel_start = line_start;
            sel_end = line_end;
        }

        if (line_num == last_line) {
            break;
        }

        line_num += 1;
        line_start = line_end;
    }

    if (line_start < full.len and line_num >= from_line and line_num <= last_line) {
        if (sel_start == null) sel_start = line_start;
        sel_end = full.len;
    }

    if (sel_start) |start| {
        return full[start..sel_end];
    }
    return "";
}

test "read handler returns selected lines with deterministic timestamps" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "in.txt", .data = "a\nb\nc\n" });
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
        .now_ms = 55,
    });

    const call: tools.Call = .{
        .id = "c1",
        .kind = .read,
        .args = .{ .read = .{
            .path = path,
            .from_line = 2,
            .to_line = 3,
        } },
        .src = .system,
        .at_ms = 5,
    };

    const res = try handler.run(call, sink);
    defer handler.deinitResult(res);

    try std.testing.expectEqual(@as(i64, 55), res.started_at_ms);
    try std.testing.expectEqual(@as(i64, 55), res.ended_at_ms);
    try std.testing.expectEqual(@as(usize, 1), res.out.len);
    try std.testing.expectEqual(@as(i64, 55), res.out[0].at_ms);
    try std.testing.expect(res.out[0].stream == .stdout);
    try std.testing.expectEqualStrings("b\nc\n", res.out[0].chunk);

    switch (res.final) {
        .ok => |ok| try std.testing.expectEqual(@as(i32, 0), ok.code),
        else => return error.TestUnexpectedResult,
    }
}

test "read handler returns invalid args on reversed line range" {
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
        .id = "c2",
        .kind = .read,
        .args = .{ .read = .{
            .path = "ignored",
            .from_line = 3,
            .to_line = 2,
        } },
        .src = .model,
        .at_ms = 0,
    };

    try std.testing.expectError(error.InvalidArgs, handler.run(call, sink));
}

test "read handler returns not found for missing file" {
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
        .id = "c3",
        .kind = .read,
        .args = .{ .read = .{
            .path = "this-file-should-not-exist-7b3908b0.txt",
        } },
        .src = .model,
        .at_ms = 0,
    };

    try std.testing.expectError(error.NotFound, handler.run(call, sink));
}

test "read handler returns kind mismatch for wrong call kind" {
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
        .id = "c4",
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
