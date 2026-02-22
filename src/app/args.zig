const std = @import("std");
const core = @import("../core/mod.zig");

pub const Mode = enum {
    tui,
    print,
    json,
    rpc,
};

pub const CfgSel = union(enum) {
    auto,
    off,
    path: []const u8,
};

pub const ThinkingLevel = enum {
    off,
    minimal,
    low,
    medium,
    high,
    xhigh,
    adaptive,

    pub fn toProviderOpts(self: ThinkingLevel) core.providers.Opts {
        return switch (self) {
            .off => .{ .thinking = .off },
            .adaptive => .{ .thinking = .adaptive },
            .minimal => .{ .thinking = .budget, .thinking_budget = 1024 },
            .low => .{ .thinking = .budget, .thinking_budget = 4096 },
            .medium => .{ .thinking = .budget, .thinking_budget = 10240 },
            .high => .{ .thinking = .budget, .thinking_budget = 32768 },
            .xhigh => .{ .thinking = .budget, .thinking_budget = 65536 },
        };
    }
};

pub const Parsed = struct {
    mode: Mode = .tui,
    mode_set: bool = false,
    prompt: ?[]const u8 = null,
    cfg: CfgSel = .auto,
    session: SessionSel = .auto,
    no_session: bool = false,
    tool_mask: u8 = core.tools.builtin.mask_all,
    model: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    session_dir: ?[]const u8 = null,
    provider_cmd: ?[]const u8 = null,
    thinking: ThinkingLevel = .adaptive,
    verbose: bool = false,
    system_prompt: ?[]const u8 = null,
    append_system_prompt: ?[]const u8 = null,
    show_help: bool = false,
    show_version: bool = false,
};

pub const SessionSel = union(enum) {
    auto,
    cont,
    resm,
    explicit: []const u8,
};

pub const ParseError = error{
    UnknownArg,
    UnexpectedPositional,
    MissingModeValue,
    MissingPromptValue,
    MissingConfigValue,
    InvalidMode,
    DuplicateMode,
    ModeConflict,
    DuplicatePrompt,
    DuplicateConfig,
    ConfigConflict,
    PromptOnlyForPrint,
    MissingPrintPrompt,
    MissingSessionValue,
    DuplicateSession,
    SessionConflict,
    DuplicateNoSession,
    SessionNoSessionConflict,
    MissingToolsValue,
    InvalidTool,
    DuplicateTool,
    ToolsConflict,
    MissingModelValue,
    DuplicateModel,
    MissingProviderValue,
    DuplicateProvider,
    MissingSessionDirValue,
    DuplicateSessionDir,
    MissingProviderCmdValue,
    DuplicateProviderCmd,
    MissingThinkingValue,
    InvalidThinking,
    MissingSystemPromptValue,
    MissingAppendSystemPromptValue,
};

