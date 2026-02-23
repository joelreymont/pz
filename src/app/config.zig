const std = @import("std");
const args = @import("args.zig");

pub const model_default = "default";
pub const provider_default = "default";
pub const session_dir_default = ".pz/sessions";
pub const auto_cfg_path = ".pz.json";
pub const pi_settings_rel_path = ".pi/agent/settings.json";

pub const Env = struct {
    model: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    session_dir: ?[]const u8 = null,
    mode: ?[]const u8 = null,
    provider_cmd: ?[]const u8 = null,
    home: ?[]const u8 = null,

    pub fn fromProcess(alloc: std.mem.Allocator) !Env {
        return .{
            .model = dupEnvAlias(alloc, "PZ_MODEL", "PI_MODEL"),
            .provider = dupEnvAlias(alloc, "PZ_PROVIDER", "PI_PROVIDER"),
            .session_dir = dupEnvAlias(alloc, "PZ_SESSION_DIR", "PI_SESSION_DIR"),
            .mode = dupEnvAlias(alloc, "PZ_MODE", "PI_MODE"),
            .provider_cmd = dupEnvAlias(alloc, "PZ_PROVIDER_CMD", "PI_PROVIDER_CMD"),
            .home = dupEnv(alloc, "HOME"),
        };
    }

    pub fn deinit(self: *Env, alloc: std.mem.Allocator) void {
        if (self.model) |v| alloc.free(v);
        if (self.provider) |v| alloc.free(v);
        if (self.session_dir) |v| alloc.free(v);
        if (self.mode) |v| alloc.free(v);
        if (self.provider_cmd) |v| alloc.free(v);
        if (self.home) |v| alloc.free(v);
        self.* = undefined;
    }
};

pub const Config = struct {
    mode: args.Mode,
    model: []u8,
    provider: []u8,
    session_dir: []u8,
    provider_cmd: ?[]u8 = null,
    enabled_models: ?[][]u8 = null, // model cycle list

    pub fn deinit(self: *Config, alloc: std.mem.Allocator) void {
        alloc.free(self.model);
        alloc.free(self.provider);
        alloc.free(self.session_dir);
        if (self.provider_cmd) |v| alloc.free(v);
        if (self.enabled_models) |models| {
            for (models) |m| alloc.free(m);
            alloc.free(models);
        }
        self.* = undefined;
    }
};

pub const pz_state_dir = ".pz";
pub const pz_state_file = "state.json";

