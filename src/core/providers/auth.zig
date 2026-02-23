const std = @import("std");
const builtin = @import("builtin");
const oauth_callback = @import("oauth_callback.zig");

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

pub const Provider = enum { anthropic, openai, google };
const provider_names = [_][]const u8{ "anthropic", "openai", "google" };

pub fn providerName(p: Provider) []const u8 {
    return provider_names[@intFromEnum(p)];
}

const OAuthTokenBody = enum {
    json_with_state,
    form_no_state,
};

const OAuthParam = struct {
    key: []const u8,
    value: []const u8,
};

const OAuthSpec = struct {
    provider: Provider,
    client_id: []const u8,
    authorize_url: []const u8,
    token_host: []const u8,
    token_path: []const u8,
    default_redirect_uri: []const u8,
    scopes: []const u8,
    local_callback_path: []const u8,
    start_action: []const u8,
    complete_action: []const u8,
    api_key_prefix: ?[]const u8 = null,
    token_body: OAuthTokenBody,
    extra_authorize: []const OAuthParam = &.{},
};

const oauth_no_expiry: i64 = std.math.maxInt(i64);
const anthropic_oauth_env = "ANTHROPIC_OAUTH_TOKEN";
const anthropic_api_key_env = "ANTHROPIC_API_KEY";
const openai_api_key_env = "OPENAI_API_KEY";

const openai_oauth_extra_authorize = [_]OAuthParam{
    .{ .key = "id_token_add_organizations", .value = "true" },
    .{ .key = "codex_cli_simplified_flow", .value = "true" },
    .{ .key = "originator", .value = "pz" },
};

const anthropic_spec = OAuthSpec{
    .provider = .anthropic,
    .client_id = "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
    .authorize_url = "https://claude.ai/oauth/authorize",
    .token_host = "console.anthropic.com",
    .token_path = "/v1/oauth/token",
    .default_redirect_uri = "https://console.anthropic.com/oauth/code/callback",
    .scopes = "org:create_api_key user:profile user:inference",
    .local_callback_path = "/callback",
    .start_action = "start anthropic oauth",
    .complete_action = "complete anthropic oauth",
    .api_key_prefix = "sk-ant-",
    .token_body = .json_with_state,
    .extra_authorize = &.{.{ .key = "code", .value = "true" }},
};

const openai_spec = OAuthSpec{
    .provider = .openai,
    .client_id = "app_EMoamEEZ73f0CkXaXp7hrann",
    .authorize_url = "https://auth.openai.com/oauth/authorize",
    .token_host = "auth.openai.com",
    .token_path = "/oauth/token",
    .default_redirect_uri = "http://127.0.0.1:1455/auth/callback",
    .scopes = "openid profile email offline_access",
    .local_callback_path = "/auth/callback",
    .start_action = "start openai oauth",
    .complete_action = "complete openai oauth",
    .api_key_prefix = "sk-",
    .token_body = .form_no_state,
    .extra_authorize = openai_oauth_extra_authorize[0..],
};

fn oauthSpec(provider: Provider) ?*const OAuthSpec {
    return switch (provider) {
        .anthropic => &anthropic_spec,
        .openai => &openai_spec,
        .google => null,
    };
}

pub const OAuthLoginInfo = struct {
    callback_path: []const u8,
    start_action: []const u8,
    complete_action: []const u8,
};

pub fn oauthLoginInfo(provider: Provider) ?OAuthLoginInfo {
    const spec = oauthSpec(provider) orelse return null;
    return .{
        .callback_path = spec.local_callback_path,
        .start_action = spec.start_action,
        .complete_action = spec.complete_action,
    };
}

pub fn oauthCapable(provider: Provider) bool {
    return oauthSpec(provider) != null;
}

pub fn looksLikeApiKey(provider: Provider, key: []const u8) bool {
    const prefix = switch (provider) {
        .anthropic => anthropic_spec.api_key_prefix,
        .openai => openai_spec.api_key_prefix,
        .google => null,
    };
    if (prefix) |p| return std.mem.startsWith(u8, key, p);
    return key.len > 0;
}

pub const OAuthStart = struct {
    url: []u8,
    verifier: []u8,

    pub fn deinit(self: *OAuthStart, alloc: std.mem.Allocator) void {
        alloc.free(self.url);
        alloc.free(self.verifier);
        self.* = undefined;
    }
};

