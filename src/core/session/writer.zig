const std = @import("std");
const schema = @import("schema.zig");
const sid_path = @import("path.zig");

pub const Event = schema.Event;

pub const FlushPolicy = union(enum) {
    always: void,
    every_n: u32,
};

pub const Opts = struct {
    flush: FlushPolicy = .{ .always = {} },
};

pub const Writer = struct {
    alloc: std.mem.Allocator,
    dir: std.fs.Dir,
    flush: FlushPolicy,
    pending: u32 = 0,

    pub fn init(alloc: std.mem.Allocator, dir: std.fs.Dir, opts: Opts) !Writer {
        switch (opts.flush) {
            .always => {},
            .every_n => |n| {
                if (n == 0) return error.InvalidFlushEvery;
            },
        }

        return .{
            .alloc = alloc,
            .dir = dir,
            .flush = opts.flush,
        };
    }

    pub fn append(self: *Writer, sid: []const u8, ev: Event) !void {
        const path = try sid_path.sidJsonlAlloc(self.alloc, sid);
        defer self.alloc.free(path);

        const raw = try schema.encodeAlloc(self.alloc, ev);
        defer self.alloc.free(raw);

        var file = try self.dir.createFile(path, .{
            .read = false,
            .truncate = false,
        });
        defer file.close();
        try file.seekFromEnd(0);
        try file.writeAll(raw);
        try file.writeAll("\n");

        switch (self.flush) {
            .always => {
                try file.sync();
            },
            .every_n => |n| {
                self.pending += 1;
                if (self.pending >= n) {
                    try file.sync();
                    self.pending = 0;
                }
            },
        }
    }
};

test "jsonl append preserves event order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var writer = try Writer.init(std.testing.allocator, tmp.dir, .{
        .flush = .{ .always = {} },
    });

    try writer.append("s1", .{
        .at_ms = 1,
        .data = .{ .prompt = .{ .text = "alpha" } },
    });
    try writer.append("s1", .{
        .at_ms = 2,
        .data = .{ .text = .{ .text = "beta" } },
    });
    try writer.append("s1", .{
        .at_ms = 3,
        .data = .{ .err = .{ .text = "gamma" } },
    });

    const raw = try tmp.dir.readFileAlloc(std.testing.allocator, "s1.jsonl", 4096);
    defer std.testing.allocator.free(raw);

    var it = std.mem.splitScalar(u8, raw, '\n');
    var idx: usize = 0;
    while (it.next()) |line| {
        if (line.len == 0) continue;
        var parsed = try schema.decodeSlice(std.testing.allocator, line);
        defer parsed.deinit();

        try std.testing.expectEqual(@as(u16, schema.version_current), parsed.value.version);
        switch (idx) {
            0 => {
                try std.testing.expectEqual(@as(i64, 1), parsed.value.at_ms);
                switch (parsed.value.data) {
                    .prompt => |v| try std.testing.expectEqualStrings("alpha", v.text),
                    else => try std.testing.expect(false),
                }
            },
            1 => {
                try std.testing.expectEqual(@as(i64, 2), parsed.value.at_ms);
                switch (parsed.value.data) {
                    .text => |v| try std.testing.expectEqualStrings("beta", v.text),
                    else => try std.testing.expect(false),
                }
            },
            2 => {
                try std.testing.expectEqual(@as(i64, 3), parsed.value.at_ms);
                switch (parsed.value.data) {
                    .err => |v| try std.testing.expectEqualStrings("gamma", v.text),
                    else => try std.testing.expect(false),
                }
            },
            else => return error.TestUnexpectedResult,
        }
        idx += 1;
    }

    try std.testing.expectEqual(@as(usize, 3), idx);
}

test "writer rejects invalid flush policy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expectError(
        error.InvalidFlushEvery,
        Writer.init(std.testing.allocator, tmp.dir, .{
            .flush = .{ .every_n = 0 },
        }),
    );
}

test "writer rejects invalid session id" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var writer = try Writer.init(std.testing.allocator, tmp.dir, .{
        .flush = .{ .every_n = 2 },
    });

    try std.testing.expectError(error.InvalidSessionId, writer.append("", .{}));
    try std.testing.expectError(error.InvalidSessionId, writer.append("a/b", .{}));
}
