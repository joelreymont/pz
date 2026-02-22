const std = @import("std");

pub const Auth = union(enum) {
    oauth: []const u8, // bearer token
    api_key: []const u8, // x-api-key
};

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    auth: Auth,

    pub fn deinit(self: *Result) void {
        self.arena.deinit();
    }
};

const AuthEntry = struct {
    type: ?[]const u8 = null,
    access: ?[]const u8 = null,
    refresh: ?[]const u8 = null,
    key: ?[]const u8 = null,
};

const AuthFile = struct {
    anthropic: ?AuthEntry = null,
};

pub fn load(alloc: std.mem.Allocator) !Result {
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const ar = arena.allocator();

    const home = std.process.getEnvVarOwned(ar, "HOME") catch return error.AuthNotFound;
    const path = try std.fs.path.join(ar, &.{ home, ".pi", "agent", "auth.json" });

    const raw = std.fs.cwd().readFileAlloc(ar, path, 1024 * 1024) catch return error.AuthNotFound;

    const parsed = std.json.parseFromSlice(AuthFile, ar, raw, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return error.AuthNotFound;

    const entry = parsed.value.anthropic orelse return error.AuthNotFound;

    const AuthType = enum { oauth, api_key };
    const auth_map = std.StaticStringMap(AuthType).initComptime(.{
        .{ "oauth", .oauth },
        .{ "api_key", .api_key },
    });

    const typ = entry.type orelse return error.AuthNotFound;
    const resolved = auth_map.get(typ) orelse return error.AuthNotFound;
    switch (resolved) {
        .oauth => {
            const token = entry.access orelse return error.AuthNotFound;
            return .{ .arena = arena, .auth = .{ .oauth = token } };
        },
        .api_key => {
            const key = entry.key orelse return error.AuthNotFound;
            return .{ .arena = arena, .auth = .{ .api_key = key } };
        },
    }
}

test "load returns auth or AuthNotFound" {
    const res = load(std.testing.allocator);
    if (res) |*r| {
        // Auth file exists on this machine — verify it parsed
        var result = r.*;
        defer result.deinit();
        switch (result.auth) {
            .oauth => |t| try std.testing.expect(t.len > 0),
            .api_key => |k| try std.testing.expect(k.len > 0),
        }
    } else |err| {
        try std.testing.expect(err == error.AuthNotFound);
    }
}