pub const OAuthCodeInput = struct {
    code: []u8,
    state: ?[]u8 = null,
    redirect_uri: ?[]u8 = null,

    pub fn deinit(self: *OAuthCodeInput, alloc: std.mem.Allocator) void {
        alloc.free(self.code);
        if (self.state) |s| alloc.free(s);
        if (self.redirect_uri) |u| alloc.free(u);
        self.* = undefined;
    }
};

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
    return loadForProvider(alloc, .anthropic);
}

pub fn loadForProvider(alloc: std.mem.Allocator, provider: Provider) !Result {
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const ar = arena.allocator();

    if (authFromEnv(providerEnvAuth(ar, provider))) |auth| {
        return .{ .arena = arena, .auth = auth };
    }

    const home = std.process.getEnvVarOwned(ar, "HOME") catch return error.AuthNotFound;
    return .{
        .arena = arena,
        .auth = try loadFileAuthForProvider(ar, home, provider),
    };
}

const EnvAuth = struct {
    oauth: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
};

fn readEnv(ar: std.mem.Allocator, key: []const u8) ?[]const u8 {
    return std.process.getEnvVarOwned(ar, key) catch null;
}

fn providerEnvAuth(ar: std.mem.Allocator, provider: Provider) EnvAuth {
    return switch (provider) {
        .anthropic => .{
            .oauth = readEnv(ar, anthropic_oauth_env),
            .api_key = readEnv(ar, anthropic_api_key_env),
        },
        .openai => .{
            .oauth = null,
            .api_key = readEnv(ar, openai_api_key_env),
        },
        .google => .{},
    };
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
    return loadFileAuthForProvider(alloc, home, .anthropic);
}

