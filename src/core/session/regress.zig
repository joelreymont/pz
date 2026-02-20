const std = @import("std");
const writer = @import("writer.zig");
const reader = @import("reader.zig");
const compact = @import("compact.zig");
const retry_state = @import("retry_state.zig");

test "session persistence regression covers compacted replay and retry restore" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var wr = try writer.Writer.init(std.testing.allocator, tmp.dir, .{
        .flush = .{ .always = {} },
    });

    try wr.append("sid-1", .{
        .at_ms = 1,
        .data = .{ .prompt = .{ .text = "ship" } },
    });
    try wr.append("sid-1", .{
        .at_ms = 2,
        .data = .{ .noop = {} },
    });
    try wr.append("sid-1", .{
        .at_ms = 3,
        .data = .{ .tool_result = .{
            .id = "c1",
            .out = "ok",
            .is_err = false,
        } },
    });

    try retry_state.save(std.testing.allocator, tmp.dir, "sid-1", .{
        .tries_done = 2,
        .fail_ct = 1,
        .next_wait_ms = 100,
        .last_err = .transient,
    });

    _ = try compact.run(std.testing.allocator, tmp.dir, "sid-1", 999);

    var rdr = try reader.ReplayReader.init(std.testing.allocator, tmp.dir, "sid-1", .{});
    defer rdr.deinit();

    const ev0 = (try rdr.next()) orelse return error.TestUnexpectedResult;
    switch (ev0.data) {
        .prompt => |prompt| try std.testing.expectEqualStrings("ship", prompt.text),
        else => return error.TestUnexpectedResult,
    }

    const ev1 = (try rdr.next()) orelse return error.TestUnexpectedResult;
    switch (ev1.data) {
        .tool_result => |tr| {
            try std.testing.expectEqualStrings("c1", tr.id);
            try std.testing.expectEqualStrings("ok", tr.out);
            try std.testing.expect(!tr.is_err);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect((try rdr.next()) == null);

    const rs = (try retry_state.load(std.testing.allocator, tmp.dir, "sid-1")) orelse {
        return error.TestUnexpectedResult;
    };
    try std.testing.expectEqual(@as(u16, 2), rs.tries_done);
    try std.testing.expectEqual(@as(u16, 1), rs.fail_ct);
    try std.testing.expectEqual(@as(u64, 100), rs.next_wait_ms);
    try std.testing.expect(rs.last_err == .transient);
}
