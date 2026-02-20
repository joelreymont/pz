const std = @import("std");
const providers = @import("contract.zig");
const retry = @import("retry.zig");
const streaming = @import("streaming.zig");
const types = @import("types.zig");

pub const Err = types.Err;
pub const Pol = retry.Policy(Err);

pub const RawChunkStream = struct {
    ctx: *anyopaque,
    vt: *const Vt,

    pub const Vt = struct {
        next: *const fn (ctx: *anyopaque) anyerror!?[]const u8,
        deinit: *const fn (ctx: *anyopaque) void,
    };

    pub fn from(
        comptime T: type,
        ctx: *T,
        comptime next_fn: anytype,
        comptime deinit_fn: fn (ctx: *T) void,
    ) RawChunkStream {
        const Wrap = struct {
            fn next(raw: *anyopaque) anyerror!?[]const u8 {
                const typed: *T = @ptrCast(@alignCast(raw));
                return next_fn(typed);
            }

            fn deinit(raw: *anyopaque) void {
                const typed: *T = @ptrCast(@alignCast(raw));
                deinit_fn(typed);
            }

            const vt = Vt{
                .next = @This().next,
                .deinit = @This().deinit,
            };
        };

        return .{
            .ctx = ctx,
            .vt = &Wrap.vt,
        };
    }

    pub fn next(self: *RawChunkStream) anyerror!?[]const u8 {
        return self.vt.next(self.ctx);
    }

    pub fn deinit(self: *RawChunkStream) void {
        self.vt.deinit(self.ctx);
    }
};

pub const RawTransport = struct {
    ctx: *anyopaque,
    vt: *const Vt,

    pub const Vt = struct {
        start: *const fn (ctx: *anyopaque, req_wire: []const u8) anyerror!RawChunkStream,
    };

    pub fn from(
        comptime T: type,
        ctx: *T,
        comptime start_fn: anytype,
    ) RawTransport {
        const Wrap = struct {
            fn start(raw: *anyopaque, req_wire: []const u8) anyerror!RawChunkStream {
                const typed: *T = @ptrCast(@alignCast(raw));
                return start_fn(typed, req_wire);
            }

            const vt = Vt{
                .start = @This().start,
            };
        };

        return .{
            .ctx = ctx,
            .vt = &Wrap.vt,
        };
    }

    pub fn start(self: RawTransport, req_wire: []const u8) anyerror!RawChunkStream {
        return self.vt.start(self.ctx, req_wire);
    }
};

pub const Client = struct {
    alloc: std.mem.Allocator,
    tr: RawTransport,
    map: types.Adapter,
    pol: Pol,
    slp: ?streaming.Sleeper = null,

    pub fn init(
        alloc: std.mem.Allocator,
        tr: RawTransport,
        map: types.Adapter,
        pol: Pol,
        slp: ?streaming.Sleeper,
    ) Client {
        return .{
            .alloc = alloc,
            .tr = tr,
            .map = map,
            .pol = pol,
            .slp = slp,
        };
    }

    pub fn asProvider(self: *Client) providers.Provider {
        return providers.Provider.from(Client, self, Client.start);
    }

    fn start(self: *Client, req: providers.Req) anyerror!providers.Stream {
        const req_wire = try buildReq(self.alloc, req);
        defer self.alloc.free(req_wire);

        var run_tr = RunTr{
            .tr = self.tr,
            .map = self.map,
            .req_wire = req_wire,
        };

        const out = try streaming.run(
            self.alloc,
            run_tr.asTransport(),
            req,
            self.pol,
            self.slp,
        );

        const st = try self.alloc.create(BufStream);
        st.* = .{
            .alloc = self.alloc,
            .out = out,
        };

        return providers.Stream.from(BufStream, st, BufStream.next, BufStream.deinit);
    }
};

