const std = @import("std");
const args = @import("args.zig");

pub const model_default = "default";
pub const provider_default = "default";
pub const session_dir_default = ".pizi/sessions";
pub const auto_cfg_path = ".pizi.json";

pub const Env = struct {
    model: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    session_dir: ?[]const u8 = null,
    mode: ?[]const u8 = null,
    provider_cmd: ?[]const u8 = null,

    pub fn fromProcess(alloc: std.mem.Allocator) !Env {
        return .{
            .model = dupEnv(alloc, "PIZI_MODEL"),
            .provider = dupEnv(alloc, "PIZI_PROVIDER"),
            .session_dir = dupEnv(alloc, "PIZI_SESSION_DIR"),
            .mode = dupEnv(alloc, "PIZI_MODE"),
            .provider_cmd = dupEnv(alloc, "PIZI_PROVIDER_CMD"),
        };
    }

    pub fn deinit(self: *Env, alloc: std.mem.Allocator) void {
        if (self.model) |v| alloc.free(v);
        if (self.provider) |v| alloc.free(v);
        if (self.session_dir) |v| alloc.free(v);
        if (self.mode) |v| alloc.free(v);
        if (self.provider_cmd) |v| alloc.free(v);
        self.* = undefined;
    }
};

pub const Config = struct {
    mode: args.Mode,
    model: []u8,
    provider: []u8,
    session_dir: []u8,
    provider_cmd: ?[]u8 = null,

    pub fn deinit(self: *Config, alloc: std.mem.Allocator) void {
        alloc.free(self.model);
        alloc.free(self.provider);
        alloc.free(self.session_dir);
        if (self.provider_cmd) |v| alloc.free(v);
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

    if (try loadFile(alloc, dir, parsed.cfg)) |file_cfg| {
        defer file_cfg.deinit();

        if (file_cfg.value.model) |model| try replaceStr(alloc, &out.model, model);
        if (file_cfg.value.provider) |provider| try replaceStr(alloc, &out.provider, provider);
        if (file_cfg.value.session_dir) |session_dir| try replaceStr(alloc, &out.session_dir, session_dir);
        if (file_cfg.value.mode) |mode_raw| out.mode = try parseMode(mode_raw, error.InvalidFileMode);
        if (file_cfg.value.provider_cmd) |provider_cmd| try replaceOptStr(alloc, &out.provider_cmd, provider_cmd);
    }

    if (env.model) |model| try replaceStr(alloc, &out.model, model);
    if (env.provider) |provider| try replaceStr(alloc, &out.provider, provider);
    if (env.session_dir) |session_dir| try replaceStr(alloc, &out.session_dir, session_dir);
    if (env.mode) |mode_raw| out.mode = try parseMode(mode_raw, error.InvalidEnvMode);
    if (env.provider_cmd) |provider_cmd| try replaceOptStr(alloc, &out.provider_cmd, provider_cmd);

    if (parsed.mode_set) out.mode = parsed.mode;
    if (parsed.model) |model| try replaceStr(alloc, &out.model, model);
    if (parsed.provider) |provider| try replaceStr(alloc, &out.provider, provider);
    if (parsed.session_dir) |session_dir| try replaceStr(alloc, &out.session_dir, session_dir);
    if (parsed.provider_cmd) |provider_cmd| try replaceOptStr(alloc, &out.provider_cmd, provider_cmd);

    return out;
}

const FileCfg = struct {
    model: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    session_dir: ?[]const u8 = null,
    mode: ?[]const u8 = null,
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

fn hasFile(dir: std.fs.Dir, path: []const u8) !bool {
    dir.access(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn parseMode(raw: []const u8, comptime invalid: anytype) @TypeOf(invalid)!args.Mode {
    if (std.mem.eql(u8, raw, "tui")) return .tui;
    if (std.mem.eql(u8, raw, "interactive")) return .tui;
    if (std.mem.eql(u8, raw, "print")) return .print;
    if (std.mem.eql(u8, raw, "json")) return .json;
    if (std.mem.eql(u8, raw, "rpc")) return .rpc;
    return invalid;
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