pub fn parse(argv: []const []const u8) ParseError!Parsed {
    var out = Parsed{};
    var mode_seen = false;
    var cfg_seen = false;
    var session_seen = false;
    var tools_seen = false;

    const Flag = enum {
        help, version, cont, resm, session, no_session,
        tui, print, mode, prompt, config, no_config,
        no_tools, tools, model, provider, session_dir, provider_cmd,
        thinking, verbose, system_prompt, append_system_prompt,
    };
    const flag_map = std.StaticStringMap(Flag).initComptime(.{
        .{ "-h", .help },
        .{ "--help", .help },
        .{ "-V", .version },
        .{ "--version", .version },
        .{ "-c", .cont },
        .{ "--continue", .cont },
        .{ "-r", .resm },
        .{ "--resume", .resm },
        .{ "--session", .session },
        .{ "--no-session", .no_session },
        .{ "--tui", .tui },
        .{ "--print", .print },
        .{ "-m", .mode },
        .{ "--mode", .mode },
        .{ "-p", .prompt },
        .{ "--prompt", .prompt },
        .{ "-C", .config },
        .{ "--config", .config },
        .{ "--no-config", .no_config },
        .{ "--no-tools", .no_tools },
        .{ "--tools", .tools },
        .{ "--model", .model },
        .{ "--provider", .provider },
        .{ "--session-dir", .session_dir },
        .{ "--provider-cmd", .provider_cmd },
        .{ "--thinking", .thinking },
        .{ "--verbose", .verbose },
        .{ "--system-prompt", .system_prompt },
        .{ "--append-system-prompt", .append_system_prompt },
    });
    const mode_map = std.StaticStringMap(Mode).initComptime(.{
        .{ "tui", .tui },
        .{ "interactive", .tui },
        .{ "print", .print },
        .{ "json", .json },
        .{ "rpc", .rpc },
    });

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const tok = argv[i];

        // Split --flag=value form
        var flag_name = tok;
        var eq_val: ?[]const u8 = null;
        if (std.mem.startsWith(u8, tok, "--")) {
            if (std.mem.indexOfScalar(u8, tok[2..], '=')) |eq| {
                flag_name = tok[0 .. eq + 2];
                eq_val = tok[eq + 3 ..]; // may be empty for --flag=
            }
        }

        if (flag_map.get(flag_name)) |flag| {
            switch (flag) {
                .help => out.show_help = true,
                .version => out.show_version = true,
                .cont => try setSession(&out, &session_seen, .cont),
                .resm => try setSession(&out, &session_seen, .resm),
                .session => {
                    const val = eq_val orelse takeVal(argv, &i) orelse return error.MissingSessionValue;
                    if (val.len == 0) return error.MissingSessionValue;
                    try setSession(&out, &session_seen, .{ .explicit = val });
                },
                .no_session => try setNoSession(&out, session_seen),
                .tui => try setMode(&out, &mode_seen, .tui),
                .print => try setMode(&out, &mode_seen, .print),
                .mode => {
                    const val = eq_val orelse takeVal(argv, &i) orelse return error.MissingModeValue;
                    if (val.len == 0) return error.MissingModeValue;
                    try setMode(&out, &mode_seen, try parseMode(val));
                },
                .prompt => {
                    const val = eq_val orelse takeVal(argv, &i) orelse return error.MissingPromptValue;
                    if (val.len == 0) return error.MissingPromptValue;
                    try setPrompt(&out, val);
                },
                .config => {
                    const val = eq_val orelse takeVal(argv, &i) orelse return error.MissingConfigValue;
                    try setCfg(&out, &cfg_seen, .{ .path = val });
                },
                .no_config => try setCfg(&out, &cfg_seen, .off),
                .no_tools => try setTools(&out, &tools_seen, 0),
                .tools => {
                    const val = eq_val orelse takeVal(argv, &i) orelse return error.MissingToolsValue;
                    if (val.len == 0) return error.MissingToolsValue;
                    try setTools(&out, &tools_seen, try parseToolMask(val));
                },
                .model => {
                    const val = eq_val orelse takeVal(argv, &i) orelse return error.MissingModelValue;
                    if (val.len == 0) return error.MissingModelValue;
                    try setModel(&out, val);
                },
                .provider => {
                    const val = eq_val orelse takeVal(argv, &i) orelse return error.MissingProviderValue;
                    if (val.len == 0) return error.MissingProviderValue;
                    try setProvider(&out, val);
                },
                .session_dir => {
                    const val = eq_val orelse takeVal(argv, &i) orelse return error.MissingSessionDirValue;
                    if (val.len == 0) return error.MissingSessionDirValue;
                    try setSessionDir(&out, val);
                },
                .provider_cmd => {
                    const val = eq_val orelse takeVal(argv, &i) orelse return error.MissingProviderCmdValue;
                    if (val.len == 0) return error.MissingProviderCmdValue;
                    try setProviderCmd(&out, val);
                },
                .thinking => {
                    const val = eq_val orelse takeVal(argv, &i) orelse return error.MissingThinkingValue;
                    if (val.len == 0) return error.MissingThinkingValue;
                    out.thinking = parseThinking(val) orelse return error.InvalidThinking;
                },
                .verbose => out.verbose = true,
                .system_prompt => {
                    const val = eq_val orelse takeVal(argv, &i) orelse return error.MissingSystemPromptValue;
                    if (val.len == 0) return error.MissingSystemPromptValue;
                    out.system_prompt = val;
                },
                .append_system_prompt => {
                    const val = eq_val orelse takeVal(argv, &i) orelse return error.MissingAppendSystemPromptValue;
                    if (val.len == 0) return error.MissingAppendSystemPromptValue;
                    out.append_system_prompt = val;
                },
            }
            continue;
        }

        if (!isOpt(tok)) {
            if (i == 0 and !mode_seen and mode_map.get(tok) != null) {
                try setMode(&out, &mode_seen, try parseMode(tok));
                continue;
            }
            if ((out.mode == .print or out.mode == .json) and out.prompt == null) {
                try setPrompt(&out, tok);
                continue;
            }
            return error.UnexpectedPositional;
        }

        return error.UnknownArg;
    }

    if (out.show_help or out.show_version) return out;
    if (mode_seen and (out.mode == .tui or out.mode == .rpc) and out.prompt != null) return error.PromptOnlyForPrint;
    if (mode_seen and out.mode == .print and out.prompt == null) return error.MissingPrintPrompt;
    return out;
}