const RunTr = struct {
    tr: RawTransport,
    map: types.Adapter,
    req_wire: []const u8,
    chunk: ChunkCtx = .{},

    const ChunkCtx = struct {
        raw: RawChunkStream = undefined,
        has_raw: bool = false,
        map: types.Adapter = undefined,

        fn next(self: *ChunkCtx) Err!?[]const u8 {
            if (!self.has_raw) return error.TransportFatal;
            return self.raw.next() catch |err| return self.map.map(err);
        }

        fn deinit(self: *ChunkCtx) void {
            if (self.has_raw) {
                self.raw.deinit();
                self.has_raw = false;
            }
        }
    };

    fn asTransport(self: *RunTr) streaming.Transport {
        return streaming.Transport.from(RunTr, self, RunTr.start);
    }

    fn start(self: *RunTr, _: providers.Req) Err!streaming.ChunkStream {
        const raw = self.tr.start(self.req_wire) catch |err| return self.map.map(err);

        self.chunk = .{
            .raw = raw,
            .has_raw = true,
            .map = self.map,
        };

        return streaming.ChunkStream.from(ChunkCtx, &self.chunk, ChunkCtx.next, ChunkCtx.deinit);
    }
};

const BufStream = struct {
    alloc: std.mem.Allocator,
    out: streaming.RunRes,
    idx: usize = 0,

    fn next(self: *BufStream) anyerror!?providers.Ev {
        if (self.idx >= self.out.evs.len) return null;

        const ev = self.out.evs[self.idx];
        self.idx += 1;
        return ev;
    }

    fn deinit(self: *BufStream) void {
        self.out.deinit();
        self.alloc.destroy(self);
    }
};

