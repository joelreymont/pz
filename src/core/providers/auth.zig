const std = @import("std");

pub const Auth = union(enum) {
    oauth: OAuth,
    api_key: []const u8, // x-api-key
};

pub const OAuth = struct {
    access: []const u8,
    refresh: []const u8,
    expires: i64, // ms since epoch
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
    expires: ?i64 = null,
    key: ?[]const u8 = null,
};

const client_id = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
const token_url_host = "console.anthropic.com";
const token_url_path = "/v1/oauth/token";
const anthropic_oauth_env = "ANTHROPIC_OAUTH_TOKEN";
const anthropic_api_key_env = "ANTHROPIC_API_KEY";
const oauth_no_expiry: i64 = std.math.maxInt(i64);

const AuthFile = struct {
    anthropic: ?AuthEntry = null,
    openai: ?AuthEntry = null,
    google: ?AuthEntry = null,
};

/// Auth file search paths (tried in order).
const auth_dirs = [_][2][]const u8{
    .{ ".pi", "agent" },
    .{ ".agents", "" },
};

fn findAuthFile(ar: std.mem.Allocator, home: []const u8) ![]const u8 {
    for (auth_dirs) |d| {
        const path = if (d[1].len > 0)
            try std.fs.path.join(ar, &.{ home, d[0], d[1], "auth.json" })
        else
            try std.fs.path.join(ar, &.{ home, d[0], "auth.json" });
        if (std.fs.cwd().access(path, .{})) |_| return path else |_| {}
    }
    return error.AuthNotFound;
}

/// Primary auth dir (for writes). Uses ~/.pi/agent/ by default.
fn primaryAuthDir(ar: std.mem.Allocator, home: []const u8) ![]const u8 {
    return try std.fs.path.join(ar, &.{ home, ".pi", "agent" });
}

pub fn load(alloc: std.mem.Allocator) !Result {
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const ar = arena.allocator();

    if (authFromEnv(.{
        .oauth = readEnv(ar, anthropic_oauth_env),
        .api_key = readEnv(ar, anthropic_api_key_env),
    })) |auth| {
        return .{ .arena = arena, .auth = auth };
    }

    const home = std.process.getEnvVarOwned(ar, "HOME") catch return error.AuthNotFound;
    return .{
        .arena = arena,
        .auth = try loadFileAuth(ar, home),
    };
}

const EnvAuth = struct {
    oauth: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
};

fn readEnv(ar: std.mem.Allocator, key: []const u8) ?[]const u8 {
    return std.process.getEnvVarOwned(ar, key) catch null;
}

fn authFromEnv(env: EnvAuth) ?Auth {
    if (env.oauth) |token| {
        if (token.len > 0) return .{ .oauth = .{
            .access = token,
            .refresh = "",
            .expires = oauth_no_expiry,
        } };
    }
    if (env.api_key) |key| {
        if (key.len > 0) return .{ .api_key = key };
    }
    return null;
}

fn loadFileAuth(alloc: std.mem.Allocator, home: []const u8) !Auth {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const ar = arena.allocator();

    const path = findAuthFile(ar, home) catch return error.AuthNotFound;
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
    return switch (resolved) {
        .oauth => blk: {
            const access = entry.access orelse return error.AuthNotFound;
            const refresh = entry.refresh orelse return error.AuthNotFound;
            const access_duped = try alloc.dupe(u8, access);
            errdefer alloc.free(access_duped);
            const refresh_duped = try alloc.dupe(u8, refresh);
            errdefer alloc.free(refresh_duped);
            break :blk .{ .oauth = .{
                .access = access_duped,
                .refresh = refresh_duped,
                .expires = entry.expires orelse 0,
            } };
        },
        .api_key => blk: {
            const key = entry.key orelse return error.AuthNotFound;
            break :blk .{ .api_key = try alloc.dupe(u8, key) };
        },
    };
}