fn takeVal(argv: []const []const u8, i: *usize) ?[]const u8 {
    if (i.* + 1 >= argv.len) return null;
    i.* += 1;
    return argv[i.*];
}

fn parseThinking(raw: []const u8) ?ThinkingLevel {
    const map = std.StaticStringMap(ThinkingLevel).initComptime(.{
        .{ "off", .off },
        .{ "none", .off },
        .{ "disabled", .off },
        .{ "minimal", .minimal },
        .{ "min", .minimal },
        .{ "low", .low },
        .{ "medium", .medium },
        .{ "med", .medium },
        .{ "high", .high },
        .{ "xhigh", .xhigh },
        .{ "max", .xhigh },
        .{ "adaptive", .adaptive },
        .{ "auto", .adaptive },
    });
    return map.get(raw);
}

fn isOpt(tok: []const u8) bool {
    return tok.len > 0 and tok[0] == '-';
}

fn parseMode(raw: []const u8) ParseError!Mode {
    const map = std.StaticStringMap(Mode).initComptime(.{
        .{ "tui", .tui },
        .{ "interactive", .tui },
        .{ "print", .print },
        .{ "json", .json },
        .{ "rpc", .rpc },
    });
    return map.get(raw) orelse error.InvalidMode;
}

fn setMode(out: *Parsed, mode_seen: *bool, mode: Mode) ParseError!void {
    if (mode_seen.*) {
        if (out.mode == mode) return error.DuplicateMode;
        return error.ModeConflict;
    }
    mode_seen.* = true;
    out.mode_set = true;
    out.mode = mode;
}

fn setPrompt(out: *Parsed, prompt: []const u8) ParseError!void {
    if (out.prompt != null) return error.DuplicatePrompt;
    out.prompt = prompt;
}

fn setCfg(out: *Parsed, cfg_seen: *bool, cfg: CfgSel) ParseError!void {
    if (cfg_seen.*) {
        if (std.meta.activeTag(out.cfg) == std.meta.activeTag(cfg)) return error.DuplicateConfig;
        return error.ConfigConflict;
    }
    cfg_seen.* = true;
    out.cfg = cfg;
}

fn setSession(out: *Parsed, session_seen: *bool, session: SessionSel) ParseError!void {
    if (out.no_session) return error.SessionNoSessionConflict;
    if (session_seen.*) {
        if (std.meta.activeTag(out.session) == std.meta.activeTag(session)) return error.DuplicateSession;
        return error.SessionConflict;
    }
    session_seen.* = true;
    out.session = session;
}

fn setNoSession(out: *Parsed, session_seen: bool) ParseError!void {
    if (out.no_session) return error.DuplicateNoSession;
    if (session_seen) return error.SessionNoSessionConflict;
    out.no_session = true;
}

fn setTools(out: *Parsed, tools_seen: *bool, mask: u8) ParseError!void {
    if (tools_seen.*) return error.ToolsConflict;
    tools_seen.* = true;
    out.tool_mask = mask;
}

fn parseToolMask(raw: []const u8) ParseError!u8 {
    if (raw.len == 0) return error.MissingToolsValue;

    var mask: u8 = 0;
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t\r\n");
        if (part.len == 0) return error.InvalidTool;

        const bit = core.tools.builtin.maskForName(part) orelse return error.InvalidTool;
        if ((mask & bit) != 0) return error.DuplicateTool;
        mask |= bit;
    }
    return mask;
}

fn setModel(out: *Parsed, model: []const u8) ParseError!void {
    if (out.model != null) return error.DuplicateModel;
    out.model = model;
}

fn setProvider(out: *Parsed, provider: []const u8) ParseError!void {
    if (out.provider != null) return error.DuplicateProvider;
    out.provider = provider;
}

fn setSessionDir(out: *Parsed, session_dir: []const u8) ParseError!void {
    if (out.session_dir != null) return error.DuplicateSessionDir;
    out.session_dir = session_dir;
}

fn setProviderCmd(out: *Parsed, cmd: []const u8) ParseError!void {
    if (out.provider_cmd != null) return error.DuplicateProviderCmd;
    out.provider_cmd = cmd;
}