pub fn buildReq(alloc: std.mem.Allocator, req: providers.Req) Err![]u8 {
    var out: std.io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    var js: std.json.Stringify = .{
        .writer = &out.writer,
        .options = .{},
    };

    writeReq(&js, req) catch return error.OutOfMemory;

    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn writeReq(js: *std.json.Stringify, req: providers.Req) anyerror!void {
    try js.beginObject();

    try js.objectField("model");
    try js.write(req.model);

    if (req.provider) |provider| {
        try js.objectField("provider");
        try js.write(provider);
    }

    try js.objectField("msgs");
    try js.beginArray();
    for (req.msgs) |msg| {
        try js.beginObject();

        try js.objectField("role");
        try js.write(@tagName(msg.role));

        try js.objectField("parts");
        try js.beginArray();
        for (msg.parts) |part| {
            try writePart(js, part);
        }
        try js.endArray();

        try js.endObject();
    }
    try js.endArray();

    try js.objectField("tools");
    try js.beginArray();
    for (req.tools) |tool| {
        try js.beginObject();
        try js.objectField("name");
        try js.write(tool.name);
        try js.objectField("desc");
        try js.write(tool.desc);
        try js.objectField("schema");
        try js.write(tool.schema);
        try js.endObject();
    }
    try js.endArray();

    try js.objectField("opts");
    try js.beginObject();

    if (req.opts.temp) |temp| {
        try js.objectField("temp");
        try js.write(temp);
    }
    if (req.opts.top_p) |top_p| {
        try js.objectField("top_p");
        try js.write(top_p);
    }
    if (req.opts.max_out) |max_out| {
        try js.objectField("max_out");
        try js.write(max_out);
    }

    try js.objectField("stop");
    try js.beginArray();
    for (req.opts.stop) |stop_tok| {
        try js.write(stop_tok);
    }
    try js.endArray();

    try js.endObject();

    try js.endObject();
}

fn writePart(js: *std.json.Stringify, part: providers.Part) anyerror!void {
    try js.beginObject();

    switch (part) {
        .text => |txt| {
            try js.objectField("type");
            try js.write("text");
            try js.objectField("text");
            try js.write(txt);
        },
        .tool_call => |tc| {
            try js.objectField("type");
            try js.write("tool_call");
            try js.objectField("id");
            try js.write(tc.id);
            try js.objectField("name");
            try js.write(tc.name);
            try js.objectField("args");
            try js.write(tc.args);
        },
        .tool_result => |tr| {
            try js.objectField("type");
            try js.write("tool_result");
            try js.objectField("id");
            try js.write(tr.id);
            try js.objectField("out");
            try js.write(tr.out);
            try js.objectField("is_err");
            try js.write(tr.is_err);
        },
    }

    try js.endObject();
}

const RawErr = error{
    Timeout,
    Closed,
    WireBreak,
    BadGateway,
};

const MapCtx = struct {
    calls: usize = 0,
};

fn mapErr(ctx: *MapCtx, err: anyerror) Err {
    ctx.calls += 1;

    if (err == error.Timeout or err == error.WireBreak) return error.TransportTransient;
    if (err == error.Closed or err == error.BadGateway) return error.TransportFatal;
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return error.TransportFatal;
}

const Attempt = struct {
    start_err: ?RawErr = null,
    chunks: []const []const u8 = &.{},
    fail_after: ?usize = null,
    fail_err: RawErr = error.WireBreak,
};

const MockRawChunk = struct {
    at: ?*const Attempt = null,
    idx: usize = 0,
    did_fail: bool = false,

    fn next(self: *MockRawChunk) RawErr!?[]const u8 {
        const at = self.at orelse return error.Closed;

        if (!self.did_fail) {
            if (at.fail_after) |fail_after| {
                if (self.idx == fail_after) {
                    self.did_fail = true;
                    return at.fail_err;
                }
            }
        }

        if (self.idx >= at.chunks.len) return null;
        const out = at.chunks[self.idx];
        self.idx += 1;
        return out;
    }

    fn deinit(_: *MockRawChunk) void {}
};

const MockRawTr = struct {
    alloc: std.mem.Allocator,
    atts: []const Attempt,
    start_ct: usize = 0,
    stream: MockRawChunk = .{},
    reqs: std.ArrayListUnmanaged([]u8) = .{},

    fn init(alloc: std.mem.Allocator, atts: []const Attempt) MockRawTr {
        return .{
            .alloc = alloc,
            .atts = atts,
        };
    }

    fn deinit(self: *MockRawTr) void {
        for (self.reqs.items) |req_wire| {
            self.alloc.free(req_wire);
        }
        self.reqs.deinit(self.alloc);
    }

    fn asRawTransport(self: *MockRawTr) RawTransport {
        return RawTransport.from(MockRawTr, self, MockRawTr.start);
    }

    fn start(self: *MockRawTr, req_wire: []const u8) anyerror!RawChunkStream {
        const req_copy = try self.alloc.dupe(u8, req_wire);
        try self.reqs.append(self.alloc, req_copy);

        if (self.start_ct >= self.atts.len) return error.Closed;
        const idx = self.start_ct;
        self.start_ct += 1;

        const at = &self.atts[idx];
        if (at.start_err) |err| return err;

        self.stream = .{
            .at = at,
            .idx = 0,
            .did_fail = false,
        };

        return RawChunkStream.from(MockRawChunk, &self.stream, MockRawChunk.next, MockRawChunk.deinit);
    }
};

const WaitLog = struct {
    waits: [8]u64 = [_]u64{0} ** 8,
    len: usize = 0,

    fn asSleeper(self: *WaitLog) streaming.Sleeper {
        return streaming.Sleeper.from(WaitLog, self, WaitLog.wait);
    }

    fn wait(self: *WaitLog, wait_ms: u64) void {
        self.waits[self.len] = wait_ms;
        self.len += 1;
    }
};

fn mkPol(max_tries: u16) !Pol {
    return Pol.init(.{
        .max_tries = max_tries,
        .backoff = .{
            .base_ms = 10,
            .max_ms = 60,
            .mul = 2,
        },
        .retryable = types.retryable,
    });
}

fn expectString(v: std.json.Value, want: []const u8) !void {
    switch (v) {
        .string => |got| try std.testing.expectEqualStrings(want, got),
        else => return error.TestUnexpectedResult,
    }
}

fn expectInt(v: std.json.Value, want: i64) !void {
    switch (v) {
        .integer => |got| try std.testing.expectEqual(want, got),
        else => return error.TestUnexpectedResult,
    }
}

fn expectFloat(v: std.json.Value, want: f64) !void {
    switch (v) {
        .float => |got| try std.testing.expectApproxEqAbs(want, got, 0.0001),
        .integer => |got| try std.testing.expectApproxEqAbs(want, @as(f64, @floatFromInt(got)), 0.0001),
        else => return error.TestUnexpectedResult,
    }
}

test "buildReq emits request fixture JSON" {
    const user_parts = [_]providers.Part{
        .{ .text = "hello" },
        .{ .tool_call = .{ .id = "c1", .name = "read", .args = "{\"path\":\"/tmp\"}" } },
    };
    const tool_parts = [_]providers.Part{
        .{ .tool_result = .{ .id = "c1", .out = "ok", .is_err = false } },
    };
    const msgs = [_]providers.Msg{
        .{ .role = .user, .parts = user_parts[0..] },
        .{ .role = .tool, .parts = tool_parts[0..] },
    };
    const tools = [_]providers.Tool{
        .{ .name = "read", .desc = "Read file", .schema = "{}" },
    };
    const stops = [_][]const u8{ "DONE", "ERR" };

    const req: providers.Req = .{
        .model = "first-model",
        .msgs = msgs[0..],
        .tools = tools[0..],
        .opts = .{
            .temp = 0.25,
            .top_p = 0.9,
            .max_out = 128,
            .stop = stops[0..],
        },
    };

    const raw = try buildReq(std.testing.allocator, req);
    defer std.testing.allocator.free(raw);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try expectString(root.get("model") orelse return error.TestUnexpectedResult, "first-model");
    try std.testing.expect(root.get("provider") == null);

    const msgs_v = root.get("msgs") orelse return error.TestUnexpectedResult;
    const msgs_arr = switch (msgs_v) {
        .array => |arr| arr,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 2), msgs_arr.items.len);

    const first_msg = switch (msgs_arr.items[0]) {
        .object => |obj| obj,
        else => return error.TestUnexpectedResult,
    };
    try expectString(first_msg.get("role") orelse return error.TestUnexpectedResult, "user");

    const parts_v = first_msg.get("parts") orelse return error.TestUnexpectedResult;
    const parts_arr = switch (parts_v) {
        .array => |arr| arr,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 2), parts_arr.items.len);

    const part0 = switch (parts_arr.items[0]) {
        .object => |obj| obj,
        else => return error.TestUnexpectedResult,
    };
    try expectString(part0.get("type") orelse return error.TestUnexpectedResult, "text");
    try expectString(part0.get("text") orelse return error.TestUnexpectedResult, "hello");

    const opts_v = root.get("opts") orelse return error.TestUnexpectedResult;
    const opts = switch (opts_v) {
        .object => |obj| obj,
        else => return error.TestUnexpectedResult,
    };
    try expectFloat(opts.get("temp") orelse return error.TestUnexpectedResult, 0.25);
    try expectFloat(opts.get("top_p") orelse return error.TestUnexpectedResult, 0.9);
    try expectInt(opts.get("max_out") orelse return error.TestUnexpectedResult, 128);

    const stop_v = opts.get("stop") orelse return error.TestUnexpectedResult;
    const stop_arr = switch (stop_v) {
        .array => |arr| arr,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 2), stop_arr.items.len);
    try expectString(stop_arr.items[0], "DONE");
    try expectString(stop_arr.items[1], "ERR");
}