fn loadFileAuthForProvider(alloc: std.mem.Allocator, home: []const u8, provider: Provider) !Auth {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const ar = arena.allocator();

    const path = findAuthFile(ar, home) catch return error.AuthNotFound;
    const raw = std.fs.cwd().readFileAlloc(ar, path, 1024 * 1024) catch return error.AuthNotFound;
    const parsed = std.json.parseFromSlice(AuthFile, ar, raw, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return error.AuthNotFound;
    const entry = switch (provider) {
        .anthropic => parsed.value.anthropic,
        .openai => parsed.value.openai,
        .google => parsed.value.google,
    } orelse return error.AuthNotFound;

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

pub fn beginAnthropicOAuth(alloc: std.mem.Allocator) !OAuthStart {
    return beginOAuth(alloc, .anthropic);
}

pub fn beginAnthropicOAuthWithRedirect(
    alloc: std.mem.Allocator,
    oauth_redirect_uri: []const u8,
) !OAuthStart {
    return beginOAuthWithRedirect(alloc, .anthropic, oauth_redirect_uri);
}

pub fn beginOpenAICodexOAuth(alloc: std.mem.Allocator) !OAuthStart {
    return beginOAuth(alloc, .openai);
}

pub fn beginOpenAICodexOAuthWithRedirect(
    alloc: std.mem.Allocator,
    oauth_redirect_uri: []const u8,
) !OAuthStart {
    return beginOAuthWithRedirect(alloc, .openai, oauth_redirect_uri);
}

pub fn beginOAuth(alloc: std.mem.Allocator, provider: Provider) !OAuthStart {
    const spec = oauthSpec(provider) orelse return error.UnsupportedOAuthProvider;
    return beginOAuthWithSpec(alloc, spec, spec.default_redirect_uri);
}

pub fn beginOAuthWithRedirect(
    alloc: std.mem.Allocator,
    provider: Provider,
    oauth_redirect_uri: []const u8,
) !OAuthStart {
    const spec = oauthSpec(provider) orelse return error.UnsupportedOAuthProvider;
    return beginOAuthWithSpec(alloc, spec, oauth_redirect_uri);
}

fn beginOAuthWithSpec(
    alloc: std.mem.Allocator,
    spec: *const OAuthSpec,
    oauth_redirect_uri: []const u8,
) !OAuthStart {
    const verifier = try pkceVerifier(alloc);
    errdefer alloc.free(verifier);

    const challenge = try pkceChallenge(alloc, verifier);
    defer alloc.free(challenge);

    var query = std.ArrayList(u8).empty;
    defer query.deinit(alloc);

    try appendQueryParam(alloc, &query, "response_type", "code");
    try appendQueryParam(alloc, &query, "client_id", spec.client_id);
    try appendQueryParam(alloc, &query, "redirect_uri", oauth_redirect_uri);
    try appendQueryParam(alloc, &query, "scope", spec.scopes);
    try appendQueryParam(alloc, &query, "code_challenge", challenge);
    try appendQueryParam(alloc, &query, "code_challenge_method", "S256");
    try appendQueryParam(alloc, &query, "state", verifier);
    for (spec.extra_authorize) |extra| {
        try appendQueryParam(alloc, &query, extra.key, extra.value);
    }

    const url = try std.fmt.allocPrint(alloc, "{s}?{s}", .{ spec.authorize_url, query.items });
    errdefer alloc.free(url);

    return .{
        .url = url,
        .verifier = verifier,
    };
}

pub fn completeAnthropicOAuth(alloc: std.mem.Allocator, input: []const u8) !void {
    return completeOAuth(alloc, .anthropic, input);
}

pub fn completeAnthropicOAuthFromLocalCallback(
    alloc: std.mem.Allocator,
    callback: oauth_callback.CodeState,
    oauth_redirect_uri: []const u8,
    verifier: []const u8,
) !void {
    return completeOAuthFromLocalCallback(alloc, .anthropic, callback, oauth_redirect_uri, verifier);
}

pub fn completeOpenAICodexOAuth(alloc: std.mem.Allocator, input: []const u8) !void {
    return completeOAuth(alloc, .openai, input);
}

pub fn completeOpenAICodexOAuthFromLocalCallback(
    alloc: std.mem.Allocator,
    callback: oauth_callback.CodeState,
    oauth_redirect_uri: []const u8,
    verifier: []const u8,
) !void {
    return completeOAuthFromLocalCallback(alloc, .openai, callback, oauth_redirect_uri, verifier);
}

pub fn completeOAuth(alloc: std.mem.Allocator, provider: Provider, input: []const u8) !void {
    const spec = oauthSpec(provider) orelse return error.UnsupportedOAuthProvider;

    var parsed = try parseOAuthInput(alloc, input);
    defer parsed.deinit(alloc);

    const state = parsed.state orelse return error.MissingOAuthState;
    if (state.len == 0) return error.MissingOAuthState;
    const oauth_redirect_uri = parsed.redirect_uri orelse spec.default_redirect_uri;

    // Manual completion path uses state as verifier (legacy code#state support).
    const oauth = try exchangeAuthorizationCode(alloc, spec, parsed.code, state, oauth_redirect_uri, state);
    defer {
        alloc.free(oauth.access);
        alloc.free(oauth.refresh);
    }
    try saveOAuthForProvider(alloc, provider, oauth);
}

pub fn completeOAuthFromLocalCallback(
    alloc: std.mem.Allocator,
    provider: Provider,
    callback: oauth_callback.CodeState,
    oauth_redirect_uri: []const u8,
    verifier: []const u8,
) !void {
    const spec = oauthSpec(provider) orelse return error.UnsupportedOAuthProvider;
    if (!std.mem.eql(u8, callback.state, verifier)) return error.OAuthStateMismatch;

    const oauth = try exchangeAuthorizationCode(
        alloc,
        spec,
        callback.code,
        callback.state,
        oauth_redirect_uri,
        verifier,
    );
    defer {
        alloc.free(oauth.access);
        alloc.free(oauth.refresh);
    }
    try saveOAuthForProvider(alloc, provider, oauth);
}

pub fn parseAnthropicOAuthInput(alloc: std.mem.Allocator, input: []const u8) !OAuthCodeInput {
    return parseOAuthInput(alloc, input);
}

pub fn parseOAuthInput(alloc: std.mem.Allocator, input: []const u8) !OAuthCodeInput {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidOAuthInput;

    if (std.mem.indexOf(u8, trimmed, "code=") != null) {
        const q_start = std.mem.indexOfScalar(u8, trimmed, '?');
        const query = if (q_start) |i| blk: {
            const hash_start = std.mem.indexOfScalarPos(u8, trimmed, i + 1, '#') orelse trimmed.len;
            break :blk trimmed[i + 1 .. hash_start];
        } else trimmed;

        var parsed = try oauth_callback.parseCodeStateQuery(alloc, query);
        errdefer parsed.deinit(alloc);

        const redirect_out = if (q_start) |i| blk: {
            const redirect_source = trimmed[0..i];
            if (std.mem.startsWith(u8, redirect_source, "http://") or std.mem.startsWith(u8, redirect_source, "https://")) {
                break :blk try alloc.dupe(u8, redirect_source);
            }
            break :blk null;
        } else null;
        errdefer if (redirect_out) |u| alloc.free(u);

        return .{
            .code = parsed.code,
            .state = parsed.state,
            .redirect_uri = redirect_out,
        };
    }

    if (std.mem.indexOfScalar(u8, trimmed, '#')) |i| {
        const code_in = std.mem.trim(u8, trimmed[0..i], " \t");
        const state_in = std.mem.trim(u8, trimmed[i + 1 ..], " \t");
        if (code_in.len == 0 or state_in.len == 0) return error.InvalidOAuthInput;
        return .{
            .code = try decodeQueryValue(alloc, code_in),
            .state = try decodeQueryValue(alloc, state_in),
            .redirect_uri = null,
        };
    }

    return .{
        .code = try decodeQueryValue(alloc, trimmed),
        .state = null,
        .redirect_uri = null,
    };
}

pub fn openBrowser(alloc: std.mem.Allocator, url: []const u8) !void {
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{ "open", url },
        .linux => &.{ "xdg-open", url },
        .windows => &.{ "cmd", "/c", "start", "", url },
        else => return error.UnsupportedPlatform,
    };

    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = argv,
        .max_output_bytes = 1024,
    }) catch return error.BrowserOpenFailed;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) return error.BrowserOpenFailed;
        },
        else => return error.BrowserOpenFailed,
    }
}