pub const PzState = struct {
    last_hash: ?[]const u8 = null,

    pub fn load(alloc: std.mem.Allocator) ?PzState {
        const home = std.posix.getenv("HOME") orelse return null;
        const path = std.fs.path.join(alloc, &.{ home, pz_state_dir, pz_state_file }) catch return null;
        defer alloc.free(path);
        const raw = std.fs.cwd().readFileAlloc(alloc, path, 64 * 1024) catch return null;
        defer alloc.free(raw);
        const parsed = std.json.parseFromSlice(PzState, alloc, raw, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch return null;
        defer parsed.deinit();
        // Dupe fields so they outlive the parsed arena
        return .{
            .last_hash = if (parsed.value.last_hash) |h| (alloc.dupe(u8, h) catch return null) else null,
        };
    }

    pub fn save(self: PzState, alloc: std.mem.Allocator) void {
        const home = std.posix.getenv("HOME") orelse return;
        const dir_path = std.fs.path.join(alloc, &.{ home, pz_state_dir }) catch return;
        defer alloc.free(dir_path);
        std.fs.cwd().makePath(dir_path) catch return;
        const path = std.fs.path.join(alloc, &.{ dir_path, pz_state_file }) catch return;
        defer alloc.free(path);
        const json = std.json.Stringify.valueAlloc(alloc, self, .{}) catch return;
        defer alloc.free(json);
        const file = std.fs.cwd().createFile(path, .{}) catch return;
        defer file.close();
        file.writeAll(json) catch return;
    }

    pub fn deinit(self: *PzState, alloc: std.mem.Allocator) void {
        if (self.last_hash) |h| alloc.free(h);
        self.* = undefined;
    }
};

pub const Err = anyerror;

pub fn discover(
    alloc: std.mem.Allocator,
    dir: std.fs.Dir,
    parsed: args.Parsed,
    env: Env,
) Err!Config {
    var out = Config{
        .mode = .tui,
        .model = try alloc.dupe(u8, model_default),
        .provider = try alloc.dupe(u8, provider_default),
        .session_dir = try alloc.dupe(u8, session_dir_default),
    };
    errdefer out.deinit(alloc);

    if (parsed.cfg == .auto) {
        if (try loadPiSettings(alloc, env.home)) |pi_cfg| {
            defer pi_cfg.deinit();
            try applyPiCfg(alloc, &out, pi_cfg.value);
        }
    }

    if (try loadFile(alloc, dir, parsed.cfg)) |file_cfg| {
        defer file_cfg.deinit();
        try applyRawCfg(
            alloc,
            &out,
            file_cfg.value.model,
            file_cfg.value.provider,
            file_cfg.value.session_dir,
            file_cfg.value.mode,
            file_cfg.value.provider_cmd,
            error.InvalidFileMode,
        );
        // File models override pi settings
        if (file_cfg.value.models) |csv| {
            try setModels(alloc, &out, csv);
        }
    }

    try applyRawCfg(
        alloc,
        &out,
        env.model,
        env.provider,
        env.session_dir,
        env.mode,
        env.provider_cmd,
        error.InvalidEnvMode,
    );

    // PZ_MODELS env var
    if (dupEnvAlias(alloc, "PZ_MODELS", "PI_MODELS")) |v| {
        defer alloc.free(v);
        try setModels(alloc, &out, v);
    }

    if (parsed.mode_set) out.mode = parsed.mode;
    try applyRawCfg(
        alloc,
        &out,
        parsed.model,
        parsed.provider,
        parsed.session_dir,
        null,
        parsed.provider_cmd,
        error.InvalidMode,
    );

    // CLI --models overrides everything
    if (parsed.models) |csv| {
        try setModels(alloc, &out, csv);
    }

    return out;
}

const FileCfg = struct {
    model: ?[]const u8 = null,
    models: ?[]const u8 = null, // comma-separated
    provider: ?[]const u8 = null,
    session_dir: ?[]const u8 = null,
    mode: ?[]const u8 = null,
    provider_cmd: ?[]const u8 = null,
};

const PiFileCfg = struct {
    defaultModel: ?[]const u8 = null,
    model: ?[]const u8 = null,
    enabledModels: ?[]const []const u8 = null,
    models: ?[]const u8 = null, // comma-separated (pz native)
    defaultProvider: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    sessionDir: ?[]const u8 = null,
    session_dir: ?[]const u8 = null,
    defaultMode: ?[]const u8 = null,
    mode: ?[]const u8 = null,
    providerCommand: ?[]const u8 = null,
    provider_cmd: ?[]const u8 = null,
};

fn loadFile(
    alloc: std.mem.Allocator,
    dir: std.fs.Dir,
    cfg_sel: args.CfgSel,
) Err!?std.json.Parsed(FileCfg) {
    const path = switch (cfg_sel) {
        .off => return null,
        .path => |p| p,
        .auto => if (hasFile(dir, auto_cfg_path) catch false) auto_cfg_path else return null,
    };

    const raw = try dir.readFileAlloc(alloc, path, 1024 * 1024);
    defer alloc.free(raw);

    const parsed = try std.json.parseFromSlice(FileCfg, alloc, raw, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    return parsed;
}

fn loadPiSettings(alloc: std.mem.Allocator, home: ?[]const u8) Err!?std.json.Parsed(PiFileCfg) {
    const home_path = home orelse return null;
    const path = try std.fs.path.join(alloc, &.{ home_path, pi_settings_rel_path });
    defer alloc.free(path);

    var file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();

    const raw = try file.readToEndAlloc(alloc, 1024 * 1024);
    defer alloc.free(raw);

    const parsed = try std.json.parseFromSlice(PiFileCfg, alloc, raw, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    return parsed;
}

fn applyPiCfg(alloc: std.mem.Allocator, cfg: *Config, pi: PiFileCfg) Err!void {
    try applyRawCfg(
        alloc,
        cfg,
        pick(pi.model, pi.defaultModel),
        pick(pi.provider, pi.defaultProvider),
        pick(pi.session_dir, pi.sessionDir),
        pick(pi.mode, pi.defaultMode),
        pick(pi.provider_cmd, pi.providerCommand),
        error.InvalidPiMode,
    );
    // Pi's enabledModels (JSON array) or pz-style comma-separated models
    if (pi.enabledModels) |arr| {
        try setModelsFromArray(alloc, cfg, arr);
    } else if (pi.models) |csv| {
        try setModels(alloc, cfg, csv);
    }
}

fn applyRawCfg(
    alloc: std.mem.Allocator,
    out: *Config,
    model: ?[]const u8,
    provider: ?[]const u8,
    session_dir: ?[]const u8,
    mode: ?[]const u8,
    provider_cmd: ?[]const u8,
    comptime invalid_mode: anytype,
) Err!void {
    if (model) |v| try replaceStr(alloc, &out.model, v);
    if (provider) |v| try replaceStr(alloc, &out.provider, v);
    if (session_dir) |v| try replaceStr(alloc, &out.session_dir, v);
    if (mode) |v| out.mode = try parseMode(v, invalid_mode);
    if (provider_cmd) |v| try replaceOptStr(alloc, &out.provider_cmd, v);
}

/// Parse comma-separated model list into enabled_models.
fn setModels(alloc: std.mem.Allocator, cfg: *Config, csv: []const u8) Err!void {
    var list = std.ArrayList([]u8).empty;
    errdefer {
        for (list.items) |m| alloc.free(m);
        list.deinit(alloc);
    }
    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t");
        if (trimmed.len == 0) continue;
        try list.append(alloc, try alloc.dupe(u8, trimmed));
    }
    if (list.items.len == 0) return;
    // Free previous
    if (cfg.enabled_models) |old| {
        for (old) |m| alloc.free(m);
        alloc.free(old);
    }
    cfg.enabled_models = try list.toOwnedSlice(alloc);
}

/// Set enabled_models from a JSON string array (pi's enabledModels format).
fn setModelsFromArray(alloc: std.mem.Allocator, cfg: *Config, arr: []const []const u8) Err!void {
    if (arr.len == 0) return;
    var list = try alloc.alloc([]u8, arr.len);
    errdefer {
        for (list, 0..) |_, i| {
            if (i < arr.len) alloc.free(list[i]);
        }
        alloc.free(list);
    }
    for (arr, 0..) |m, i| {
        list[i] = try alloc.dupe(u8, m);
    }
    if (cfg.enabled_models) |old| {
        for (old) |m| alloc.free(m);
        alloc.free(old);
    }
    cfg.enabled_models = list;
}

fn pick(primary: ?[]const u8, fallback: ?[]const u8) ?[]const u8 {
    if (primary) |v| return v;
    return fallback;
}

fn hasFile(dir: std.fs.Dir, path: []const u8) !bool {
    dir.access(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn parseMode(raw: []const u8, comptime invalid: anytype) @TypeOf(invalid)!args.Mode {
    const map = std.StaticStringMap(args.Mode).initComptime(.{
        .{ "tui", .tui },
        .{ "interactive", .tui },
        .{ "print", .print },
        .{ "json", .json },
        .{ "rpc", .rpc },
    });
    return map.get(raw) orelse invalid;
}

fn replaceStr(
    alloc: std.mem.Allocator,
    dst: *[]u8,
    src: []const u8,
) std.mem.Allocator.Error!void {
    const next = try alloc.dupe(u8, src);
    alloc.free(dst.*);
    dst.* = next;
}

fn replaceOptStr(
    alloc: std.mem.Allocator,
    dst: *?[]u8,
    src: []const u8,
) std.mem.Allocator.Error!void {
    const next = try alloc.dupe(u8, src);
    if (dst.*) |curr| alloc.free(curr);
    dst.* = next;
}

fn dupEnvAlias(alloc: std.mem.Allocator, primary: []const u8, fallback: []const u8) ?[]const u8 {
    if (dupEnv(alloc, primary)) |v| return v;
    return dupEnv(alloc, fallback);
}

fn dupEnv(alloc: std.mem.Allocator, key: []const u8) ?[]const u8 {
    const val = std.process.getEnvVarOwned(alloc, key) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => return null,
    };
    return val;
}

test "config uses defaults when no sources are present" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const parsed = try args.parse(&.{});
    var cfg = try discover(std.testing.allocator, tmp.dir, parsed, .{});
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expect(cfg.mode == .tui);
    try std.testing.expectEqualStrings(model_default, cfg.model);
    try std.testing.expectEqualStrings(provider_default, cfg.provider);
    try std.testing.expectEqualStrings(session_dir_default, cfg.session_dir);
    try std.testing.expect(cfg.provider_cmd == null);
}

test "config precedence is file then env then flags" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = auto_cfg_path,
        .data = "{\"mode\":\"print\",\"model\":\"file-model\",\"session_dir\":\"file-sessions\",\"provider_cmd\":\"file-cmd\"}",
    });

    const parsed = try args.parse(&.{ "--tui", "--model", "flag-model", "--provider-cmd", "flag-cmd" });
    var cfg = try discover(std.testing.allocator, tmp.dir, parsed, .{
        .model = "env-model",
        .provider = "env-provider",
        .session_dir = "env-sessions",
        .mode = "print",
        .provider_cmd = "env-cmd",
    });
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expect(cfg.mode == .tui);
    try std.testing.expectEqualStrings("flag-model", cfg.model);
    try std.testing.expectEqualStrings("env-provider", cfg.provider);
    try std.testing.expectEqualStrings("env-sessions", cfg.session_dir);
    try std.testing.expect(cfg.provider_cmd != null);
    try std.testing.expectEqualStrings("flag-cmd", cfg.provider_cmd.?);
}

