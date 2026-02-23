const std = @import("std");

const Rule = struct {
    summary: []const u8,
    next: []const u8,
};

const rule_map = std.StaticStringMap(Rule).initComptime(.{
    .{ "SessionDisabled", Rule{
        .summary = "session persistence is disabled",
        .next = "rerun without --no-session and ensure a writable session directory",
    } },
    .{ "SessionNotFound", Rule{
        .summary = "session was not found",
        .next = "run /tree (or rpc tree) to list sessions and retry with an exact id",
    } },
    .{ "AmbiguousSession", Rule{
        .summary = "session id prefix matches multiple sessions",
        .next = "use a longer id prefix or an exact session id",
    } },
    .{ "InvalidSessionPath", Rule{
        .summary = "session path is invalid",
        .next = "pass a .jsonl session file path or valid session id",
    } },
    .{ "FileNotFound", Rule{
        .summary = "file or directory was not found",
        .next = "verify the path exists and retry",
    } },
    .{ "AccessDenied", Rule{
        .summary = "permission denied",
        .next = "grant access to the target path and retry",
    } },
    .{ "ReadOnlyFileSystem", Rule{
        .summary = "target filesystem is read-only",
        .next = "choose a writable location or remount with write access",
    } },
    .{ "ConnectionRefused", Rule{
        .summary = "remote endpoint refused the connection",
        .next = "check network/proxy/firewall settings and retry",
    } },
    .{ "NetworkUnreachable", Rule{
        .summary = "network is unreachable",
        .next = "check internet connectivity and retry",
    } },
    .{ "HostUnreachable", Rule{
        .summary = "host is unreachable",
        .next = "check DNS/network reachability and retry",
    } },
    .{ "ConnectionTimedOut", Rule{
        .summary = "network request timed out",
        .next = "retry after network stabilizes",
    } },
    .{ "TemporaryNameServerFailure", Rule{
        .summary = "DNS lookup failed",
        .next = "check DNS settings and retry",
    } },
    .{ "UnknownArg", Rule{
        .summary = "unknown command-line argument",
        .next = "run pz --help and fix the command",
    } },
    .{ "MissingPrintPrompt", Rule{
        .summary = "print mode requires a prompt",
        .next = "pass text after --print or use --prompt <text>",
    } },
    .{ "MissingPromptValue", Rule{
        .summary = "missing value for --prompt",
        .next = "use --prompt <text>",
    } },
    .{ "MissingSessionValue", Rule{
        .summary = "missing value for --session/--resume",
        .next = "use --session <id|path> or plain -r for latest",
    } },
    .{ "MissingModeValue", Rule{
        .summary = "missing value for --mode",
        .next = "use --mode <tui|print|json|rpc>",
    } },
    .{ "InvalidMode", Rule{
        .summary = "invalid mode value",
        .next = "use one of: tui, print, json, rpc",
    } },
    .{ "InvalidTool", Rule{
        .summary = "invalid tools list",
        .next = "use --tools read,write,bash,edit,grep,find,ls,ask or --no-tools",
    } },
});

fn lookup(err: anyerror) Rule {
    const name = @errorName(err);
    return rule_map.get(name) orelse .{
        .summary = name,
        .next = "retry; if it persists, report this error with context",
    };
}

pub fn short(err: anyerror) []const u8 {
    return lookup(err).summary;
}

pub fn inlineMsg(alloc: std.mem.Allocator, err: anyerror) ![]u8 {
    const name = @errorName(err);
    const r = lookup(err);
    return std.fmt.allocPrint(alloc, "{s} ({s})", .{ r.summary, name });
}

pub fn cli(alloc: std.mem.Allocator, op: []const u8, err: anyerror) ![]u8 {
    const name = @errorName(err);
    const r = lookup(err);
    return std.fmt.allocPrint(
        alloc,
        "error: {s} failed\nreason: {s}\nerror code: {s}\nnext: {s}\n",
        .{ op, r.summary, name, r.next },
    );
}

pub fn rpc(alloc: std.mem.Allocator, op: []const u8, err: anyerror) ![]u8 {
    const name = @errorName(err);
    const r = lookup(err);
    return std.fmt.allocPrint(
        alloc,
        "{s} failed: {s} (error: {s}). next: {s}",
        .{ op, r.summary, name, r.next },
    );
}

test "report maps session disabled to actionable text" {
    const msg = try cli(std.testing.allocator, "resume session", error.SessionDisabled);
    defer std.testing.allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "session persistence is disabled") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "without --no-session") != null);
}

test "report falls back to error name when unknown" {
    const msg = try rpc(std.testing.allocator, "do thing", error.TestUnexpectedResult);
    defer std.testing.allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "TestUnexpectedResult") != null);
}

test "report inline includes summary and code" {
    const msg = try inlineMsg(std.testing.allocator, error.SessionDisabled);
    defer std.testing.allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "session persistence is disabled") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "SessionDisabled") != null);
}