fn pkceVerifier(alloc: std.mem.Allocator) ![]u8 {
    var raw: [32]u8 = undefined;
    std.crypto.random.bytes(&raw);
    const enc_len = std.base64.url_safe_no_pad.Encoder.calcSize(raw.len);
    const out = try alloc.alloc(u8, enc_len);
    _ = std.base64.url_safe_no_pad.Encoder.encode(out, &raw);
    return out;
}

fn pkceChallenge(alloc: std.mem.Allocator, verifier: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    const enc_len = std.base64.url_safe_no_pad.Encoder.calcSize(digest.len);
    const out = try alloc.alloc(u8, enc_len);
    _ = std.base64.url_safe_no_pad.Encoder.encode(out, &digest);
    return out;
}

fn encodeQueryComponentAlloc(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);

    for (raw) |c| {
        const is_unreserved =
            (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '-' or c == '_' or c == '.' or c == '~';
        if (is_unreserved) {
            try out.append(alloc, c);
            continue;
        }
        try out.append(alloc, '%');
        try out.append(alloc, hexUpper((c >> 4) & 0x0f));
        try out.append(alloc, hexUpper(c & 0x0f));
    }
    return out.toOwnedSlice(alloc);
}

fn appendQueryParam(alloc: std.mem.Allocator, out: *std.ArrayList(u8), key: []const u8, value: []const u8) !void {
    if (out.items.len > 0) try out.append(alloc, '&');
    try out.appendSlice(alloc, key);
    try out.append(alloc, '=');
    const enc = try encodeQueryComponentAlloc(alloc, value);
    defer alloc.free(enc);
    try out.appendSlice(alloc, enc);
}

fn encodeFormComponentAlloc(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);

    for (raw) |c| {
        const is_unreserved =
            (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '-' or c == '_' or c == '.' or c == '~';
        if (is_unreserved) {
            try out.append(alloc, c);
            continue;
        }
        if (c == ' ') {
            try out.append(alloc, '+');
            continue;
        }
        try out.append(alloc, '%');
        try out.append(alloc, hexUpper((c >> 4) & 0x0f));
        try out.append(alloc, hexUpper(c & 0x0f));
    }
    return out.toOwnedSlice(alloc);
}

fn hexUpper(v: u8) u8 {
    return if (v < 10) ('0' + v) else ('A' + (v - 10));
}

const TokenReq = struct {
    content_type: []const u8,
    body: []const u8,
};