test "buildReq includes provider field when set" {
    const msgs = [_]providers.Msg{
        .{ .role = .user, .parts = &.{.{ .text = "hi" }} },
    };
    const req: providers.Req = .{
        .model = "m1",
        .provider = "anthropic",
        .msgs = msgs[0..],
    };

    const raw = try buildReq(std.testing.allocator, req);
    defer std.testing.allocator.free(raw);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try expectString(root.get("model") orelse return error.TestUnexpectedResult, "m1");
    try expectString(root.get("provider") orelse return error.TestUnexpectedResult, "anthropic");
}

test "first provider retries transient start and streams parsed events" {
    const atts = [_]Attempt{
        .{ .start_err = error.Timeout },
        .{ .chunks = &.{"text:hello\nstop:done\n"} },
    };

    var tr = MockRawTr.init(std.testing.allocator, atts[0..]);
    defer tr.deinit();

    var waits = WaitLog{};
    const pol = try mkPol(3);

    var map_ctx = MapCtx{};
    var client = Client.init(
        std.testing.allocator,
        tr.asRawTransport(),
        types.Adapter.from(MapCtx, &map_ctx, mapErr),
        pol,
        waits.asSleeper(),
    );

    const req: providers.Req = .{
        .model = "first-model",
        .msgs = &.{},
    };

    var stream = try client.asProvider().start(req);
    defer stream.deinit();

    const ev0 = (try stream.next()) orelse return error.TestUnexpectedResult;
    const ev1 = (try stream.next()) orelse return error.TestUnexpectedResult;
    try std.testing.expect((try stream.next()) == null);

    switch (ev0) {
        .text => |txt| try std.testing.expectEqualStrings("hello", txt),
        else => return error.TestUnexpectedResult,
    }
    switch (ev1) {
        .stop => |stop| try std.testing.expect(stop.reason == .done),
        else => return error.TestUnexpectedResult,
    }

    try std.testing.expectEqual(@as(usize, 2), tr.start_ct);
    try std.testing.expectEqual(@as(usize, 2), tr.reqs.items.len);
    try std.testing.expectEqualStrings(tr.reqs.items[0], tr.reqs.items[1]);
    try std.testing.expect(std.mem.indexOf(u8, tr.reqs.items[0], "\"model\":\"first-model\"") != null);

    try std.testing.expectEqual(@as(usize, 1), waits.len);
    try std.testing.expectEqual(@as(u64, 10), waits.waits[0]);
    try std.testing.expectEqual(@as(usize, 1), map_ctx.calls);
}