/// Refresh an expired OAuth token. Returns new OAuth credentials and saves to disk.
pub fn refreshOAuth(alloc: std.mem.Allocator, old: OAuth) !OAuth {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const ar = arena.allocator();

    // Build JSON body
    const body = try std.fmt.allocPrint(ar,
        \\{{"grant_type":"refresh_token","client_id":"{s}","refresh_token":"{s}"}}
    , .{ client_id, old.refresh });

    // POST to token endpoint
    var http = std.http.Client{ .allocator = ar };
    defer http.deinit();

    const uri = std.Uri{
        .scheme = "https",
        .host = .{ .raw = token_url_host },
        .path = .{ .raw = token_url_path },
    };

    var send_buf: [1024]u8 = undefined;
    var req = try http.request(.POST, uri, .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
        .keep_alive = false,
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = body.len };
    var bw = try req.sendBodyUnflushed(&send_buf);
    try bw.writer.writeAll(body);
    try bw.end();
    try req.connection.?.flush();

    var redir_buf: [0]u8 = .{};
    var resp = try req.receiveHead(&redir_buf);

    if (resp.head.status != .ok) return error.RefreshFailed;

    var transfer_buf: [16384]u8 = undefined;
    var decomp: std.http.Decompress = undefined;
    var decomp_buf: [std.compress.flate.max_window_len]u8 = undefined;
    const rdr = resp.readerDecompressing(&transfer_buf, &decomp, &decomp_buf);
    const resp_body = try rdr.allocRemaining(ar, .limited(65536));

    const parsed = std.json.parseFromSlice(struct {
        access_token: []const u8,
        refresh_token: []const u8,
        expires_in: i64,
    }, ar, resp_body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return error.RefreshFailed;

    const now_ms = std.time.milliTimestamp();
    // 5 minute buffer before expiry
    const expires = now_ms + parsed.value.expires_in * 1000 - 5 * 60 * 1000;

    // Copy to caller's allocator
    const new_access = try alloc.dupe(u8, parsed.value.access_token);
    errdefer alloc.free(new_access);
    const new_refresh = try alloc.dupe(u8, parsed.value.refresh_token);
    errdefer alloc.free(new_refresh);

    const new_oauth = OAuth{
        .access = new_access,
        .refresh = new_refresh,
        .expires = expires,
    };

    // Save to disk (non-fatal: in-memory token is still valid)
    saveOAuth(ar, new_oauth) catch |err| {
        std.debug.print("warning: failed to persist refreshed token: {s}\n", .{@errorName(err)});
    };

    return new_oauth;
}

fn saveOAuth(ar: std.mem.Allocator, oauth: OAuth) !void {
    const home = try std.process.getEnvVarOwned(ar, "HOME");
    const dir_path = try primaryAuthDir(ar, home);
    try std.fs.cwd().makePath(dir_path);
    const path = try std.fs.path.join(ar, &.{ dir_path, "auth.json" });

    var auth_file: AuthFile = .{};
    // Load existing
    if (std.fs.cwd().readFileAlloc(ar, path, 1024 * 1024)) |raw| {
        if (std.json.parseFromSlice(AuthFile, ar, raw, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        })) |parsed| {
            auth_file = parsed.value;
        } else |_| {}
    } else |_| {}

    auth_file.anthropic = .{
        .type = "oauth",
        .access = oauth.access,
        .refresh = oauth.refresh,
        .expires = oauth.expires,
    };

    const out = try std.json.Stringify.valueAlloc(ar, auth_file, .{ .whitespace = .indent_2 });
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(out);
}

pub const Provider = enum { anthropic, openai, google };
const provider_names = [_][]const u8{ "anthropic", "openai", "google" };

pub fn providerName(p: Provider) []const u8 {
    return provider_names[@intFromEnum(p)];
}