test "parse defaults to tui and auto config" {
    const out = try parse(&.{});

    try std.testing.expectEqual(Mode.tui, out.mode);
    try std.testing.expect(out.prompt == null);
    try std.testing.expect(std.meta.activeTag(out.cfg) == .auto);
}

test "parse print subcommand positional prompt and config path" {
    const out = try parse(&.{ "print", "hello", "--config", "/tmp/pz.json" });

    try std.testing.expectEqual(Mode.print, out.mode);
    try std.testing.expect(out.prompt != null);
    try std.testing.expect(std.mem.eql(u8, out.prompt.?, "hello"));

    switch (out.cfg) {
        .path => |path| try std.testing.expect(std.mem.eql(u8, path, "/tmp/pz.json")),
        else => return error.TestUnexpectedResult,
    }
}

test "parse long forms with equals syntax" {
    const out = try parse(&.{ "--mode=print", "--prompt=ship-it", "--config=/tmp/pz.toml" });

    try std.testing.expectEqual(Mode.print, out.mode);
    try std.testing.expect(out.prompt != null);
    try std.testing.expect(std.mem.eql(u8, out.prompt.?, "ship-it"));

    switch (out.cfg) {
        .path => |path| try std.testing.expect(std.mem.eql(u8, path, "/tmp/pz.toml")),
        else => return error.TestUnexpectedResult,
    }
}

test "parse no config option" {
    const out = try parse(&.{ "--tui", "--no-config" });

    try std.testing.expectEqual(Mode.tui, out.mode);
    try std.testing.expect(std.meta.activeTag(out.cfg) == .off);
}

test "parse supports json and rpc modes" {
    const json = try parse(&.{ "--mode", "json" });
    try std.testing.expectEqual(Mode.json, json.mode);

    const rpc = try parse(&.{"rpc"});
    try std.testing.expectEqual(Mode.rpc, rpc.mode);
}

test "parse accepts interactive alias for tui mode" {
    const pos = try parse(&.{"interactive"});
    try std.testing.expectEqual(Mode.tui, pos.mode);

    const flag = try parse(&.{ "--mode", "interactive" });
    try std.testing.expectEqual(Mode.tui, flag.mode);
}

test "parse help and version flags" {
    const help = try parse(&.{"--help"});
    try std.testing.expect(help.show_help);
    try std.testing.expect(!help.show_version);

    const ver = try parse(&.{"--version"});
    try std.testing.expect(!ver.show_help);
    try std.testing.expect(ver.show_version);

    const short = try parse(&.{ "-h", "-V" });
    try std.testing.expect(short.show_help);
    try std.testing.expect(short.show_version);
}

test "errors on unknown arg" {
    try std.testing.expectError(error.UnknownArg, parse(&.{"--wat"}));
}

test "errors on unexpected positional in tui mode" {
    try std.testing.expectError(error.UnexpectedPositional, parse(&.{ "tui", "extra" }));
}

test "errors on missing mode value" {
    try std.testing.expectError(error.MissingModeValue, parse(&.{"--mode"}));
}

test "errors on invalid mode value" {
    try std.testing.expectError(error.InvalidMode, parse(&.{ "--mode", "headless" }));
}

test "errors on mode conflict" {
    try std.testing.expectError(error.ModeConflict, parse(&.{ "--tui", "--print" }));
}

test "errors on duplicate mode" {
    try std.testing.expectError(error.DuplicateMode, parse(&.{ "--print", "--mode=print" }));
}

test "errors on missing prompt value" {
    try std.testing.expectError(error.MissingPromptValue, parse(&.{ "--print", "--prompt" }));
}

test "errors on duplicate prompt" {
    try std.testing.expectError(error.DuplicatePrompt, parse(&.{ "--print", "--prompt", "a", "--prompt", "b" }));
}

test "errors when prompt is provided for tui mode" {
    try std.testing.expectError(error.PromptOnlyForPrint, parse(&.{ "--tui", "--prompt", "hello" }));
}

test "errors when print mode has no prompt" {
    try std.testing.expectError(error.MissingPrintPrompt, parse(&.{"--print"}));
}

test "help bypasses prompt requirement checks" {
    const out = try parse(&.{ "--print", "--help" });
    try std.testing.expect(out.show_help);
    try std.testing.expectEqual(Mode.print, out.mode);
    try std.testing.expect(out.prompt == null);
}

