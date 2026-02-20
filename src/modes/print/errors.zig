const std = @import("std");
const core = @import("../../core/mod.zig");

pub const Err = error{
    PromptWrite,
    ProviderStart,
    StreamRead,
    OutputFormat,
    EventWrite,
    OutputFlush,
    StopMaxOut,
    StopTool,
    StopCanceled,
    StopErr,
};

pub const Exit = struct {
    code: u8,
    msg: []const u8,
};

pub fn map(err: Err) Exit {
    return switch (err) {
        error.PromptWrite => .{ .code = 10, .msg = "print: failed to persist prompt" },
        error.ProviderStart => .{ .code = 11, .msg = "print: provider failed to start stream" },
        error.StreamRead => .{ .code = 12, .msg = "print: provider stream read failed" },
        error.OutputFormat => .{ .code = 13, .msg = "print: failed to format output event" },
        error.EventWrite => .{ .code = 14, .msg = "print: failed to persist stream event" },
        error.OutputFlush => .{ .code = 15, .msg = "print: failed to flush formatted output" },
        error.StopMaxOut => .{ .code = 16, .msg = "print: provider stopped at max output" },
        error.StopTool => .{ .code = 17, .msg = "print: provider stopped for tool handoff" },
        error.StopCanceled => .{ .code = 18, .msg = "print: provider stream canceled" },
        error.StopErr => .{ .code = 19, .msg = "print: provider reported terminal error" },
    };
}

pub fn mapStop(reason: core.providers.StopReason) ?Err {
    return switch (reason) {
        .done => null,
        .max_out => error.StopMaxOut,
        .tool => error.StopTool,
        .canceled => error.StopCanceled,
        .err => error.StopErr,
    };
}

pub fn mergeStop(curr: ?core.providers.StopReason, next: core.providers.StopReason) core.providers.StopReason {
    if (curr) |prev| {
        if (stopRank(prev) >= stopRank(next)) return prev;
    }
    return next;
}

fn stopRank(reason: core.providers.StopReason) u8 {
    return switch (reason) {
        .done => 0,
        .tool => 1,
        .max_out => 2,
        .canceled => 3,
        .err => 4,
    };
}

test "map provides stable exit codes and messages for each typed print error" {
    const Case = struct {
        err: Err,
        code: u8,
        msg: []const u8,
    };

    const cases = [_]Case{
        .{ .err = error.PromptWrite, .code = 10, .msg = "print: failed to persist prompt" },
        .{ .err = error.ProviderStart, .code = 11, .msg = "print: provider failed to start stream" },
        .{ .err = error.StreamRead, .code = 12, .msg = "print: provider stream read failed" },
        .{ .err = error.OutputFormat, .code = 13, .msg = "print: failed to format output event" },
        .{ .err = error.EventWrite, .code = 14, .msg = "print: failed to persist stream event" },
        .{ .err = error.OutputFlush, .code = 15, .msg = "print: failed to flush formatted output" },
        .{ .err = error.StopMaxOut, .code = 16, .msg = "print: provider stopped at max output" },
        .{ .err = error.StopTool, .code = 17, .msg = "print: provider stopped for tool handoff" },
        .{ .err = error.StopCanceled, .code = 18, .msg = "print: provider stream canceled" },
        .{ .err = error.StopErr, .code = 19, .msg = "print: provider reported terminal error" },
    };

    for (cases, 0..) |case, i| {
        const got = map(case.err);
        try std.testing.expectEqual(case.code, got.code);
        try std.testing.expectEqualStrings(case.msg, got.msg);

        var j: usize = i + 1;
        while (j < cases.len) : (j += 1) {
            try std.testing.expect(cases[j].code != got.code);
        }
    }
}

test "mapStop maps stop reasons to typed print errors" {
    try std.testing.expect(mapStop(.done) == null);
    try std.testing.expectEqual(error.StopMaxOut, mapStop(.max_out).?);
    try std.testing.expectEqual(error.StopTool, mapStop(.tool).?);
    try std.testing.expectEqual(error.StopCanceled, mapStop(.canceled).?);
    try std.testing.expectEqual(error.StopErr, mapStop(.err).?);
}

test "mergeStop chooses deterministic highest priority stop reason" {
    try std.testing.expectEqual(core.providers.StopReason.done, mergeStop(null, .done));
    try std.testing.expectEqual(core.providers.StopReason.max_out, mergeStop(.done, .max_out));
    try std.testing.expectEqual(core.providers.StopReason.max_out, mergeStop(.max_out, .done));
    try std.testing.expectEqual(core.providers.StopReason.err, mergeStop(.tool, .err));
    try std.testing.expectEqual(core.providers.StopReason.canceled, mergeStop(.canceled, .max_out));
}