/// List providers that have credentials stored (merges all auth files).
pub fn listLoggedIn(alloc: std.mem.Allocator) ![]Provider {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const ar = arena.allocator();

    const home = std.process.getEnvVarOwned(ar, "HOME") catch return try alloc.alloc(Provider, 0);

    var merged: AuthFile = .{};
    for (auth_dirs) |d| {
        const path = if (d[1].len > 0)
            try std.fs.path.join(ar, &.{ home, d[0], d[1], "auth.json" })
        else
            try std.fs.path.join(ar, &.{ home, d[0], "auth.json" });
        const raw = std.fs.cwd().readFileAlloc(ar, path, 1024 * 1024) catch continue;
        const parsed = std.json.parseFromSlice(AuthFile, ar, raw, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch continue;
        if (merged.anthropic == null) merged.anthropic = parsed.value.anthropic;
        if (merged.openai == null) merged.openai = parsed.value.openai;
        if (merged.google == null) merged.google = parsed.value.google;
    }

    var result = std.ArrayList(Provider).empty;
    errdefer result.deinit(alloc);
    if (merged.anthropic != null) try result.append(alloc, .anthropic);
    if (merged.openai != null) try result.append(alloc, .openai);
    if (merged.google != null) try result.append(alloc, .google);
    return try result.toOwnedSlice(alloc);
}

/// Remove credentials for a provider from all auth files.
pub fn logout(alloc: std.mem.Allocator, provider: Provider) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const ar = arena.allocator();

    const home = try std.process.getEnvVarOwned(ar, "HOME");

    for (auth_dirs) |d| {
        const path = if (d[1].len > 0)
            try std.fs.path.join(ar, &.{ home, d[0], d[1], "auth.json" })
        else
            try std.fs.path.join(ar, &.{ home, d[0], "auth.json" });
        const raw = std.fs.cwd().readFileAlloc(ar, path, 1024 * 1024) catch continue;
        var parsed = std.json.parseFromSlice(AuthFile, ar, raw, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch continue;

        switch (provider) {
            .anthropic => parsed.value.anthropic = null,
            .openai => parsed.value.openai = null,
            .google => parsed.value.google = null,
        }

        const out = try std.json.Stringify.valueAlloc(ar, parsed.value, .{ .whitespace = .indent_2 });
        const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(out);
    }
}

/// Save API key for a provider. Writes to primary auth dir (~/.pi/agent/).
pub fn saveApiKey(alloc: std.mem.Allocator, provider: Provider, key: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const ar = arena.allocator();

    const home = try std.process.getEnvVarOwned(ar, "HOME");
    const dir_path = try primaryAuthDir(ar, home);
    try std.fs.cwd().makePath(dir_path);
    const path = try std.fs.path.join(ar, &.{ dir_path, "auth.json" });

    var auth_file: AuthFile = .{};
    // Try loading existing
    if (std.fs.cwd().readFileAlloc(ar, path, 1024 * 1024)) |raw| {
        if (std.json.parseFromSlice(AuthFile, ar, raw, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        })) |parsed| {
            auth_file = parsed.value;
        } else |_| {}
    } else |_| {}

    const entry = AuthEntry{ .type = "api_key", .key = key };
    switch (provider) {
        .anthropic => auth_file.anthropic = entry,
        .openai => auth_file.openai = entry,
        .google => auth_file.google = entry,
    }

    const out = try std.json.Stringify.valueAlloc(ar, auth_file, .{ .whitespace = .indent_2 });
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(out);
}

test "authFromEnv prefers oauth token over api key" {
    const auth = authFromEnv(.{
        .oauth = "sk-ant-oat-123",
        .api_key = "sk-ant-123",
    }) orelse return error.TestUnexpectedResult;
    switch (auth) {
        .oauth => |oauth| {
            try std.testing.expectEqualStrings("sk-ant-oat-123", oauth.access);
            try std.testing.expectEqualStrings("", oauth.refresh);
            try std.testing.expectEqual(@as(i64, oauth_no_expiry), oauth.expires);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "authFromEnv uses api key when oauth token is missing" {
    const auth = authFromEnv(.{
        .oauth = null,
        .api_key = "sk-ant-123",
    }) orelse return error.TestUnexpectedResult;
    switch (auth) {
        .api_key => |key| try std.testing.expectEqualStrings("sk-ant-123", key),
        else => return error.TestUnexpectedResult,
    }
}

test "loadFileAuth parses anthropic api_key entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(".pi/agent");
    try tmp.dir.writeFile(.{
        .sub_path = ".pi/agent/auth.json",
        .data =
        \\{
        \\  "anthropic": {
        \\    "type": "api_key",
        \\    "key": "sk-ant-file"
        \\  }
        \\}
        ,
    });

    const home = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(home);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const auth = try loadFileAuth(arena.allocator(), home);
    switch (auth) {
        .api_key => |key| try std.testing.expectEqualStrings("sk-ant-file", key),
        else => return error.TestUnexpectedResult,
    }
}

test "loadFileAuth returns AuthNotFound when file is missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(home);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const res = loadFileAuth(arena.allocator(), home);
    try std.testing.expectError(error.AuthNotFound, res);
}
