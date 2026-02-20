const std = @import("std");

pub const Err = error{
    OutOfMemory,
    TransportTransient,
    TransportFatal,
    BadFrame,
    UnknownTag,
    InvalidUsage,
    UnknownStop,
    MissingStop,
};

pub const Class = enum {
    retryable_transport,
    fatal_transport,
    parse,
};

pub fn class(err: Err) Class {
    return switch (err) {
        error.TransportTransient => .retryable_transport,
        error.TransportFatal => .fatal_transport,
        error.OutOfMemory,
        error.BadFrame,
        error.UnknownTag,
        error.InvalidUsage,
        error.UnknownStop,
        error.MissingStop,
        => .parse,
    };
}

pub fn retryable(err: Err) bool {
    return err == error.TransportTransient;
}

pub fn mapAlloc(_: std.mem.Allocator.Error) Err {
    return error.OutOfMemory;
}

pub const Adapter = struct {
    ctx: *anyopaque,
    vt: *const Vt,

    pub const Vt = struct {
        map: *const fn (ctx: *anyopaque, err: anyerror) Err,
    };

    pub fn from(
        comptime T: type,
        ctx: *T,
        comptime map_fn: fn (ctx: *T, err: anyerror) Err,
    ) Adapter {
        const Wrap = struct {
            fn map(raw: *anyopaque, err: anyerror) Err {
                const typed: *T = @ptrCast(@alignCast(raw));
                return map_fn(typed, err);
            }

            const vt = Vt{
                .map = @This().map,
            };
        };

        return .{
            .ctx = ctx,
            .vt = &Wrap.vt,
        };
    }

    pub fn map(self: Adapter, err: anyerror) Err {
        return self.vt.map(self.ctx, err);
    }
};

const MapCtx = struct {
    calls: usize = 0,
};

fn mapRaw(ctx: *MapCtx, err: anyerror) Err {
    ctx.calls += 1;

    if (err == error.Timeout or err == error.WireBreak) return error.TransportTransient;
    if (err == error.Closed) return error.TransportFatal;
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return error.TransportFatal;
}

test "taxonomy class and retry classification" {
    try std.testing.expect(class(error.TransportTransient) == .retryable_transport);
    try std.testing.expect(class(error.TransportFatal) == .fatal_transport);
    try std.testing.expect(class(error.BadFrame) == .parse);

    try std.testing.expect(retryable(error.TransportTransient));
    try std.testing.expect(!retryable(error.TransportFatal));
    try std.testing.expect(!retryable(error.BadFrame));
}

test "adapter maps provider errors into canonical taxonomy" {
    var ctx = MapCtx{};
    const ad = Adapter.from(MapCtx, &ctx, mapRaw);

    try std.testing.expectEqual(error.TransportTransient, ad.map(error.Timeout));
    try std.testing.expectEqual(error.TransportTransient, ad.map(error.WireBreak));
    try std.testing.expectEqual(error.TransportFatal, ad.map(error.Closed));
    try std.testing.expectEqual(error.OutOfMemory, ad.map(error.OutOfMemory));
    try std.testing.expectEqual(@as(usize, 4), ctx.calls);
}
