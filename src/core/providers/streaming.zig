const std = @import("std");
const providers = @import("contract.zig");
const retry = @import("retry.zig");
const stream_parse = @import("stream_parse.zig");
const types = @import("types.zig");

pub const Err = types.Err;

pub const Pol = retry.Policy(Err);

pub fn retryable(err: Err) bool {
    return types.retryable(err);
}

pub const ChunkStream = struct {
    ctx: *anyopaque,
    vt: *const Vt,

    pub const Vt = struct {
        next: *const fn (ctx: *anyopaque) Err!?[]const u8,
        deinit: *const fn (ctx: *anyopaque) void,
    };

    pub fn from(
        comptime T: type,
        ctx: *T,
        comptime next_fn: fn (ctx: *T) Err!?[]const u8,
        comptime deinit_fn: fn (ctx: *T) void,
    ) ChunkStream {
        const Wrap = struct {
            fn next(raw: *anyopaque) Err!?[]const u8 {
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

    pub fn next(self: *ChunkStream) Err!?[]const u8 {
        return self.vt.next(self.ctx);
    }

    pub fn deinit(self: *ChunkStream) void {
        self.vt.deinit(self.ctx);
    }
};

pub const Transport = struct {
    ctx: *anyopaque,
    vt: *const Vt,

    pub const Vt = struct {
        start: *const fn (ctx: *anyopaque, req: providers.Req) Err!ChunkStream,
    };

    pub fn from(
        comptime T: type,
        ctx: *T,
        comptime start_fn: fn (ctx: *T, req: providers.Req) Err!ChunkStream,
    ) Transport {
        const Wrap = struct {
            fn start(raw: *anyopaque, req: providers.Req) Err!ChunkStream {
                const typed: *T = @ptrCast(@alignCast(raw));
                return start_fn(typed, req);
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

    pub fn start(self: Transport, req: providers.Req) Err!ChunkStream {
        return self.vt.start(self.ctx, req);
    }
};

pub const Sleeper = struct {
    ctx: *anyopaque,
    wait_fn: *const fn (ctx: *anyopaque, wait_ms: u64) void,

    pub fn from(
        comptime T: type,
        ctx: *T,
        comptime wait_fn: fn (ctx: *T, wait_ms: u64) void,
    ) Sleeper {
        const Wrap = struct {
            fn wait(raw: *anyopaque, wait_ms: u64) void {
                const typed: *T = @ptrCast(@alignCast(raw));
                wait_fn(typed, wait_ms);
            }
        };

        return .{
            .ctx = ctx,
            .wait_fn = Wrap.wait,
        };
    }

    pub fn wait(self: Sleeper, wait_ms: u64) void {
        self.wait_fn(self.ctx, wait_ms);
    }
};

pub const RunRes = struct {
    arena: std.heap.ArenaAllocator,
    evs: []providers.Ev,
    tries: u16,

    pub fn deinit(self: *RunRes) void {
        self.arena.deinit();
    }
};

pub fn run(
    alloc: std.mem.Allocator,
    tr: Transport,
    req: providers.Req,
    pol: Pol,
    slp: ?Sleeper,
) (retry.StepErr || Err)!RunRes {
    var tries: u16 = 0;
    while (true) {
        tries += 1;

        var arena = std.heap.ArenaAllocator.init(alloc);
        const ar = arena.allocator();
        const res = runOnce(ar, tr, req);
        if (res) |evs| {
            return .{
                .arena = arena,
                .evs = evs,
                .tries = tries,
            };
        } else |err| {
            arena.deinit();

            const step = try pol.next(err, tries);
            switch (step) {
                .retry_after_ms => |wait_ms| {
                    if (slp) |s| s.wait(wait_ms);
                },
                .fail => return err,
            }
        }
    }
}

fn runOnce(alloc: std.mem.Allocator, tr: Transport, req: providers.Req) Err![]providers.Ev {
    var stream = try tr.start(req);
    defer stream.deinit();

    var p = stream_parse.Parser{};
    defer p.deinit(alloc);

    var evs: std.ArrayListUnmanaged(providers.Ev) = .{};
    errdefer evs.deinit(alloc);

    while (try stream.next()) |chunk| {
        try p.feed(alloc, &evs, chunk);
    }
    try p.finish(alloc, &evs);

    return evs.toOwnedSlice(alloc);
}

const Attempt = struct {
    start_err: ?Err = null,
    chunks: []const []const u8 = &.{},
    fail_after: ?usize = null,
    fail_err: Err = error.TransportTransient,
};

const MockChunk = struct {
    at: ?*const Attempt = null,
    idx: usize = 0,
    did_fail: bool = false,

    fn next(self: *MockChunk) Err!?[]const u8 {
        const at = self.at orelse return error.TransportFatal;

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

    fn deinit(_: *MockChunk) void {}
};

const MockTr = struct {
    atts: []const Attempt,
    start_ct: usize = 0,
    stream: MockChunk = .{},

    fn init(atts: []const Attempt) MockTr {
        return .{
            .atts = atts,
        };
    }

    fn asTransport(self: *MockTr) Transport {
        return Transport.from(MockTr, self, MockTr.start);
    }

    fn start(self: *MockTr, _: providers.Req) Err!ChunkStream {
        if (self.start_ct >= self.atts.len) return error.TransportFatal;
        const idx = self.start_ct;
        self.start_ct += 1;

        const at = &self.atts[idx];
        if (at.start_err) |err| return err;

        self.stream = .{
            .at = at,
            .idx = 0,
            .did_fail = false,
        };
        return ChunkStream.from(MockChunk, &self.stream, MockChunk.next, MockChunk.deinit);
    }
};

const WaitLog = struct {
    waits: [8]u64 = [_]u64{0} ** 8,
    len: usize = 0,

    fn asSleeper(self: *WaitLog) Sleeper {
        return Sleeper.from(WaitLog, self, WaitLog.wait);
    }

    fn wait(self: *WaitLog, wait_ms: u64) void {
        self.waits[self.len] = wait_ms;
        self.len += 1;
    }
};

fn reqStub() providers.Req {
    return .{
        .model = "stub",
        .msgs = &.{},
    };
}

fn mkPol(max_tries: u16) !Pol {
    return Pol.init(.{
        .max_tries = max_tries,
        .backoff = .{
            .base_ms = 10,
            .max_ms = 60,
            .mul = 2,
        },
        .retryable = retryable,
    });
}

test "stream run retries transient transport and parses frames" {
    const atts = [_]Attempt{
        .{
            .start_err = error.TransportTransient,
        },
        .{
            .chunks = &.{
                "text:he",
                "llo\nusage:3,5,8\nstop:done\n",
            },
        },
    };

    var tr = MockTr.init(atts[0..]);
    var waits = WaitLog{};
    const pol = try mkPol(3);

    var out = try run(
        std.testing.allocator,
        tr.asTransport(),
        reqStub(),
        pol,
        waits.asSleeper(),
    );
    defer out.deinit();

    try std.testing.expectEqual(@as(u16, 2), out.tries);
    try std.testing.expectEqual(@as(usize, 2), tr.start_ct);
    try std.testing.expectEqual(@as(usize, 1), waits.len);
    try std.testing.expectEqual(@as(u64, 10), waits.waits[0]);
    try std.testing.expectEqual(@as(usize, 3), out.evs.len);

    switch (out.evs[0]) {
        .text => |txt| try std.testing.expectEqualStrings("hello", txt),
        else => return error.TestUnexpectedResult,
    }
    switch (out.evs[1]) {
        .usage => |usage| {
            try std.testing.expectEqual(@as(u64, 3), usage.in_tok);
            try std.testing.expectEqual(@as(u64, 5), usage.out_tok);
            try std.testing.expectEqual(@as(u64, 8), usage.tot_tok);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (out.evs[2]) {
        .stop => |stop| try std.testing.expect(stop.reason == .done),
        else => return error.TestUnexpectedResult,
    }
}

test "stream run drops partial events from failed retry attempt" {
    const atts = [_]Attempt{
        .{
            .chunks = &.{"text:bad\n"},
            .fail_after = 1,
            .fail_err = error.TransportTransient,
        },
        .{
            .chunks = &.{"text:ok\nstop:done\n"},
        },
    };

    var tr = MockTr.init(atts[0..]);
    var waits = WaitLog{};
    const pol = try mkPol(3);

    var out = try run(
        std.testing.allocator,
        tr.asTransport(),
        reqStub(),
        pol,
        waits.asSleeper(),
    );
    defer out.deinit();

    try std.testing.expectEqual(@as(u16, 2), out.tries);
    try std.testing.expectEqual(@as(usize, 2), out.evs.len);
    try std.testing.expectEqual(@as(usize, 1), waits.len);

    switch (out.evs[0]) {
        .text => |txt| try std.testing.expectEqualStrings("ok", txt),
        else => return error.TestUnexpectedResult,
    }
    switch (out.evs[1]) {
        .stop => |stop| try std.testing.expect(stop.reason == .done),
        else => return error.TestUnexpectedResult,
    }
}

test "stream run does not retry parser failures" {
    const atts = [_]Attempt{
        .{
            .chunks = &.{"bad\n"},
        },
    };

    var tr = MockTr.init(atts[0..]);
    var waits = WaitLog{};
    const pol = try mkPol(3);

    try std.testing.expectError(
        error.BadFrame,
        run(
            std.testing.allocator,
            tr.asTransport(),
            reqStub(),
            pol,
            waits.asSleeper(),
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), tr.start_ct);
    try std.testing.expectEqual(@as(usize, 0), waits.len);
}

test "stream run stops at max tries for transient failures" {
    const atts = [_]Attempt{
        .{
            .start_err = error.TransportTransient,
        },
        .{
            .start_err = error.TransportTransient,
        },
    };

    var tr = MockTr.init(atts[0..]);
    var waits = WaitLog{};
    const pol = try mkPol(2);

    try std.testing.expectError(
        error.TransportTransient,
        run(
            std.testing.allocator,
            tr.asTransport(),
            reqStub(),
            pol,
            waits.asSleeper(),
        ),
    );
    try std.testing.expectEqual(@as(usize, 2), tr.start_ct);
    try std.testing.expectEqual(@as(usize, 1), waits.len);
    try std.testing.expectEqual(@as(u64, 10), waits.waits[0]);
}
