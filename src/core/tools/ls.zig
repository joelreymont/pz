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
        if (call.kind != .ls) return error.KindMismatch;
        if (std.meta.activeTag(call.args) != .ls) return error.KindMismatch;

        const args = call.args.ls;
        if (args.path.len == 0) return error.InvalidArgs;

        var dir = std.fs.cwd().openDir(args.path, .{ .iterate = true }) catch |open_err| {
            return mapDirErr(open_err);
        };
        defer dir.close();

        var items = std.ArrayList(Item).empty;
        defer {
            for (items.items) |it| self.alloc.free(it.name);
            items.deinit(self.alloc);
        }

        var it = dir.iterate();
        while (it.next() catch |next_err| return mapDirErr(next_err)) |ent| {
            if (!args.all and ent.name.len > 0 and ent.name[0] == '.') continue;

            const name = self.alloc.dupe(u8, ent.name) catch return error.OutOfMemory;
            errdefer self.alloc.free(name);
            items.append(self.alloc, .{
                .name = name,
                .kind = ent.kind,
            }) catch return error.OutOfMemory;
        }

        std.sort.pdq(Item, items.items, {}, lessItem);

        var acc = Acc.init(self.alloc, self.max_bytes);
        defer acc.deinit();

        for (items.items) |item| {
            try acc.append(item.name);
            if (item.kind == .directory) try acc.append("/");
            try acc.append("\n");
        }

        const data = acc.takeOwned() catch return error.OutOfMemory;
        errdefer self.alloc.free(data);

        const meta = tools.output.metaFor(self.max_bytes, acc.full_bytes);
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
            .chunk = data,
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

const Item = struct {
    name: []u8,
    kind: std.fs.Dir.Entry.Kind,
};

fn lessItem(_: void, a: Item, b: Item) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

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

    fn append(self: *Acc, data: []const u8) !void {
        self.full_bytes = satAdd(self.full_bytes, data.len);
        if (self.buf.items.len >= self.limit) return;

        const keep = @min(data.len, self.limit - self.buf.items.len);
        if (keep == 0) return;
        try self.buf.appendSlice(self.alloc, data[0..keep]);
    }

    fn takeOwned(self: *Acc) ![]u8 {
        const out = try self.buf.toOwnedSlice(self.alloc);
        self.buf = .empty;
        return out;
    }
};

fn satAdd(a: usize, b: usize) usize {
    const sum, const ov = @addWithOverflow(a, b);
    if (ov == 0) return sum;
    return std.math.maxInt(usize);
}

fn mapDirErr(err: anyerror) Err {
    return switch (err) {
        error.FileNotFound => error.NotFound,
        error.AccessDenied, error.PermissionDenied => error.Denied,
        error.OutOfMemory => error.OutOfMemory,
        else => error.Io,
    };
}

test "ls handler lists entries in deterministic order and marks directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("d");
    try tmp.dir.writeFile(.{ .sub_path = "b.txt", .data = "b" });
    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "a" });

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    const SinkImpl = struct {
        fn push(_: *@This(), _: tools.Event) !void {}
    };
    var sink_impl = SinkImpl{};
    const sink = tools.Sink.from(SinkImpl, &sink_impl, SinkImpl.push);

    const handler = Handler.init(.{
        .alloc = std.testing.allocator,
        .max_bytes = 1024,
        .now_ms = 44,
    });
    const call: tools.Call = .{
        .id = "l1",
        .kind = .ls,
        .args = .{ .ls = .{
            .path = root,
        } },
        .src = .model,
        .at_ms = 0,
    };

    const res = try handler.run(call, sink);
    defer handler.deinitResult(res);

    try std.testing.expectEqual(@as(usize, 1), res.out.len);
    try std.testing.expectEqualStrings("a.txt\nb.txt\nd/\n", res.out[0].chunk);
}

test "ls handler rejects missing path and wrong kind" {
    const SinkImpl = struct {
        fn push(_: *@This(), _: tools.Event) !void {}
    };
    var sink_impl = SinkImpl{};
    const sink = tools.Sink.from(SinkImpl, &sink_impl, SinkImpl.push);

    const handler = Handler.init(.{
        .alloc = std.testing.allocator,
        .max_bytes = 64,
    });

    const bad_kind: tools.Call = .{
        .id = "l2",
        .kind = .read,
        .args = .{ .read = .{ .path = "x" } },
        .src = .model,
        .at_ms = 0,
    };
    try std.testing.expectError(error.KindMismatch, handler.run(bad_kind, sink));

    const missing: tools.Call = .{
        .id = "l3",
        .kind = .ls,
        .args = .{ .ls = .{ .path = "no-such-dir-29341" } },
        .src = .model,
        .at_ms = 0,
    };
    try std.testing.expectError(error.NotFound, handler.run(missing, sink));
}

test "ls handler emits truncation metadata when output exceeds limit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "one", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "two", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "three", .data = "" });

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    const SinkImpl = struct {
        fn push(_: *@This(), _: tools.Event) !void {}
    };
    var sink_impl = SinkImpl{};
    const sink = tools.Sink.from(SinkImpl, &sink_impl, SinkImpl.push);

    const handler = Handler.init(.{
        .alloc = std.testing.allocator,
        .max_bytes = 8,
    });
    const call: tools.Call = .{
        .id = "l4",
        .kind = .ls,
        .args = .{ .ls = .{ .path = root } },
        .src = .model,
        .at_ms = 0,
    };
    const res = try handler.run(call, sink);
    defer handler.deinitResult(res);

    try std.testing.expectEqual(@as(usize, 2), res.out.len);
    try std.testing.expect(res.out[0].truncated);
    try std.testing.expect(res.out[1].stream == .meta);
}
