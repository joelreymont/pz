const std = @import("std");
const Args = @import("args.zig");
const config = @import("config.zig");

pub const version = "0.0.0";

pub const ParseError = Args.ParseError || config.Err;

pub const Run = struct {
    mode: Args.Mode,
    prompt: ?[]const u8,
    cfg: config.Config,
    session: Args.SessionSel = .auto,
    no_session: bool = false,
    tool_mask: u8 = @import("../core/mod.zig").tools.builtin.mask_all,
    thinking: Args.ThinkingLevel = .adaptive,
    verbose: bool = false,
    system_prompt: ?[]const u8 = null,
    append_system_prompt: ?[]const u8 = null,
    max_turns: u16 = 0,
};

pub const Command = union(enum) {
    help: []const u8,
    version: []const u8,
    run: Run,

    pub fn deinit(self: *Command, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .run => |*run| run.cfg.deinit(alloc),
            else => {},
        }
        self.* = undefined;
    }
};

pub fn parse(
    alloc: std.mem.Allocator,
    dir: std.fs.Dir,
    argv: []const []const u8,
    env: config.Env,
) ParseError!Command {
    const parsed = try Args.parse(argv);

    if (parsed.show_help) return .{ .help = help_text };
    if (parsed.show_version) return .{ .version = version_text };

    var cfg = try config.discover(alloc, dir, parsed, env);
    errdefer cfg.deinit(alloc);
    const mode = selectMode(parsed, cfg);
    if (mode == .print and parsed.prompt == null) return error.MissingPrintPrompt;

    return .{
        .run = .{
            .mode = mode,
            .prompt = parsed.prompt,
            .cfg = cfg,
            .session = parsed.session,
            .no_session = parsed.no_session,
            .tool_mask = parsed.tool_mask,
            .thinking = parsed.thinking,
            .verbose = parsed.verbose,
            .system_prompt = parsed.system_prompt,
            .append_system_prompt = parsed.append_system_prompt,
            .max_turns = parsed.max_turns,
        },
    };
}

pub fn selectMode(parsed: Args.Parsed, cfg: config.Config) Args.Mode {
    if (parsed.mode_set) return parsed.mode;
    return cfg.mode;
}

pub const help_text =
    \\Usage: pz [OPTIONS] [tui|interactive|print|json|rpc]
    \\
    \\Modes:
    \\  tui                         Interactive terminal mode (default)
    \\  interactive                 Alias for tui
    \\  print <PROMPT>              Headless print mode
    \\  json <PROMPT>               Headless JSONL events mode
    \\  rpc                         JSON-RPC over stdin/stdout
    \\
    \\Options:
    \\  -m, --mode <tui|interactive|print|json|rpc>
    \\                             Select mode
    \\  -p, --prompt <TEXT>         Prompt text (print/json modes)
    \\  -C, --config <PATH>         Config file path
    \\      --no-config             Disable config file loading
    \\  -c, --continue              Continue most recent session
    \\  -r, --resume                Resume most recent session
    \\      --session <ID|PATH>     Use a specific session ID or .jsonl path
    \\      --no-session            Disable session persistence
    \\      --model <MODEL>         Override model id
    \\      --provider <PROVIDER>   Override provider id
    \\      --session-dir <PATH>    Override session directory
    \\      --provider-cmd <CMD>    Override provider transport command
    \\      --tools <LIST>          Enable tool subset (read,write,bash,edit,grep,find,ls)
    \\      --no-tools              Disable all built-in tools
    \\      --thinking <LEVEL>      Thinking mode (off,minimal,low,medium,high,xhigh,adaptive)
    \\      --max-turns <N>          Limit agent loop turns (0=unlimited)
    \\      --verbose               Show metadata in print mode
    \\      --system-prompt <TEXT>   Override system prompt
    \\      --append-system-prompt <TEXT>
    \\                             Append to system prompt
    \\  -h, --help                  Show help
    \\  -V, --version               Show version
;

pub const version_text = "pz " ++ version ++ "\n";

test "cli returns help and version commands" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var help_cmd = try parse(std.testing.allocator, tmp.dir, &.{"--help"}, .{});
    defer help_cmd.deinit(std.testing.allocator);
    switch (help_cmd) {
        .help => |txt| try std.testing.expect(std.mem.indexOf(u8, txt, "Usage: pz") != null),
        else => return error.TestUnexpectedResult,
    }

    var ver_cmd = try parse(std.testing.allocator, tmp.dir, &.{"--version"}, .{});
    defer ver_cmd.deinit(std.testing.allocator);
    switch (ver_cmd) {
        .version => |txt| try std.testing.expectEqualStrings(version_text, txt),
        else => return error.TestUnexpectedResult,
    }
}

test "cli mode dispatch uses config mode when mode flag absent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = config.auto_cfg_path,
        .data = "{\"mode\":\"print\"}",
    });

    var cmd = try parse(std.testing.allocator, tmp.dir, &.{ "--prompt", "ship" }, .{});
    defer cmd.deinit(std.testing.allocator);

    switch (cmd) {
        .run => |run| {
            try std.testing.expect(run.mode == .print);
            try std.testing.expect(run.prompt != null);
            try std.testing.expectEqualStrings("ship", run.prompt.?);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "cli mode dispatch applies mode flag over config and env" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = config.auto_cfg_path,
        .data = "{\"mode\":\"print\"}",
    });

    var cmd = try parse(std.testing.allocator, tmp.dir, &.{"--tui"}, .{
        .mode = "print",
    });
    defer cmd.deinit(std.testing.allocator);

    switch (cmd) {
        .run => |run| try std.testing.expect(run.mode == .tui),
        else => return error.TestUnexpectedResult,
    }
}

test "cli propagates session and tool selections to run command" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cmd = try parse(std.testing.allocator, tmp.dir, &.{ "--continue", "--tools", "read,bash" }, .{});
    defer cmd.deinit(std.testing.allocator);

    switch (cmd) {
        .run => |run| {
            try std.testing.expect(std.meta.activeTag(run.session) == .cont);
            try std.testing.expect(!run.no_session);
            try std.testing.expectEqual(
                @import("../core/mod.zig").tools.builtin.mask_read |
                    @import("../core/mod.zig").tools.builtin.mask_bash,
                run.tool_mask,
            );
        },
        else => return error.TestUnexpectedResult,
    }
}