test "parse allows prompt when mode is not explicitly set" {
    const out = try parse(&.{ "--prompt", "hello" });
    try std.testing.expectEqual(Mode.tui, out.mode);
    try std.testing.expect(out.prompt != null);
    try std.testing.expectEqualStrings("hello", out.prompt.?);
}

test "errors on missing config value" {
    try std.testing.expectError(error.MissingConfigValue, parse(&.{ "--print", "--prompt", "hi", "--config" }));
}

test "errors on duplicate config path" {
    try std.testing.expectError(
        error.DuplicateConfig,
        parse(&.{ "--print", "--prompt", "hi", "--config", "/a", "--config", "/b" }),
    );
}

test "errors on config conflict" {
    try std.testing.expectError(
        error.ConfigConflict,
        parse(&.{ "--print", "--prompt", "hi", "--config", "/a", "--no-config" }),
    );
}

test "parse accepts session control flags" {
    const cont = try parse(&.{"--continue"});
    try std.testing.expect(std.meta.activeTag(cont.session) == .cont);

    const res = try parse(&.{"-r"});
    try std.testing.expect(std.meta.activeTag(res.session) == .resm);

    const sel = try parse(&.{ "--session", "abc123" });
    switch (sel.session) {
        .explicit => |v| try std.testing.expectEqualStrings("abc123", v),
        else => return error.TestUnexpectedResult,
    }

    const no_session = try parse(&.{"--no-session"});
    try std.testing.expect(no_session.no_session);
}

test "errors on session flag conflicts" {
    try std.testing.expectError(error.MissingSessionValue, parse(&.{"--session"}));
    try std.testing.expectError(error.SessionConflict, parse(&.{ "--continue", "--resume" }));
    try std.testing.expectError(error.SessionNoSessionConflict, parse(&.{ "--continue", "--no-session" }));
    try std.testing.expectError(error.DuplicateNoSession, parse(&.{ "--no-session", "--no-session" }));
}

test "parse accepts tool selection flags" {
    const subset = try parse(&.{ "--tools", "read,bash" });
    try std.testing.expectEqual(
        core.tools.builtin.mask_read | core.tools.builtin.mask_bash,
        subset.tool_mask,
    );

    const none = try parse(&.{"--no-tools"});
    try std.testing.expectEqual(@as(u8, 0), none.tool_mask);
}

test "errors on tool selection conflicts and invalid values" {
    try std.testing.expectError(error.MissingToolsValue, parse(&.{"--tools"}));
    try std.testing.expectError(error.InvalidTool, parse(&.{ "--tools", "read,wat" }));
    try std.testing.expectError(error.DuplicateTool, parse(&.{ "--tools", "read,read" }));
    try std.testing.expectError(error.ToolsConflict, parse(&.{ "--no-tools", "--tools", "read" }));
}

test "parse accepts model and provider command overrides" {
    const out = try parse(&.{ "--model", "m-x", "--provider", "p-x", "--session-dir", "/tmp/s", "--provider-cmd", "echo ok" });
    try std.testing.expect(out.model != null);
    try std.testing.expectEqualStrings("m-x", out.model.?);
    try std.testing.expect(out.provider != null);
    try std.testing.expectEqualStrings("p-x", out.provider.?);
    try std.testing.expect(out.session_dir != null);
    try std.testing.expectEqualStrings("/tmp/s", out.session_dir.?);
    try std.testing.expect(out.provider_cmd != null);
    try std.testing.expectEqualStrings("echo ok", out.provider_cmd.?);
}

test "errors on duplicate and missing model or provider command args" {
    try std.testing.expectError(error.MissingModelValue, parse(&.{"--model"}));
    try std.testing.expectError(error.DuplicateModel, parse(&.{ "--model", "a", "--model", "b" }));
    try std.testing.expectError(error.MissingProviderValue, parse(&.{"--provider"}));
    try std.testing.expectError(error.DuplicateProvider, parse(&.{ "--provider", "a", "--provider", "b" }));
    try std.testing.expectError(error.MissingSessionDirValue, parse(&.{"--session-dir"}));
    try std.testing.expectError(error.DuplicateSessionDir, parse(&.{ "--session-dir", "a", "--session-dir", "b" }));
    try std.testing.expectError(error.MissingProviderCmdValue, parse(&.{"--provider-cmd"}));
    try std.testing.expectError(
        error.DuplicateProviderCmd,
        parse(&.{ "--provider-cmd", "a", "--provider-cmd", "b" }),
    );
}
