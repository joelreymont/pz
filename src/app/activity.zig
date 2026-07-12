//! Privacy-minimized runtime activity hooks.
const std = @import("std");

pub const Event = union(enum) {
    session_start: Session,
    prompt: Prompt,
    activity: Tool,
    stop: Session,

    pub const Session = struct {
        session_id: []const u8,
        source: ?[]const u8 = null,
    };

    pub const Prompt = struct {
        session_id: []const u8,
        prompt_chars: usize,
        source: ?[]const u8 = null,
    };

    pub const Tool = struct {
        session_id: []const u8,
        tool_name: []const u8,
        source: ?[]const u8 = null,
    };
};

pub const ActivitySink = struct {
    ctx: *anyopaque,
    emit_fn: *const fn (*anyopaque, Event) void,

    pub fn emit(self: *ActivitySink, event: Event) void {
        self.emit_fn(self.ctx, event);
    }
};

pub const ActivityHooks = struct {
    sink: ?*ActivitySink = null,
};

pub const Bridge = struct {
    sink: ActivitySink = undefined,
    alloc: std.mem.Allocator,
    io: std.Io,
    path: []const u8,

    pub fn init(alloc: std.mem.Allocator, io: std.Io, home: []const u8) !Bridge {
        return .{
            .alloc = alloc,
            .io = io,
            .path = try std.fs.path.join(alloc, &.{ home, ".local", "bin", "vibemon-hook" }),
        };
    }

    pub fn activitySink(self: *Bridge) *ActivitySink {
        self.sink = .{ .ctx = self, .emit_fn = &emitOpaque };
        return &self.sink;
    }

    pub fn deinit(self: *Bridge) void {
        self.alloc.free(self.path);
        self.* = undefined;
    }

    fn emitOpaque(ctx: *anyopaque, event: Event) void {
        const self: *Bridge = @ptrCast(@alignCast(ctx));
        self.send(event) catch |err| {
            std.log.debug("activity hook skipped: {s}", .{@errorName(err)});
        };
    }

    fn send(self: *Bridge, event: Event) !void {
        std.Io.Dir.accessAbsolute(self.io, self.path, .{}) catch return;

        const event_name = @tagName(event);
        const payload = try encodeAlloc(self.alloc, event);
        defer self.alloc.free(payload);

        const argv = [_][]const u8{ self.path, "pz", event_name };
        var child = try std.process.spawn(self.io, .{
            .argv = argv[0..],
            .stdin = .pipe,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        var stdin = child.stdin orelse {
            _ = child.wait(self.io) catch return;
            return;
        };
        child.stdin = null;
        stdin.writeStreamingAll(self.io, payload) catch {
            stdin.close(self.io);
            _ = child.wait(self.io) catch return;
            return;
        };
        stdin.writeStreamingAll(self.io, "\n") catch |write_err| {
            stdin.close(self.io);
            _ = child.wait(self.io) catch return write_err;
            return write_err;
        };
        stdin.close(self.io);
        _ = child.wait(self.io) catch return;
    }
};

pub fn encodeAlloc(alloc: std.mem.Allocator, event: Event) ![]u8 {
    return switch (event) {
        .session_start => |payload| std.json.Stringify.valueAlloc(alloc, payload, .{ .emit_null_optional_fields = false }),
        .prompt => |payload| std.json.Stringify.valueAlloc(alloc, payload, .{ .emit_null_optional_fields = false }),
        .activity => |payload| std.json.Stringify.valueAlloc(alloc, payload, .{ .emit_null_optional_fields = false }),
        .stop => |payload| std.json.Stringify.valueAlloc(alloc, payload, .{ .emit_null_optional_fields = false }),
    };
}

test "activity JSON exposes only the event allowlist" {
    const prompt = try encodeAlloc(std.testing.allocator, .{ .prompt = .{
        .session_id = "sid-1",
        .prompt_chars = 31,
    } });
    defer std.testing.allocator.free(prompt);
    try std.testing.expectEqualStrings("{\"session_id\":\"sid-1\",\"prompt_chars\":31}", prompt);

    const tool = try encodeAlloc(std.testing.allocator, .{ .activity = .{
        .session_id = "sid-1",
        .tool_name = "bash",
    } });
    defer std.testing.allocator.free(tool);
    try std.testing.expectEqualStrings("{\"session_id\":\"sid-1\",\"tool_name\":\"bash\"}", tool);

    const sensitive = [_][]const u8{ "deploy production", "rm -rf", "tool output", "secret error", "sk-live-key" };
    for (sensitive) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, prompt, needle) == null);
        try std.testing.expect(std.mem.indexOf(u8, tool, needle) == null);
    }
}