fn tokenReqContentType(spec: *const OAuthSpec) []const u8 {
    return switch (spec.token_body) {
        .json_with_state => "application/json",
        .form_no_state => "application/x-www-form-urlencoded",
    };
}

fn buildTokenReqBody(
    ar: std.mem.Allocator,
    spec: *const OAuthSpec,
    code: []const u8,
    state: []const u8,
    oauth_redirect_uri: []const u8,
    verifier: []const u8,
) !TokenReq {
    return switch (spec.token_body) {
        .json_with_state => blk: {
            const Body = struct {
                grant_type: []const u8,
                client_id: []const u8,
                code: []const u8,
                state: []const u8,
                redirect_uri: []const u8,
                code_verifier: []const u8,
            };
            break :blk .{
                .content_type = tokenReqContentType(spec),
                .body = try std.json.Stringify.valueAlloc(ar, Body{
                    .grant_type = "authorization_code",
                    .client_id = spec.client_id,
                    .code = code,
                    .state = state,
                    .redirect_uri = oauth_redirect_uri,
                    .code_verifier = verifier,
                }, .{}),
            };
        },
        .form_no_state => blk: {
            const code_enc = try encodeFormComponentAlloc(ar, code);
            const verifier_enc = try encodeFormComponentAlloc(ar, verifier);
            const redirect_enc = try encodeFormComponentAlloc(ar, oauth_redirect_uri);
            break :blk .{
                .content_type = tokenReqContentType(spec),
                .body = try std.fmt.allocPrint(
                    ar,
                    "grant_type=authorization_code&client_id={s}&code={s}&code_verifier={s}&redirect_uri={s}",
                    .{ spec.client_id, code_enc, verifier_enc, redirect_enc },
                ),
            };
        },
    };
}

fn buildRefreshReqBody(
    ar: std.mem.Allocator,
    spec: *const OAuthSpec,
    refresh_token: []const u8,
) !TokenReq {
    return switch (spec.token_body) {
        .json_with_state => blk: {
            const Body = struct {
                grant_type: []const u8,
                client_id: []const u8,
                refresh_token: []const u8,
            };
            break :blk .{
                .content_type = tokenReqContentType(spec),
                .body = try std.json.Stringify.valueAlloc(ar, Body{
                    .grant_type = "refresh_token",
                    .client_id = spec.client_id,
                    .refresh_token = refresh_token,
                }, .{}),
            };
        },
        .form_no_state => blk: {
            const refresh_enc = try encodeFormComponentAlloc(ar, refresh_token);
            break :blk .{
                .content_type = tokenReqContentType(spec),
                .body = try std.fmt.allocPrint(
                    ar,
                    "grant_type=refresh_token&client_id={s}&refresh_token={s}",
                    .{ spec.client_id, refresh_enc },
                ),
            };
        },
    };
}

fn parseOAuthTokenResponse(
    alloc: std.mem.Allocator,
    ar: std.mem.Allocator,
    resp_body: []const u8,
    parse_err: anyerror,
) !OAuth {
    const parsed = std.json.parseFromSlice(struct {
        access_token: []const u8,
        refresh_token: []const u8,
        expires_in: i64,
    }, ar, resp_body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return parse_err;

    const now_ms = std.time.milliTimestamp();
    const expires = now_ms + parsed.value.expires_in * 1000 - 5 * 60 * 1000;

    const access = try alloc.dupe(u8, parsed.value.access_token);
    errdefer alloc.free(access);
    const refresh = try alloc.dupe(u8, parsed.value.refresh_token);
    errdefer alloc.free(refresh);

    return .{
        .access = access,
        .refresh = refresh,
        .expires = expires,
    };
}

fn exchangeAuthorizationCode(
    alloc: std.mem.Allocator,
    spec: *const OAuthSpec,
    code: []const u8,
    state: []const u8,
    oauth_redirect_uri: []const u8,
    verifier: []const u8,
) !OAuth {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const ar = arena.allocator();

    const token_req = try buildTokenReqBody(ar, spec, code, state, oauth_redirect_uri, verifier);

    var http = std.http.Client{ .allocator = ar };
    defer http.deinit();

    const uri = std.Uri{
        .scheme = "https",
        .host = .{ .raw = spec.token_host },
        .path = .{ .raw = spec.token_path },
    };

    var send_buf: [1024]u8 = undefined;
    var req = try http.request(.POST, uri, .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = token_req.content_type },
        },
        .keep_alive = false,
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = token_req.body.len };
    var bw = try req.sendBodyUnflushed(&send_buf);
    try bw.writer.writeAll(token_req.body);
    try bw.end();
    try req.connection.?.flush();

    var redir_buf: [0]u8 = .{};
    var resp = try req.receiveHead(&redir_buf);

    if (resp.head.status != .ok) return error.TokenExchangeFailed;

    var transfer_buf: [16384]u8 = undefined;
    var decomp: std.http.Decompress = undefined;
    var decomp_buf: [std.compress.flate.max_window_len]u8 = undefined;
    const rdr = resp.readerDecompressing(&transfer_buf, &decomp, &decomp_buf);
    const resp_body = try rdr.allocRemaining(ar, .limited(65536));

    return parseOAuthTokenResponse(alloc, ar, resp_body, error.TokenExchangeFailed);
}

