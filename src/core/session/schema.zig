const std = @import("std");

pub const version_current: u16 = 1;

pub const Event = struct {
    version: u16 = version_current,
    at_ms: i64 = 0,
    data: Data = .{ .noop = {} },

    pub const Data = union(Tag) {
        noop: void,
        prompt: Text,
        text: Text,
        thinking: Text,
        tool_call: ToolCall,
        tool_result: ToolResult,
        usage: Usage,
        stop: Stop,
        err: Text,
    };

    pub const Tag = enum {
        noop,
        prompt,
        text,
        thinking,
        tool_call,
        tool_result,
        usage,
        stop,
        err,
    };

    pub const Text = struct {
        text: []const u8,
    };

    pub const ToolCall = struct {
        id: []const u8,
        name: []const u8,
        args: []const u8,
    };

    pub const ToolResult = struct {
        id: []const u8,
        out: []const u8,
        is_err: bool = false,
    };

    pub const Usage = struct {
        in_tok: u64 = 0,
        out_tok: u64 = 0,
        tot_tok: u64 = 0,
        cache_read: u64 = 0,
        cache_write: u64 = 0,
    };

    pub const Stop = struct {
        reason: StopReason,
    };

    pub const StopReason = enum {
        done,
        max_out,
        tool,
        canceled,
        err,
    };
};

pub const DecodeError = std.json.ParseError(std.json.Scanner) || error{
    UnsupportedVersion,
};

pub fn encodeAlloc(alloc: std.mem.Allocator, ev: Event) error{OutOfMemory}![]u8 {
    var out = ev;
    out.version = version_current;
    return std.json.Stringify.valueAlloc(alloc, out, .{});
}

pub fn decodeSlice(alloc: std.mem.Allocator, raw: []const u8) DecodeError!std.json.Parsed(Event) {
    var parsed = try std.json.parseFromSlice(Event, alloc, raw, .{
        .allocate = .alloc_always,
    });
    errdefer parsed.deinit();

    if (parsed.value.version != version_current) return error.UnsupportedVersion;

    return parsed;
}

test "session event json roundtrip" {
    const ev = Event{
        .version = 99,
        .at_ms = 42,
        .data = .{ .tool_result = .{
            .id = "call-1",
            .out = "{\"ok\":true}",
            .is_err = false,
        } },
    };

    const raw = try encodeAlloc(std.testing.allocator, ev);
    defer std.testing.allocator.free(raw);

    var parsed = try decodeSlice(std.testing.allocator, raw);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(u16, version_current), parsed.value.version);
    try std.testing.expectEqual(@as(i64, 42), parsed.value.at_ms);

    switch (parsed.value.data) {
        .tool_result => |out| {
            try std.testing.expectEqualStrings("call-1", out.id);
            try std.testing.expectEqualStrings("{\"ok\":true}", out.out);
            try std.testing.expect(!out.is_err);
        },
        else => try std.testing.expect(false),
    }
}

test "session event json rejects wrong version" {
    const raw = "{\"version\":7,\"at_ms\":1,\"data\":{\"noop\":{}}}";
    try std.testing.expectError(error.UnsupportedVersion, decodeSlice(std.testing.allocator, raw));
}