test "config no-config bypasses file source" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = auto_cfg_path,
        .data = "{\"mode\":\"print\",\"model\":\"file-model\"}",
    });

    const parsed = try args.parse(&.{"--no-config"});
    var cfg = try discover(std.testing.allocator, tmp.dir, parsed, .{});
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expect(cfg.mode == .tui);
    try std.testing.expectEqualStrings(model_default, cfg.model);
    try std.testing.expectEqualStrings(provider_default, cfg.provider);
    try std.testing.expect(cfg.provider_cmd == null);
}

test "config explicit path loads file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "custom.json",
        .data = "{\"mode\":\"print\",\"model\":\"m\",\"session_dir\":\"s\",\"provider_cmd\":\"cmd\"}",
    });

    const parsed = try args.parse(&.{ "--config", "custom.json" });
    var cfg = try discover(std.testing.allocator, tmp.dir, parsed, .{});
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expect(cfg.mode == .print);
    try std.testing.expectEqualStrings("m", cfg.model);
    try std.testing.expectEqualStrings(provider_default, cfg.provider);
    try std.testing.expectEqualStrings("s", cfg.session_dir);
    try std.testing.expect(cfg.provider_cmd != null);
    try std.testing.expectEqualStrings("cmd", cfg.provider_cmd.?);
}