fn decodeQueryValue(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);

    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (c == '+') {
            try out.append(alloc, ' ');
            continue;
        }
        if (c != '%') {
            try out.append(alloc, c);
            continue;
        }
        if (i + 2 >= raw.len) return error.InvalidOAuthInput;
        const hi = fromHex(raw[i + 1]) orelse return error.InvalidOAuthInput;
        const lo = fromHex(raw[i + 2]) orelse return error.InvalidOAuthInput;
        try out.append(alloc, (hi << 4) | lo);
        i += 2;
    }
    return out.toOwnedSlice(alloc);
}

fn fromHex(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

/// Refresh an expired OAuth token. Returns new OAuth credentials and saves to disk.
pub fn refreshOAuth(alloc: std.mem.Allocator, old: OAuth) !OAuth {
    return refreshOAuthForProvider(alloc, .anthropic, old);
}

/// Refresh an expired OAuth token for a specific provider.
pub fn refreshOAuthForProvider(alloc: std.mem.Allocator, provider: Provider, old: OAuth) !OAuth {
    const spec = oauthSpec(provider) orelse return error.UnsupportedOAuthProvider;

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const ar = arena.allocator();

    const req_body = try buildRefreshReqBody(ar, spec, old.refresh);

    var http = std.http.Client{ .allocator = ar };
    defer http.deinit();

    const uri = std.Uri{
        .scheme = "https",
        .host = .{ .raw = spec.token_host },
        .path = .{ .raw = spec.token_path },
    };

    var send_buf: [1024]u8 = undefined;
    var req = try http.request(.POST, uri, .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = req_body.content_type },
        },
        .keep_alive = false,
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = req_body.body.len };
    var bw = try req.sendBodyUnflushed(&send_buf);
    try bw.writer.writeAll(req_body.body);
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

    const new_oauth = try parseOAuthTokenResponse(alloc, ar, resp_body, error.RefreshFailed);

    saveOAuthForProvider(ar, provider, new_oauth) catch |err| {
        std.debug.print("warning: failed to persist refreshed token: {s}\n", .{@errorName(err)});
    };

    return new_oauth;
}

