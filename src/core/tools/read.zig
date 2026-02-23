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

        const selected = try readSelected(self, args.path, from_line, args.to_line);
        errdefer self.alloc.free(selected.chunk);

        const meta = tools.output.metaFor(self.max_bytes, selected.full_bytes);
        var meta_chunk: ?[]u8 = null;
        if (meta) |m| {
            meta_chunk = tools.output.metaJsonAlloc(self.alloc, .stdout, m) catch return error.OutOfMemory;
        }
        errdefer if (meta_chunk) |chunk| self.alloc.free(chunk);

        const out_len: usize = 1 + @as(usize, @intFromBool(meta_chunk != null));
        const out = self.alloc.alloc(tools.Output, out_len) catch return error.OutOfMemory;
        errdefer self.alloc.free(out);

        out[0] = .{
            .call_id = call.id,
            .seq = 0,
            .at_ms = self.now_ms,
            .stream = .stdout,
            .chunk = selected.chunk,
            .owned = true,
            .truncated = meta != null,
        };

        if (meta_chunk) |chunk| {
            out[1] = .{
                .call_id = call.id,
                .seq = 1,
                .at_ms = self.now_ms,
                .stream = .meta,
                .chunk = chunk,
                .owned = true,
                .truncated = false,
            };
            meta_chunk = null;
        }

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

const Selected = struct {
    chunk: []u8,
    full_bytes: usize,
};

const Acc = struct {
    alloc: std.mem.Allocator,
    limit: usize,
    buf: std.ArrayList(u8) = .empty,
    full_bytes: usize = 0,

    fn init(alloc: std.mem.Allocator, limit: usize) Acc {
        return .{
            .alloc = alloc,
            .limit = limit,
        };
    }

    fn deinit(self: *Acc) void {
        self.buf.deinit(self.alloc);
        self.* = undefined;
    }

    fn appendByte(self: *Acc, b: u8) std.mem.Allocator.Error!void {
        self.full_bytes = satAdd(self.full_bytes, 1);
        if (self.buf.items.len >= self.limit) return;
        try self.buf.append(self.alloc, b);
    }

    fn takeOwned(self: *Acc) std.mem.Allocator.Error![]u8 {
        const out = try self.buf.toOwnedSlice(self.alloc);
        self.buf = .empty;
        return out;
    }
};

fn readSelected(self: Handler, path: []const u8, from_line: u32, to_line: ?u32) Err!Selected {
    var file = std.fs.cwd().openFile(path, .{ .mode = .read_only }) catch |open_err| {
        return mapReadErr(open_err);
    };
    defer file.close();

    const last_line = to_line orelse std.math.maxInt(u32);
    var line_no: u32 = 1;
    var in_range = line_no >= from_line and line_no <= last_line;

    var acc = Acc.init(self.alloc, self.max_bytes);
    defer acc.deinit();

    var scratch: [4096]u8 = undefined;
    while (true) {
        const n = file.read(&scratch) catch |read_err| {
            return mapReadErr(read_err);
        };
        if (n == 0) break;

        var i: usize = 0;
        while (i < n) : (i += 1) {
            const b = scratch[i];
            if (in_range) try acc.appendByte(b);

            if (b == '\n') {
                if (line_no == last_line) {
                    return .{
                        .chunk = acc.takeOwned() catch return error.OutOfMemory,
                        .full_bytes = acc.full_bytes,
                    };
                }
                line_no = satAddU32(line_no, 1);
                in_range = line_no >= from_line and line_no <= last_line;
            }
        }
    }

    return .{
        .chunk = acc.takeOwned() catch return error.OutOfMemory,
        .full_bytes = acc.full_bytes,
    };
}

fn mapReadErr(err: anyerror) Err {
    return switch (err) {
        error.FileNotFound => error.NotFound,
        error.AccessDenied, error.PermissionDenied => error.Denied,
        error.OutOfMemory => error.OutOfMemory,
        else => error.Io,
    };
}

fn satAdd(a: usize, b: usize) usize {
    const out, const ov = @addWithOverflow(a, b);
    if (ov == 0) return out;
    return std.math.maxInt(usize);
}

fn satAddU32(a: u32, b: u32) u32 {
    const out, const ov = @addWithOverflow(a, b);
    if (ov == 0) return out;
    return std.math.maxInt(u32);
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

test "read handler truncates oversized output instead of failing TooLarge" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var text = std.ArrayList(u8).empty;
    defer text.deinit(std.testing.allocator);
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        try text.appendSlice(std.testing.allocator, "line-data-1234567890\n");
    }

    try tmp.dir.writeFile(.{ .sub_path = "big.txt", .data = text.items });
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "big.txt");
    defer std.testing.allocator.free(path);

    const SinkImpl = struct {
        fn push(_: *@This(), _: tools.Event) !void {}
    };
    var sink_impl = SinkImpl{};
    const sink = tools.Sink.from(SinkImpl, &sink_impl, SinkImpl.push);

    const handler = Handler.init(.{
        .alloc = std.testing.allocator,
        .max_bytes = 128,
        .now_ms = 99,
    });
    const call: tools.Call = .{
        .id = "c-big",
        .kind = .read,
        .args = .{ .read = .{ .path = path } },
        .src = .model,
        .at_ms = 0,
    };

    const res = try handler.run(call, sink);
    defer handler.deinitResult(res);

    try std.testing.expectEqual(@as(usize, 2), res.out.len);
    try std.testing.expectEqual(@as(usize, 128), res.out[0].chunk.len);
    try std.testing.expect(res.out[0].truncated);
    try std.testing.expect(res.out[1].stream == .meta);
    try std.testing.expect(std.mem.indexOf(u8, res.out[1].chunk, "\"type\":\"trunc\"") != null);
}

test "read handler can target a line in very large file without TooLarge" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var txt = std.ArrayList(u8).empty;
    defer txt.deinit(std.testing.allocator);
    var w = txt.writer(std.testing.allocator);
    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        try w.print("line-{d}\n", .{i + 1});
    }
    try tmp.dir.writeFile(.{ .sub_path = "huge.txt", .data = txt.items });

    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "huge.txt");
    defer std.testing.allocator.free(path);

    const SinkImpl = struct {
        fn push(_: *@This(), _: tools.Event) !void {}
    };
    var sink_impl = SinkImpl{};
    const sink = tools.Sink.from(SinkImpl, &sink_impl, SinkImpl.push);

    const handler = Handler.init(.{
        .alloc = std.testing.allocator,
        .max_bytes = 64,
    });

    const call: tools.Call = .{
        .id = "c-huge",
        .kind = .read,
        .args = .{ .read = .{
            .path = path,
            .from_line = 9999,
            .to_line = 9999,
        } },
        .src = .model,
        .at_ms = 0,
    };

    const res = try handler.run(call, sink);
    defer handler.deinitResult(res);

    try std.testing.expectEqual(@as(usize, 1), res.out.len);
    try std.testing.expectEqualStrings("line-9999\n", res.out[0].chunk);
    try std.testing.expect(!res.out[0].truncated);
}