test "config rejects invalid env mode and invalid file mode" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const parsed = try args.parse(&.{});
    try std.testing.expectError(error.InvalidEnvMode, discover(
        std.testing.allocator,
        tmp.dir,
        parsed,
        .{
            .mode = "bad",
        },
    ));

    try tmp.dir.writeFile(.{
        .sub_path = auto_cfg_path,
        .data = "{\"mode\":\"bad\"}",
    });
    try std.testing.expectError(error.InvalidFileMode, discover(
        std.testing.allocator,
        tmp.dir,
        parsed,
        .{},
    ));
}

test "config accepts interactive alias for mode" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const parsed = try args.parse(&.{});
    var cfg = try discover(std.testing.allocator, tmp.dir, parsed, .{
        .mode = "interactive",
    });
    defer cfg.deinit(std.testing.allocator);
    try std.testing.expect(cfg.mode == .tui);
}

test "config auto imports pi settings from home" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("home/.pi/agent");
    try tmp.dir.writeFile(.{
        .sub_path = "home/.pi/agent/settings.json",
        .data =
        \\{
        \\  "defaultModel":"pi-model",
        \\  "defaultProvider":"anthropic",
        \\  "sessionDir":"/tmp/pi-sessions",
        \\  "defaultMode":"interactive",
        \\  "providerCommand":"pi-provider-cmd"
        \\}
        ,
    });

    const home_abs = try tmp.dir.realpathAlloc(std.testing.allocator, "home");
    defer std.testing.allocator.free(home_abs);

    const parsed = try args.parse(&.{});
    var cfg = try discover(std.testing.allocator, tmp.dir, parsed, .{
        .home = home_abs,
    });
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expect(cfg.mode == .tui);
    try std.testing.expectEqualStrings("pi-model", cfg.model);
    try std.testing.expectEqualStrings("anthropic", cfg.provider);
    try std.testing.expectEqualStrings("/tmp/pi-sessions", cfg.session_dir);
    try std.testing.expect(cfg.provider_cmd != null);
    try std.testing.expectEqualStrings("pi-provider-cmd", cfg.provider_cmd.?);
}