fn saveOAuthForProvider(ar: std.mem.Allocator, provider: Provider, oauth: OAuth) !void {
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

    const entry: AuthEntry = .{
        .type = "oauth",
        .access = oauth.access,
        .refresh = oauth.refresh,
        .expires = oauth.expires,
    };
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

test "loadFileAuthForProvider parses openai oauth entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(".pi/agent");
    try tmp.dir.writeFile(.{
        .sub_path = ".pi/agent/auth.json",
        .data =
        \\{
        \\  "openai": {
        \\    "type": "oauth",
        \\    "access": "oa-access",
        \\    "refresh": "oa-refresh",
        \\    "expires": 123
        \\  }
        \\}
        ,
    });

    const home = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(home);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const auth = try loadFileAuthForProvider(arena.allocator(), home, .openai);
    switch (auth) {
        .oauth => |oauth| {
            try std.testing.expectEqualStrings("oa-access", oauth.access);
            try std.testing.expectEqualStrings("oa-refresh", oauth.refresh);
            try std.testing.expectEqual(@as(i64, 123), oauth.expires);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "loadFileAuthForProvider returns AuthNotFound when provider missing" {
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
    try std.testing.expectError(error.AuthNotFound, loadFileAuthForProvider(arena.allocator(), home, .openai));
}

test "oauth helpers expose provider capabilities and metadata" {
    try std.testing.expect(oauthCapable(.anthropic));
    try std.testing.expect(oauthCapable(.openai));
    try std.testing.expect(!oauthCapable(.google));

    try std.testing.expect(looksLikeApiKey(.anthropic, "sk-ant-api03-abc"));
    try std.testing.expect(!looksLikeApiKey(.anthropic, "http://localhost/callback?code=x&state=y"));
    try std.testing.expect(looksLikeApiKey(.openai, "sk-proj-123"));
    try std.testing.expect(!looksLikeApiKey(.openai, "http://localhost/callback?code=x&state=y"));
    try std.testing.expect(looksLikeApiKey(.google, "anything"));

    const anth = oauthLoginInfo(.anthropic) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("/callback", anth.callback_path);
    try std.testing.expectEqualStrings("start anthropic oauth", anth.start_action);
    try std.testing.expectEqualStrings("complete anthropic oauth", anth.complete_action);

    const oa = oauthLoginInfo(.openai) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("/auth/callback", oa.callback_path);
    try std.testing.expectEqualStrings("start openai oauth", oa.start_action);
    try std.testing.expectEqualStrings("complete openai oauth", oa.complete_action);

    try std.testing.expect(oauthLoginInfo(.google) == null);
}

test "beginAnthropicOAuth builds authorization URL and verifier" {
    var flow = try beginAnthropicOAuth(std.testing.allocator);
    defer flow.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.startsWith(u8, flow.url, "https://claude.ai/oauth/authorize?"));
    try std.testing.expect(std.mem.indexOf(u8, flow.url, "client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e") != null);
    try std.testing.expect(std.mem.indexOf(u8, flow.url, "code_challenge=") != null);
    try std.testing.expect(std.mem.indexOf(u8, flow.url, "state=") != null);
    try std.testing.expect(flow.verifier.len > 16);
}

test "beginAnthropicOAuthWithRedirect encodes localhost callback URI" {
    var flow = try beginAnthropicOAuthWithRedirect(std.testing.allocator, "http://127.0.0.1:54321/callback");
    defer flow.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, flow.url, "redirect_uri=http%3A%2F%2F127.0.0.1%3A54321%2Fcallback") != null);
}