test "first provider maps fatal transport errors without retry" {
    const atts = [_]Attempt{
        .{ .start_err = error.BadGateway },
    };

    var tr = MockRawTr.init(std.testing.allocator, atts[0..]);
    defer tr.deinit();

    var waits = WaitLog{};
    const pol = try mkPol(3);

    var map_ctx = MapCtx{};
    var client = Client.init(
        std.testing.allocator,
        tr.asRawTransport(),
        types.Adapter.from(MapCtx, &map_ctx, mapErr),
        pol,
        waits.asSleeper(),
    );

    const req: providers.Req = .{
        .model = "m",
        .msgs = &.{},
    };

    try std.testing.expectError(error.TransportFatal, client.asProvider().start(req));
    try std.testing.expectEqual(@as(usize, 1), tr.start_ct);
    try std.testing.expectEqual(@as(usize, 0), waits.len);
    try std.testing.expectEqual(@as(usize, 1), map_ctx.calls);
}

test "first provider retries on transient chunk read failures" {
    const atts = [_]Attempt{
        .{
            .chunks = &.{"text:bad\n"},
            .fail_after = 1,
            .fail_err = error.WireBreak,
        },
        .{
            .chunks = &.{"text:good\nstop:done\n"},
        },
    };

    var tr = MockRawTr.init(std.testing.allocator, atts[0..]);
    defer tr.deinit();

    var waits = WaitLog{};
    const pol = try mkPol(3);

    var map_ctx = MapCtx{};
    var client = Client.init(
        std.testing.allocator,
        tr.asRawTransport(),
        types.Adapter.from(MapCtx, &map_ctx, mapErr),
        pol,
        waits.asSleeper(),
    );

    const req: providers.Req = .{
        .model = "m",
        .msgs = &.{},
    };

    var stream = try client.asProvider().start(req);
    defer stream.deinit();

    const ev0 = (try stream.next()) orelse return error.TestUnexpectedResult;
    const ev1 = (try stream.next()) orelse return error.TestUnexpectedResult;
    try std.testing.expect((try stream.next()) == null);

    switch (ev0) {
        .text => |txt| try std.testing.expectEqualStrings("good", txt),
        else => return error.TestUnexpectedResult,
    }
    switch (ev1) {
        .stop => |stop| try std.testing.expect(stop.reason == .done),
        else => return error.TestUnexpectedResult,
    }

    try std.testing.expectEqual(@as(usize, 2), tr.start_ct);
    try std.testing.expectEqual(@as(usize, 1), waits.len);
    try std.testing.expectEqual(@as(u64, 10), waits.waits[0]);
    try std.testing.expectEqual(@as(usize, 1), map_ctx.calls);
}