test "config local auto file overrides pi settings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("home/.pi/agent");
    try tmp.dir.writeFile(.{
        .sub_path = "home/.pi/agent/settings.json",
        .data =
        \\{
        \\  "defaultModel":"pi-model",
        \\  "defaultProvider":"pi-provider",
        \\  "sessionDir":"pi-sessions",
        \\  "defaultMode":"json",
        \\  "providerCommand":"pi-cmd"
        \\}
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = auto_cfg_path,
        .data = "{\"mode\":\"print\",\"model\":\"local-model\",\"provider\":\"local-provider\",\"session_dir\":\"local-sessions\",\"provider_cmd\":\"local-cmd\"}",
    });

    const home_abs = try tmp.dir.realpathAlloc(std.testing.allocator, "home");
    defer std.testing.allocator.free(home_abs);

    const parsed = try args.parse(&.{});
    var cfg = try discover(std.testing.allocator, tmp.dir, parsed, .{
        .home = home_abs,
    });
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expect(cfg.mode == .print);
    try std.testing.expectEqualStrings("local-model", cfg.model);
    try std.testing.expectEqualStrings("local-provider", cfg.provider);
    try std.testing.expectEqualStrings("local-sessions", cfg.session_dir);
    try std.testing.expect(cfg.provider_cmd != null);
    try std.testing.expectEqualStrings("local-cmd", cfg.provider_cmd.?);
}

test "config loads enabled_models from --models flag" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const parsed = try args.parse(&.{ "--models", "claude-opus-4-6,claude-haiku-4-5" });
    var cfg = try discover(std.testing.allocator, tmp.dir, parsed, .{});
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expect(cfg.enabled_models != null);
    const models = cfg.enabled_models.?;
    try std.testing.expectEqual(@as(usize, 2), models.len);
    try std.testing.expectEqualStrings("claude-opus-4-6", models[0]);
    try std.testing.expectEqualStrings("claude-haiku-4-5", models[1]);
}

test "config loads enabled_models from file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = auto_cfg_path,
        .data = "{\"models\":\"model-a, model-b, model-c\"}",
    });

    const parsed = try args.parse(&.{});
    var cfg = try discover(std.testing.allocator, tmp.dir, parsed, .{});
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expect(cfg.enabled_models != null);
    const models = cfg.enabled_models.?;
    try std.testing.expectEqual(@as(usize, 3), models.len);
    try std.testing.expectEqualStrings("model-a", models[0]);
    try std.testing.expectEqualStrings("model-b", models[1]);
    try std.testing.expectEqualStrings("model-c", models[2]);
}

test "config cli --models overrides file models" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = auto_cfg_path,
        .data = "{\"models\":\"file-model\"}",
    });

    const parsed = try args.parse(&.{ "--models", "cli-model" });
    var cfg = try discover(std.testing.allocator, tmp.dir, parsed, .{});
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expect(cfg.enabled_models != null);
    try std.testing.expectEqual(@as(usize, 1), cfg.enabled_models.?.len);
    try std.testing.expectEqualStrings("cli-model", cfg.enabled_models.?[0]);
}