test "beginOpenAICodexOAuthWithRedirect encodes callback URI and codex params" {
    var flow = try beginOpenAICodexOAuthWithRedirect(std.testing.allocator, "http://127.0.0.1:54321/auth/callback");
    defer flow.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.startsWith(u8, flow.url, "https://auth.openai.com/oauth/authorize?"));
    try std.testing.expect(std.mem.indexOf(u8, flow.url, "client_id=app_EMoamEEZ73f0CkXaXp7hrann") != null);
    try std.testing.expect(std.mem.indexOf(u8, flow.url, "redirect_uri=http%3A%2F%2F127.0.0.1%3A54321%2Fauth%2Fcallback") != null);
    try std.testing.expect(std.mem.indexOf(u8, flow.url, "codex_cli_simplified_flow=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, flow.url, "originator=pz") != null);
}

test "beginOAuthWithRedirect rejects unsupported provider" {
    try std.testing.expectError(
        error.UnsupportedOAuthProvider,
        beginOAuthWithRedirect(std.testing.allocator, .google, "http://127.0.0.1:1234/callback"),
    );
}

test "parseAnthropicOAuthInput supports code#state" {
    var parsed = try parseAnthropicOAuthInput(std.testing.allocator, "abc123#state456");
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("abc123", parsed.code);
    try std.testing.expect(parsed.state != null);
    try std.testing.expectEqualStrings("state456", parsed.state.?);
    try std.testing.expect(parsed.redirect_uri == null);
}

test "parseAnthropicOAuthInput supports callback URL query params" {
    const input = "http://localhost:64915/callback?code=abc123&state=state%20456";
    var parsed = try parseAnthropicOAuthInput(std.testing.allocator, input);
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("abc123", parsed.code);
    try std.testing.expect(parsed.state != null);
    try std.testing.expectEqualStrings("state 456", parsed.state.?);
    try std.testing.expect(parsed.redirect_uri != null);
    try std.testing.expectEqualStrings("http://localhost:64915/callback", parsed.redirect_uri.?);
}

test "parseAnthropicOAuthInput supports raw query params" {
    var parsed = try parseAnthropicOAuthInput(std.testing.allocator, "code=abc123&state=state%20456");
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("abc123", parsed.code);
    try std.testing.expect(parsed.state != null);
    try std.testing.expectEqualStrings("state 456", parsed.state.?);
    try std.testing.expect(parsed.redirect_uri == null);
}

test "parseAnthropicOAuthInput accepts code-only input" {
    var parsed = try parseAnthropicOAuthInput(std.testing.allocator, "abc123");
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("abc123", parsed.code);
    try std.testing.expect(parsed.state == null);
}

test "parseAnthropicOAuthInput rejects empty input" {
    try std.testing.expectError(error.InvalidOAuthInput, parseAnthropicOAuthInput(std.testing.allocator, " \t\r\n"));
}

test "completeAnthropicOAuthFromLocalCallback rejects mismatched state" {
    const code = try std.testing.allocator.dupe(u8, "c");
    defer std.testing.allocator.free(code);
    const state = try std.testing.allocator.dupe(u8, "state-a");
    defer std.testing.allocator.free(state);
    const cb = oauth_callback.CodeState{
        .code = code,
        .state = state,
    };
    try std.testing.expectError(
        error.OAuthStateMismatch,
        completeAnthropicOAuthFromLocalCallback(
            std.testing.allocator,
            cb,
            "http://127.0.0.1:1234/callback",
            "state-b",
        ),
    );
}

test "completeOpenAICodexOAuthFromLocalCallback rejects mismatched state" {
    const code = try std.testing.allocator.dupe(u8, "c");
    defer std.testing.allocator.free(code);
    const state = try std.testing.allocator.dupe(u8, "state-a");
    defer std.testing.allocator.free(state);
    const cb = oauth_callback.CodeState{
        .code = code,
        .state = state,
    };
    try std.testing.expectError(
        error.OAuthStateMismatch,
        completeOpenAICodexOAuthFromLocalCallback(
            std.testing.allocator,
            cb,
            "http://127.0.0.1:1234/auth/callback",
            "state-b",
        ),
    );
}

test "completeOAuthFromLocalCallback rejects unsupported provider" {
    const code = try std.testing.allocator.dupe(u8, "c");
    defer std.testing.allocator.free(code);
    const state = try std.testing.allocator.dupe(u8, "state-a");
    defer std.testing.allocator.free(state);
    const cb = oauth_callback.CodeState{
        .code = code,
        .state = state,
    };
    try std.testing.expectError(
        error.UnsupportedOAuthProvider,
        completeOAuthFromLocalCallback(
            std.testing.allocator,
            .google,
            cb,
            "http://127.0.0.1:1234/callback",
            "state-a",
        ),
    );
}

test "tokenReqContentType maps oauth token body types" {
    try std.testing.expectEqualStrings("application/json", tokenReqContentType(&anthropic_spec));
    try std.testing.expectEqualStrings("application/x-www-form-urlencoded", tokenReqContentType(&openai_spec));
}

test "buildRefreshReqBody uses provider-specific body shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const anth = try buildRefreshReqBody(ar, &anthropic_spec, "rt-1");
    try std.testing.expectEqualStrings("application/json", anth.content_type);
    try std.testing.expect(std.mem.indexOf(u8, anth.body, "\"grant_type\":\"refresh_token\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, anth.body, "\"refresh_token\":\"rt-1\"") != null);

    const oa = try buildRefreshReqBody(ar, &openai_spec, "rt 2");
    try std.testing.expectEqualStrings("application/x-www-form-urlencoded", oa.content_type);
    try std.testing.expect(std.mem.indexOf(u8, oa.body, "grant_type=refresh_token") != null);
    try std.testing.expect(std.mem.indexOf(u8, oa.body, "refresh_token=rt+2") != null);
}

test "refreshOAuthForProvider rejects unsupported provider" {
    const old = OAuth{
        .access = "a",
        .refresh = "r",
        .expires = 0,
    };
    try std.testing.expectError(
        error.UnsupportedOAuthProvider,
        refreshOAuthForProvider(std.testing.allocator, .google, old),
    );
}
