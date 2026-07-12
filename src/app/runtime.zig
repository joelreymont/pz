//! Runtime orchestration: wire providers, tools, and modes together.
const builtin = @import("builtin");
const std = @import("std");
const cli = @import("cli.zig");
const bg = @import("bg.zig");
const activity = @import("activity.zig");
const changelog = @import("changelog.zig");
const report = @import("report.zig");
const update_mod = @import("update.zig");
const version_check = @import("version.zig");
const config = @import("config.zig");
const core = @import("../core.zig");
const core_skill = @import("../core/skill.zig");
const summary_types = @import("../core/session/summary.zig");
const print_fmt = @import("../modes/print/format.zig");
const print_err = @import("../modes/print/errors.zig");
const tui_harness = @import("../modes/tui/harness.zig");
const tui_render = @import("../modes/tui/render.zig");
const tui_term = @import("../modes/tui/term.zig");
const tui_transcript = @import("../modes/tui/transcript.zig");
const tui_input = @import("../modes/tui/input.zig");
const tui_editor = @import("../modes/tui/editor.zig");
const tui_frame = @import("../modes/tui/frame.zig");
const tui_theme = @import("../modes/tui/theme.zig");
const tui_overlay = @import("../modes/tui/overlay.zig");
const tui_panels = @import("../modes/tui/panels.zig");
const tui_ask = @import("../modes/tui/ask.zig");
const utf8 = @import("../core/utf8.zig");
const tui_path_complete = @import("../modes/tui/path_complete.zig");
const args_mod = @import("args.zig");
const path_guard = @import("../core/tools/path_guard.zig");
const event_loop = @import("../core/event_loop.zig");
const audit_e2e = @import("../test/audit_e2e.zig");
const provider_mock = @import("../test/provider_mock.zig");
const syslog_mock = @import("../test/syslog_mock.zig");

pub const Err = error{
    SessionNotFound,
    AmbiguousSession,
    InvalidSessionPath,
    TerminalSetupFailed,
    InvalidSyslogTransport,
    AuditSpoolSetup,
};

const ProcMapCtx = struct {
    pub fn map(_: *@This(), err: anyerror) core.providers.types.Err {
        if (err == error.Timeout or err == error.WireBreak) return error.TransportTransient;
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return error.TransportFatal;
    }
};

const ProcTr = core.providers.proc_transport.Transport;
const ProcClient = core.providers.client.Client(ProcTr, ProcMapCtx, core.providers.client.VoidSleeper);

const ProviderRuntime = struct {
    tr: ProcTr,
    map_ctx: ProcMapCtx = .{},
    pol: core.providers.client.Policy = undefined,
    client: ProcClient = undefined,

    fn init(self: *ProviderRuntime, alloc: std.mem.Allocator, io: std.Io, provider_cmd: []const u8) !void {
        self.tr = try ProcTr.init(.{
            .alloc = alloc,
            .io = io,
            .cmd = provider_cmd,
        });
        self.map_ctx = .{};
        self.pol = try core.providers.client.Policy.init(.{
            .max_tries = 4,
            .backoff = .{
                .base_ms = 2000,
                .max_ms = 60000,
                .mul = 2,
            },
            .retryable = core.providers.types.retryable,
        });
        self.client = ProcClient.init(
            alloc,
            &self.tr,
            &self.map_ctx,
            self.pol,
        );
    }

    fn deinit(self: *ProviderRuntime) void {
        self.tr.deinit();
        self.* = undefined;
    }
};

// Native fast-path kinds plus the OpenAI-compatible providers routed through the
// dynamic arm. `anthropic`/`openai` keep their hand-wired native clients; every
// other tag resolves to a `core.providers.*` SseClient dispatched via the
// router (MP7). The set mirrors `registry.ProviderTag` so every registered
// provider has a runtime construction path — no provider falls through.
const NativeProviderKind = enum {
    anthropic,
    openai,
    openrouter,
    google,
    mistral,
    groq,
    deepseek,
};
const native_provider_kind_map = std.StaticStringMap(NativeProviderKind).initComptime(.{
    .{ "anthropic", .anthropic },
    .{ "openai", .openai },
    .{ "openrouter", .openrouter },
    .{ "google", .google },
    .{ "mistral", .mistral },
    .{ "groq", .groq },
    .{ "deepseek", .deepseek },
});

fn parseNativeProviderKind(provider: []const u8) ?NativeProviderKind {
    return native_provider_kind_map.get(provider);
}

// The OpenAI-compatible provider kinds handled by the dynamic arm. anthropic and
// openai are the native fast paths and are excluded here.
const DynamicKind = enum {
    openrouter,
    google,
    mistral,
    groq,
    deepseek,

    fn fromNative(kind: NativeProviderKind) ?DynamicKind {
        return switch (kind) {
            .anthropic, .openai => null,
            .openrouter => .openrouter,
            .google => .google,
            .mistral => .mistral,
            .groq => .groq,
            .deepseek => .deepseek,
        };
    }

    /// Canonical registry/auth name for this provider. Used by the router lookup
    /// to match the dispatch-resolved provider name to this single backend.
    fn name(self: DynamicKind) []const u8 {
        return switch (self) {
            .openrouter => "openrouter",
            .google => "google",
            .mistral => "mistral",
            .groq => "groq",
            .deepseek => "deepseek",
        };
    }

    /// Auth tag used for credential reload after a login. Mirrors each module's
    /// `Cfg.provider_tag` so reloadAuth fetches the same credential the client
    /// was constructed with.
    fn authTag(self: DynamicKind) core.providers.auth.Provider {
        return switch (self) {
            // openrouter/groq/deepseek reuse the `.openai` auth identity (their
            // Cfg.provider_tag is `.openai`); google has its own identity.
            .openrouter, .groq, .deepseek, .mistral => .openai,
            .google => .google,
        };
    }
};

// One OpenAI-compatible backend client, plus a router that dispatches requests
// to it by resolved provider name (MP7). The router never falls back: a request
// whose resolved provider does not match this backend surfaces `error.NoBackend`
// (or a named dispatch error from `resolveDispatch`), never a silent reroute.
const DynamicProvider = struct {
    kind: DynamicKind,
    backend: Backend,
    router: core.providers.client.Router = undefined,
    router_ready: bool = false,

    const Backend = union(DynamicKind) {
        openrouter: core.providers.openrouter.Client,
        google: core.providers.google.Client,
        mistral: core.providers.mistral.Client,
        groq: core.providers.groq.Client,
        deepseek: core.providers.deepseek.Client,
    };

    fn init(alloc: std.mem.Allocator, kind: DynamicKind, hooks: core.providers.auth.Hooks) !DynamicProvider {
        const backend: Backend = switch (kind) {
            .openrouter => .{ .openrouter = try core.providers.openrouter.Client.init(alloc, hooks) },
            .google => .{ .google = try core.providers.google.Client.init(alloc, hooks) },
            .mistral => .{ .mistral = try core.providers.mistral.Client.init(alloc, hooks) },
            .groq => .{ .groq = try core.providers.groq.Client.init(alloc, hooks) },
            .deepseek => .{ .deepseek = try core.providers.deepseek.Client.init(alloc, hooks) },
        };
        return .{ .kind = kind, .backend = backend };
    }

    /// Backend `*Provider` for the active client. Single source the router
    /// forwards to once the resolved name matches `self.kind`.
    fn backendProvider(self: *DynamicProvider) *core.providers.Provider {
        return switch (self.backend) {
            inline else => |*client| &client.provider,
        };
    }

    /// Router lookup: forward only when the dispatch-resolved provider name is
    /// exactly this backend's provider. Any other (still-registered) provider
    /// returns null → `Router` raises `error.NoBackend`. No fallback.
    fn lookup(self: *DynamicProvider, lookup_name: []const u8) ?*core.providers.Provider {
        if (std.mem.eql(u8, lookup_name, self.kind.name())) return self.backendProvider();
        return null;
    }

    /// Bind the router to this (stable) address and return its `*Provider`. Safe
    /// to call repeatedly; the binding is recomputed against the current address
    /// so it survives the move from the init temporary into `native_rt`.
    fn providerPtr(self: *DynamicProvider) *core.providers.Provider {
        self.router = core.providers.client.Router.init(
            core.providers.client.DynamicCfg.from(DynamicProvider, self, DynamicProvider.lookup),
        );
        self.router_ready = true;
        return &self.router.provider;
    }

    fn setEventLoop(self: *DynamicProvider, el: *event_loop.EventLoop) void {
        switch (self.backend) {
            inline else => |*client| client.el = el,
        }
    }

    fn setCancel(self: *DynamicProvider, cancel: *core.providers.CancelPoll) void {
        switch (self.backend) {
            inline else => |*client| client.cancel = cancel,
        }
    }

    fn clearCancel(self: *DynamicProvider) void {
        switch (self.backend) {
            inline else => |*client| client.cancel = null,
        }
    }

    fn expiredOAuthProvider(self: *DynamicProvider) ?core.providers.auth.Provider {
        const auth = switch (self.backend) {
            inline else => |*client| client.auth.auth,
        };
        switch (auth) {
            .oauth => |oauth| {
                if (core.time.milliTimestamp() >= oauth.expires) return self.kind.authTag();
            },
            else => {},
        }
        return null;
    }

    fn reloadAuth(self: *DynamicProvider, alloc: std.mem.Allocator, hooks: core.providers.auth.Hooks) !void {
        const new_auth = try core.providers.auth.loadForProviderWithHooks(alloc, self.kind.authTag(), hooks);
        switch (self.backend) {
            inline else => |*client| {
                client.auth.deinit();
                client.auth = new_auth;
            },
        }
    }

    fn isSub(self: *const DynamicProvider) bool {
        return switch (self.backend) {
            inline else => |client| client.isSub(),
        };
    }

    fn deinit(self: *DynamicProvider) void {
        switch (self.backend) {
            inline else => |*client| client.deinit(),
        }
        self.* = undefined;
    }
};

fn parseSyslogTransport(s: []const u8) ?core.syslog.Transport {
    if (std.mem.eql(u8, s, "udp")) return .udp;
    if (std.mem.eql(u8, s, "tcp")) return .tcp;
    if (std.mem.eql(u8, s, "tls")) return .tls;
    return null;
}

// The runtime's provider home: native anthropic/openai fast paths plus one
// `dynamic_provider` arm that wraps an OpenAI-compatible client behind the
// dispatch router (MP7). EVERY switch below covers ALL THREE arms — there is no
// `unreachable`, no `else =>`, and no panic. Adding a union arm is a build error
// until each switch handles it.
const NativeProviderRuntime = union(enum) {
    anthropic: core.providers.anthropic.Client,
    openai: core.providers.openai.Client,
    dynamic_provider: DynamicProvider,

    fn init(alloc: std.mem.Allocator, kind: NativeProviderKind, hooks: core.providers.auth.Hooks) !NativeProviderRuntime {
        return switch (kind) {
            .anthropic => .{ .anthropic = try core.providers.anthropic.Client.init(alloc, hooks) },
            .openai => .{ .openai = try core.providers.openai.Client.init(alloc, hooks) },
            // Any non-native kind constructs the dynamic arm. `fromNative`
            // returns a concrete DynamicKind for exactly these tags, so the
            // `orelse` branch is unreachable-by-construction yet still surfaces a
            // named error instead of `unreachable` if the maps ever diverge.
            .openrouter, .google, .mistral, .groq, .deepseek => blk: {
                const dyn_kind = DynamicKind.fromNative(kind) orelse return error.UnsupportedProvider;
                break :blk .{ .dynamic_provider = try DynamicProvider.init(alloc, dyn_kind, hooks) };
            },
        };
    }

    fn setEventLoop(self: *NativeProviderRuntime, el: *event_loop.EventLoop) void {
        switch (self.*) {
            .anthropic => |*client| client.el = el,
            .openai => |*client| client.el = el,
            .dynamic_provider => |*dyn| dyn.setEventLoop(el),
        }
    }

    fn setCancel(self: *NativeProviderRuntime, cancel: *core.providers.CancelPoll) void {
        switch (self.*) {
            .anthropic => |*client| client.cancel = cancel,
            .openai => |*client| client.cancel = cancel,
            .dynamic_provider => |*dyn| dyn.setCancel(cancel),
        }
    }

    fn clearCancel(self: *NativeProviderRuntime) void {
        switch (self.*) {
            .anthropic => |*client| client.cancel = null,
            .openai => |*client| client.cancel = null,
            .dynamic_provider => |*dyn| dyn.clearCancel(),
        }
    }

    /// Returns the provider tag if the current auth is expired OAuth.
    fn expiredOAuthProvider(self: *NativeProviderRuntime) ?core.providers.auth.Provider {
        return switch (self.*) {
            .anthropic => |*c| oauthExpiredTag(c.auth.auth, .anthropic),
            .openai => |*c| oauthExpiredTag(c.auth.auth, .openai),
            .dynamic_provider => |*dyn| dyn.expiredOAuthProvider(),
        };
    }

    /// Replace auth after a successful login flow.
    fn reloadAuth(self: *NativeProviderRuntime, alloc: std.mem.Allocator, hooks: core.providers.auth.Hooks) !void {
        switch (self.*) {
            .anthropic => |*c| {
                const new_auth = try core.providers.auth.loadForProviderWithHooks(alloc, .anthropic, hooks);
                c.auth.deinit();
                c.auth = new_auth;
            },
            .openai => |*c| {
                const new_auth = try core.providers.auth.loadForProviderWithHooks(alloc, .openai, hooks);
                c.auth.deinit();
                c.auth = new_auth;
            },
            .dynamic_provider => |*dyn| try dyn.reloadAuth(alloc, hooks),
        }
    }

    fn providerPtr(self: *NativeProviderRuntime) *core.providers.Provider {
        return switch (self.*) {
            .anthropic => |*client| &client.provider,
            .openai => |*client| &client.provider,
            .dynamic_provider => |*dyn| dyn.providerPtr(),
        };
    }

    fn isSub(self: *const NativeProviderRuntime) bool {
        return switch (self.*) {
            .anthropic => |client| client.isSub(),
            .openai => |client| client.isSub(),
            .dynamic_provider => |dyn| dyn.isSub(),
        };
    }

    fn deinit(self: *NativeProviderRuntime) void {
        switch (self.*) {
            .anthropic => |*client| client.deinit(),
            .openai => |*client| client.deinit(),
            .dynamic_provider => |*dyn| dyn.deinit(),
        }
        self.* = undefined;
    }
};

/// Map an auth value to its expired-OAuth tag, or null if the auth is not an
/// expired OAuth token. Shared by the native arms so the expiry check stays
/// identical across providers.
fn oauthExpiredTag(auth: core.providers.auth.Auth, tag: core.providers.auth.Provider) ?core.providers.auth.Provider {
    switch (auth) {
        .oauth => |oauth| {
            if (core.time.milliTimestamp() >= oauth.expires) return tag;
        },
        else => {},
    }
    return null;
}

const missing_provider_msg = "direct provider runtimes are disabled by policy; set --provider-cmd/PZ_PROVIDER_CMD to an approved CLI adapter";
const missing_anthropic_provider_msg = missing_provider_msg;
const missing_openai_provider_msg = missing_provider_msg;
const missing_openrouter_provider_msg = missing_provider_msg;
const missing_google_provider_msg = missing_provider_msg;
const missing_mistral_provider_msg = missing_provider_msg;
const missing_groq_provider_msg = missing_provider_msg;
const missing_deepseek_provider_msg = missing_provider_msg;
const direct_provider_login_disabled_msg = "direct provider login disabled by policy; configure PZ_PROVIDER_CMD with an approved CLI adapter\n";
const unsupported_native_provider_msg = "native provider unavailable for this provider label; " ++
    "set --provider-cmd/PZ_PROVIDER_CMD to an approved CLI adapter";
const policy_denied_msg = "blocked by policy";

fn missingProviderMsgForInitErr(kind: NativeProviderKind, err: anyerror) []const u8 {
    const auth_missing = err == error.AuthNotFound;
    return switch (kind) {
        .anthropic => if (auth_missing) missing_anthropic_provider_msg else missing_provider_msg,
        .openai => if (auth_missing) missing_openai_provider_msg else missing_provider_msg,
        .openrouter => if (auth_missing) missing_openrouter_provider_msg else missing_provider_msg,
        .google => if (auth_missing) missing_google_provider_msg else missing_provider_msg,
        .mistral => if (auth_missing) missing_mistral_provider_msg else missing_provider_msg,
        .groq => if (auth_missing) missing_groq_provider_msg else missing_provider_msg,
        .deepseek => if (auth_missing) missing_deepseek_provider_msg else missing_provider_msg,
    };
}

const RuntimePolicy = struct {
    alloc: std.mem.Allocator,
    resolved: core.policy.Resolved,

    fn load(alloc: std.mem.Allocator, io: std.Io, home: ?[]const u8) !RuntimePolicy {
        const cwd = try std.process.currentPathAlloc(io, alloc);
        defer alloc.free(cwd);
        return .{
            .alloc = alloc,
            .resolved = try core.policy.loadResolved(alloc, io, cwd, home),
        };
    }

    fn deinit(self: *RuntimePolicy) void {
        core.policy.deinitResolved(self.alloc, self.resolved);
        self.* = undefined;
    }

    fn hash(self: *const RuntimePolicy) []const u8 {
        return self.resolved.hash_hex[0..];
    }

    fn bind(self: *const RuntimePolicy) core.policy.ApprovalBind {
        return self.resolved.bind();
    }

    fn enforced(self: *const RuntimePolicy) bool {
        return self.resolved.has_files;
    }

    fn locked(self: *const RuntimePolicy) bool {
        return self.resolved.locked;
    }

    fn allows(self: *const RuntimePolicy, path: []const u8, tool: ?[]const u8) bool {
        if (!self.enforced()) return true;
        return core.policy.evaluate(self.resolved.doc.rules, path, tool) == .allow;
    }

    fn allowsCmd(self: *const RuntimePolicy, name: []const u8) bool {
        var buf: [128]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "runtime/cmd/{s}", .{name}) catch return false;
        return self.allows(path, null);
    }

    fn allowsSubagent(self: *const RuntimePolicy, agent_id: []const u8) bool {
        var buf: [128]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "runtime/subagent/{s}", .{agent_id}) catch return false;
        return self.allows(path, null);
    }

    fn allowsTool(self: *const RuntimePolicy, name: []const u8, call: core.tools.Call) bool {
        var buf: [256]u8 = undefined;
        const path = toolPolicyPath(&buf, name, call) catch return false;
        return self.allows(path, name);
    }

    fn allowsToolKind(self: *const RuntimePolicy, name: []const u8, call: core.tools.Call, kind_str: []const u8) bool {
        if (!self.enforced()) return true;
        var buf: [256]u8 = undefined;
        const path = toolPolicyPath(&buf, name, call) catch return false;
        return core.policy.evaluateKind(self.resolved.doc.rules, path, name, kind_str) == .allow;
    }

    fn allowsCmdKind(self: *const RuntimePolicy, name: []const u8, tool: ?[]const u8, kind: ?[]const u8) bool {
        if (!self.enforced()) return true;
        var buf: [128]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "cmd/{s}", .{name}) catch return false;
        return core.policy.evaluateKind(self.resolved.doc.rules, path, tool, kind) == .allow;
    }
};

fn toolPolicyPath(buf: *[256]u8, name: []const u8, call: core.tools.Call) ![]const u8 {
    return switch (call.args) {
        .read => |args| args.path,
        .write => |args| args.path,
        .bash => |args| args.cwd orelse try std.fmt.bufPrint(buf, "runtime/tool/{s}", .{name}),
        .edit => |args| args.path,
        .grep => |args| args.path,
        .find => |args| args.path,
        .ls => |args| args.path,
        .agent => |args| try std.fmt.bufPrint(buf, "runtime/subagent/{s}", .{args.agent_id}),
        .web => try std.fmt.bufPrint(buf, "runtime/tool/{s}", .{name}),
        .ask => try std.fmt.bufPrint(buf, "runtime/tool/{s}", .{name}),
        .skill => |args| try std.fmt.bufPrint(buf, "runtime/skill/{s}", .{args.name}),
    };
}

const PolicyToolDispatch = struct {
    dispatch: core.tools.Dispatch = .{ .vt = &Bind.vt },
    pol: *const RuntimePolicy,
    name: []const u8,
    audit: ?PolicyToolAudit = null,
    inner: *core.tools.Dispatch,

    const Bind = core.tools.Dispatch.Bind(@This(), run);

    fn run(self: *@This(), call: core.tools.Call, sink: *core.tools.Sink) !core.tools.Result {
        if (!self.pol.allowsTool(self.name, call)) {
            if (self.audit) |audit| try audit.emit(call, self.name);
            return .{
                .call_id = call.id,
                .started_at_ms = call.at_ms,
                .ended_at_ms = call.at_ms,
                .out = &.{},
                .final = .{
                    .failed = .{
                        .kind = .denied,
                        .msg = policy_denied_msg,
                    },
                },
            };
        }
        return self.inner.run(call, sink);
    }
};

const PolicyToolRegistry = struct {
    const max_tools = 16;
    ctxs: [max_tools]PolicyToolDispatch = undefined,
    entries: [max_tools]core.tools.Entry = undefined,
    reg: core.tools.Registry = undefined,

    fn init(self: *PolicyToolRegistry, pol: *const RuntimePolicy, base: core.tools.Registry, audit: ?PolicyToolAudit) void {
        for (base.entries, 0..) |entry, i| {
            self.ctxs[i] = .{
                .pol = pol,
                .name = entry.name,
                .audit = audit,
                .inner = entry.dispatch,
            };
            self.entries[i] = entry;
            self.entries[i].dispatch = &self.ctxs[i].dispatch;
        }
        self.reg = core.tools.Registry.init(self.entries[0..base.entries.len]);
    }

    fn registry(self: *const PolicyToolRegistry) core.tools.Registry {
        return self.reg;
    }
};

const PolicyToolAuth = struct {
    tool_auth: core.loop.ToolAuth = .{ .vt = &core.loop.ToolAuth.Bind(@This(), @This().check).vt },
    alloc: std.mem.Allocator,
    pol: *const RuntimePolicy,
    sid: []const u8,
    audit_emitter: ?*core.audit.Emitter = null,
    now_ms: *const fn () i64 = core.time.milliTimestamp,
    seq: *u64,

    fn check(self: *@This(), call_id: []const u8, name: []const u8, kind: core.tools.Kind, kind_str: []const u8, parsed_args: core.tools.Call.Args) !void {
        const call: core.tools.Call = .{
            .id = "",
            .kind = kind,
            .args = parsed_args,
            .src = .model,
            .at_ms = 0,
            .cancel = null,
        };
        if (!self.pol.allowsToolKind(name, call, kind_str)) {
            try self.emitDeny(call_id, name, kind, parsed_args);
            return error.PolicyDenied;
        }
    }

    fn emitDeny(self: *@This(), call_id: []const u8, name: []const u8, kind: core.tools.Kind, parsed_args: core.tools.Call.Args) !void {
        const e = self.audit_emitter orelse return;
        const seq = self.seq.*;
        self.seq.* +%= 1;
        const info = toolAuditInfo(kind, parsed_args);
        try e.emit(self.alloc, .{
            .ts_ms = self.now_ms(),
            .sid = self.sid,
            .seq = seq,
            .severity = .warn,
            .outcome = .deny,
            .actor = .{
                .kind = .tool,
                .id = .{ .text = name, .vis = .@"pub" },
            },
            .res = .{
                .kind = info.res_kind,
                .name = .{ .text = info.target, .vis = .mask },
                .op = info.op,
            },
            .msg = .{ .text = "policy denied", .vis = .@"pub" },
            .data = .{
                .tool = .{
                    .name = .{ .text = name, .vis = .@"pub" },
                    .call_id = call_id,
                    .argv = .{ .text = info.argv, .vis = .mask },
                },
            },
        });
    }
};

const ToolAuditInfo = struct {
    res_kind: core.audit.ResourceKind,
    op: []const u8,
    target: []const u8,
    argv: []const u8,
};

fn toolAuditInfo(kind: core.tools.Kind, parsed_args: core.tools.Call.Args) ToolAuditInfo {
    return switch (kind) {
        .read => .{ .res_kind = .file, .op = "read", .target = parsed_args.read.path, .argv = parsed_args.read.path },
        .write => .{ .res_kind = .file, .op = "write", .target = parsed_args.write.path, .argv = parsed_args.write.path },
        .bash => .{ .res_kind = .cmd, .op = "exec", .target = parsed_args.bash.cmd, .argv = parsed_args.bash.cmd },
        .edit => .{ .res_kind = .file, .op = "edit", .target = parsed_args.edit.path, .argv = parsed_args.edit.path },
        .grep => .{ .res_kind = .file, .op = "grep", .target = parsed_args.grep.path, .argv = parsed_args.grep.pattern },
        .find => .{ .res_kind = .file, .op = "find", .target = parsed_args.find.path, .argv = parsed_args.find.name },
        .ls => .{ .res_kind = .file, .op = "list", .target = parsed_args.ls.path, .argv = parsed_args.ls.path },
        .agent => .{ .res_kind = .cmd, .op = "run", .target = parsed_args.agent.agent_id, .argv = parsed_args.agent.agent_id },
        .web => .{ .res_kind = .net, .op = "request", .target = parsed_args.web.url, .argv = parsed_args.web.url },
        .ask => .{ .res_kind = .cfg, .op = "ask", .target = "ask", .argv = "ask" },
        .skill => .{ .res_kind = .cmd, .op = "run", .target = parsed_args.skill.name, .argv = parsed_args.skill.name },
    };
}

fn initSubagentStub(pol: *const RuntimePolicy, agent_id: []const u8) !core.agent.Stub {
    if (!pol.allowsSubagent(agent_id)) return error.PolicyDenied;
    return try core.agent.Stub.init(agent_id, pol.hash());
}

const MissingProvider = struct {
    provider: core.providers.Provider = .{ .vt = &core.providers.Provider.Bind(@This(), @This().start).vt },
    alloc: std.mem.Allocator,
    msg: []const u8 = missing_provider_msg,

    fn start(self: *MissingProvider, _: core.providers.Request) !*core.providers.Stream {
        const stream = try self.alloc.create(MissingProviderStream);
        stream.* = .{
            .alloc = self.alloc,
            .msg = self.msg,
        };
        return &stream.stream;
    }
};

const MissingProviderStream = struct {
    stream: core.providers.Stream = .{ .vt = &core.providers.Stream.Bind(@This(), @This().next, @This().deinit).vt },
    alloc: std.mem.Allocator,
    msg: []const u8,
    idx: u8 = 0,

    fn next(self: *MissingProviderStream) !?core.providers.Event {
        defer self.idx +|= 1;

        return switch (self.idx) {
            0 => .{ .err = self.msg },
            1 => .{
                .stop = .{ .reason = .err },
            },
            else => null,
        };
    }

    fn deinit(self: *MissingProviderStream) void {
        self.alloc.destroy(self);
    }
};

const PrintSink = struct {
    mode_sink: core.loop.ModeSink = .{ .vt = &core.loop.ModeSink.Bind(@This(), @This().push).vt },
    fmt: print_fmt.Formatter,
    stop_reason: ?core.providers.StopReason = null,

    fn init(alloc: std.mem.Allocator, out: *std.Io.Writer) PrintSink {
        return .{
            .fmt = print_fmt.Formatter.init(alloc, out),
        };
    }

    fn deinit(self: *PrintSink) void {
        self.fmt.deinit();
    }

    fn push(self: *PrintSink, ev: core.loop.ModeEv) !void {
        switch (ev) {
            .provider => |pev| {
                switch (pev) {
                    .stop => |stop| {
                        // stop:tool is an internal handoff marker when loop continues.
                        if (stop.reason == .tool) return;
                        self.stop_reason = core.providers.StopReason.merge(self.stop_reason, stop.reason);
                    },
                    else => {}, // .text, .thinking, .tool_call, .tool_result, .usage, .err forwarded via fmt.push
                }
                try self.fmt.push(pev);
            },
            .session_write_err => |msg| {
                if (self.fmt.text_seen and !self.fmt.text_ended_nl) {
                    try self.fmt.out.writeByte('\n');
                    self.fmt.text_ended_nl = true;
                }
                try self.fmt.out.writeAll("[session write failed: ");
                try self.fmt.out.writeAll(msg);
                try self.fmt.out.writeAll("]\n");
            },
            else => {}, // .replay, .session, .tool, .agent_status not used in print sink
        }
    }
};

const ActivityModeSink = struct {
    mode_sink: core.loop.ModeSink = .{ .vt = &core.loop.ModeSink.Bind(@This(), @This().push).vt },
    inner: *core.loop.ModeSink,
    activity_sink: *activity.ActivitySink,
    sid: []const u8,

    fn push(self: *ActivityModeSink, ev: core.loop.ModeEv) !void {
        switch (ev) {
            .provider => |provider_event| switch (provider_event) {
                .tool_call => |tool_call| self.activity_sink.emit(.{ .activity = .{
                    .session_id = self.sid,
                    .tool_name = tool_call.name,
                } }),
                else => {},
            },
            else => {},
        }
        try self.inner.push(ev);
    }
};

const TuiSink = struct {
    mode_sink: core.loop.ModeSink = .{ .vt = &core.loop.ModeSink.Bind(@This(), @This().push).vt },
    ui: *tui_harness.Ui,
    out: *std.Io.Writer,

    fn push(self: *TuiSink, ev: core.loop.ModeEv) !void {
        switch (ev) {
            .provider => |pev| {
                // Provider text may contain invalid UTF-8 from API responses.
                // Sanitize text fields before TUI rendering.
                self.ui.onProvider(pev) catch |err| switch (err) {
                    error.InvalidUtf8 => try self.pushSanitized(pev),
                    else => return err,
                };
            },
            .session_write_err => |msg| {
                const note = try std.fmt.allocPrint(self.ui.alloc, "[session write failed: {s}]", .{msg});
                defer self.ui.alloc.free(note);
                try self.ui.tr.infoText(note);
            },
            .agent_status => |as| {
                const phase: tui_transcript.AgentPhase = switch (as.phase) {
                    .running => .running,
                    .done => .done,
                    .err => .err,
                    .canceled => .canceled,
                };
                self.ui.tr.updateAgent(as.agent_id, phase) catch {
                    // Agent block not yet created — create it.
                    try self.ui.tr.agentBlock(as.agent_id, phase);
                };
            },
            else => {}, // .replay, .session, .tool not rendered in TUI sink
        }
        try self.ui.draw(self.out);
    }

    fn pushSanitized(self: *TuiSink, pev: core.providers.Event) !void {
        const alloc = self.ui.alloc;
        switch (pev) {
            .text => |t| {
                const s = try sanitizeUtf8LossyAlloc(alloc, t);
                defer alloc.free(s);
                try self.ui.onProvider(.{ .text = s });
            },
            .thinking => |t| {
                const s = try sanitizeUtf8LossyAlloc(alloc, t);
                defer alloc.free(s);
                try self.ui.onProvider(.{ .thinking = s });
            },
            .tool_call => |tc| {
                const s_id = try sanitizeUtf8LossyAlloc(alloc, tc.id);
                defer alloc.free(s_id);
                const s_name = try sanitizeUtf8LossyAlloc(alloc, tc.name);
                defer alloc.free(s_name);
                const s_args = try sanitizeUtf8LossyAlloc(alloc, tc.args);
                defer alloc.free(s_args);
                try self.ui.onProvider(.{ .tool_call = .{
                    .id = s_id,
                    .name = s_name,
                    .args = s_args,
                } });
            },
            .tool_result => |tr| {
                const s_id = try sanitizeUtf8LossyAlloc(alloc, tr.id);
                defer alloc.free(s_id);
                const s_out = try sanitizeUtf8LossyAlloc(alloc, tr.output);
                defer alloc.free(s_out);
                try self.ui.onProvider(.{ .tool_result = .{
                    .id = s_id,
                    .output = s_out,
                    .is_err = tr.is_err,
                } });
            },
            .err => |t| {
                const s = try sanitizeUtf8LossyAlloc(alloc, t);
                defer alloc.free(s);
                try self.ui.onProvider(.{ .err = s });
            },
            // Non-text events pass through directly
            .usage, .stop => try self.ui.onProvider(pev),
        }
    }
};

const AskUiCtx = tui_ask.AskUiCtx;
const collectAskAnswers = tui_ask.collectAskAnswers;
const firstUnanswered = tui_ask.firstUnanswered;
const buildAskRows = tui_ask.buildAskRows;
const buildAskResult = tui_ask.buildAskResult;

/// Reads stdin on a dedicated thread during streaming. Sets an atomic
/// flag when ESC is pressed, allowing the core loop's CancelSrc to
/// detect cancellation without platform-specific non-blocking hacks.
/// Mirrors pi's CancellableLoader + AbortController pattern.
const InputWatcher = struct {
    cancel_src: core.loop.CancelSrc = .{ .vt = &core.loop.CancelSrc.Bind(@This(), @This().isCanceled).vt },
    pause_ctl: tui_ask.PauseCtl = .{ .vt = &tui_ask.PauseCtl.Bind(@This(), @This().setPaused).vt },
    canceled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    paused: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
    fd: std.posix.fd_t,
    wake_r: std.posix.fd_t,
    wake_w: std.posix.fd_t,
    /// Buffer for non-ESC bytes consumed during streaming, replayed after join().
    stash: [64]u8 = undefined,
    stash_len: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

    fn init(fd: std.posix.fd_t) !InputWatcher {
        const pipe = try makePipe(true);
        errdefer {
            closeFd(pipe[0]);
            closeFd(pipe[1]);
        }
        return .{
            .fd = fd,
            .wake_r = pipe[0],
            .wake_w = pipe[1],
        };
    }

    fn deinit(self: *InputWatcher) void {
        self.join(null);
        closeFd(self.wake_r);
        closeFd(self.wake_w);
        self.* = undefined;
    }

    /// Start watching stdin for ESC on a background thread.
    /// Returns false if thread spawn failed (cancel unavailable).
    fn start(self: *InputWatcher) bool {
        self.canceled.store(false, .release);
        self.stop.store(false, .release);
        self.paused.store(false, .release);
        self.stash_len.store(0, .release);
        drainWake(self.wake_r);
        self.thread = std.Thread.spawn(.{}, watchFn, .{self}) catch return false;
        return true;
    }

    /// Stop the watcher, join the thread, replay stashed bytes into reader.
    fn join(self: *InputWatcher, reader: ?*tui_input.Reader) void {
        self.stop.store(true, .release);
        signalWake(self.wake_w);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        const n = self.stash_len.load(.acquire);
        if (n > 0) {
            if (reader) |r| r.inject(self.stash[0..n]);
        }
    }

    fn isCanceled(self: *InputWatcher) bool {
        return self.canceled.load(.acquire);
    }

    fn setPaused(self: *InputWatcher, paused: bool) void {
        self.paused.store(paused, .release);
        signalWake(self.wake_w);
    }

    fn isPaused(self: *InputWatcher) bool {
        return self.paused.load(.acquire);
    }

    fn watchFn(self: *InputWatcher) void {
        while (!self.stop.load(.acquire)) {
            const paused = self.paused.load(.acquire);
            var fds = [2]std.posix.pollfd{
                .{
                    .fd = self.wake_r,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                },
                .{
                    .fd = self.fd,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                },
            };
            const nfd: usize = if (paused) 1 else 2;
            const n = std.posix.poll(fds[0..nfd], -1) catch break;
            if (n == 0) continue;
            if ((fds[0].revents & std.posix.POLL.IN) != 0) {
                drainWake(self.wake_r);
                continue;
            }
            if (paused or (fds[1].revents & std.posix.POLL.IN) == 0) continue;
            var buf: [1]u8 = undefined;
            const r = fdRead(self.fd, &buf) catch break;
            if (r == 1 and buf[0] == 0x1b) {
                self.canceled.store(true, .release);
                return;
            }
            if (r == 1) {
                const cur = self.stash_len.load(.acquire);
                if (cur < self.stash.len) {
                    self.stash[cur] = buf[0];
                    self.stash_len.store(cur + 1, .release);
                }
            }
        }
    }
};

fn signalWake(fd: std.posix.fd_t) void {
    _ = fdWrite(fd, "\x01") catch {}; // cleanup: propagation impossible
}

fn drainWake(fd: std.posix.fd_t) void {
    var buf: [32]u8 = undefined;
    while (true) {
        _ = fdRead(fd, &buf) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return,
        };
    }
}

const TurnCancelFlag = struct {
    cancel_src: core.loop.CancelSrc = .{ .vt = &core.loop.CancelSrc.Bind(@This(), @This().isCanceled).vt },
    cancel_poll: core.providers.CancelPoll = .{ .vt = &core.providers.CancelPoll.Bind(@This(), @This().isCanceled).vt },
    canceled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn clear(self: *TurnCancelFlag) void {
        self.canceled.store(false, .release);
    }

    fn request(self: *TurnCancelFlag) void {
        self.canceled.store(true, .release);
    }

    fn isCanceled(self: *TurnCancelFlag) bool {
        return self.canceled.load(.acquire);
    }
};

const Mutex = struct {
    inner: std.Io.Mutex = .init,

    fn lock(self: *Mutex) void {
        self.inner.lockUncancelable(defaultIo());
    }

    fn unlock(self: *Mutex) void {
        self.inner.unlock(defaultIo());
    }
};

const Condition = struct {
    inner: std.Io.Condition = .init,

    fn wait(self: *Condition, mutex: *Mutex) void {
        self.inner.waitUncancelable(defaultIo(), &mutex.inner);
    }

    fn signal(self: *Condition) void {
        self.inner.signal(defaultIo());
    }
};

const LiveTurn = struct {
    const Req = struct {
        sid: []u8,
        prompt: []u8,
        model: []u8,
        provider_label: []u8,
        provider_opts: core.providers.Opts,
        system_prompt: ?[]u8 = null,

        fn deinit(self: *Req, alloc: std.mem.Allocator) void {
            alloc.free(self.sid);
            alloc.free(self.prompt);
            alloc.free(self.model);
            alloc.free(self.provider_label);
            if (self.system_prompt) |sp| alloc.free(sp);
            self.* = undefined;
        }
    };

    const ThreadCtx = struct {
        live: *LiveTurn,
        tctx: *const TurnCtx,
        req: Req,
    };

    alloc: std.mem.Allocator,
    mu: Mutex = .{},
    evs: std.ArrayListUnmanaged(SeqProviderEv) = .empty,
    ev_head: usize = 0,
    next_seq: u64 = 1,
    done: bool = false,
    running: bool = false,
    err_name: ?[]u8 = null,
    thr: ?std.Thread = null,
    wake_r: std.posix.fd_t,
    wake_w: std.posix.fd_t,
    cancel_flag: TurnCancelFlag = .{},
    abort_slot: core.providers.AbortSlot = .{},
    last_req: ?Req = null,
    agent_statuses: std.ArrayListUnmanaged(AgentStatusEntry) = .empty,
    agent_head: usize = 0,
    last_stop: ?core.providers.StopReason = null,
    last_err: ?[]u8 = null,
    last_model: ?[]u8 = null,
    ask_txn: ?*AskTxn = null,

    const AskTxn = struct {
        mu: Mutex = .{},
        cv: Condition = .{},
        claimed: bool = false,
        done: bool = false,
        args: OwnedAskArgs,
        out: ?[]u8 = null,
        err: ?anyerror = null,

        fn wait(self: *AskTxn) ![]u8 {
            self.mu.lock();
            defer self.mu.unlock();
            while (!self.done) self.cv.wait(&self.mu);
            if (self.err) |err| return err;
            return self.out orelse error.TerminalSetupFailed;
        }
    };

    const SeqProviderEv = struct {
        seq: u64,
        ev: core.providers.Event,
    };

    const AgentStatusEntry = struct {
        agent_id: []u8,
        phase: core.loop.AgentPhase,
    };

    fn init(alloc: std.mem.Allocator) !LiveTurn {
        const pipe = try makePipe(true);
        errdefer {
            closeFd(pipe[0]);
            closeFd(pipe[1]);
        }
        return .{
            .alloc = alloc,
            .wake_r = pipe[0],
            .wake_w = pipe[1],
        };
    }

    fn deinit(self: *LiveTurn) void {
        self.requestCancel();
        self.failAsk(error.Canceled);
        if (self.thr) |thr| {
            thr.join();
            self.thr = null;
        }
        self.mu.lock();
        for (self.evs.items[self.ev_head..]) |sev| freeProviderEv(self.alloc, sev.ev);
        self.evs.deinit(self.alloc);
        for (self.agent_statuses.items[self.agent_head..]) |as| self.alloc.free(as.agent_id);
        self.agent_statuses.deinit(self.alloc);
        if (self.err_name) |name| self.alloc.free(name);
        if (self.last_err) |e| self.alloc.free(e);
        if (self.last_model) |m| self.alloc.free(m);
        if (self.last_req) |*req| req.deinit(self.alloc);
        self.mu.unlock();
        closeFd(self.wake_r);
        closeFd(self.wake_w);
        self.* = undefined;
    }

    fn wakeFd(self: *const LiveTurn) std.posix.fd_t {
        return self.wake_r;
    }

    fn isRunning(self: *LiveTurn) bool {
        self.mu.lock();
        defer self.mu.unlock();
        return self.running;
    }

    fn requestCancel(self: *LiveTurn) void {
        self.cancel_flag.request();
        self.abort_slot.abort();
    }

    fn ask(self: *LiveTurn, args: core.tools.Call.AskArgs) ![]u8 {
        var tx = AskTxn{
            .args = try dupAskArgs(self.alloc, args),
        };
        defer tx.args.deinit(self.alloc);

        self.mu.lock();
        if (self.ask_txn != null) {
            self.mu.unlock();
            return error.AlreadyRunning;
        }
        self.ask_txn = &tx;
        self.mu.unlock();
        self.nudge();
        return tx.wait();
    }

    fn takeAsk(self: *LiveTurn) ?*AskTxn {
        self.mu.lock();
        defer self.mu.unlock();

        const tx = self.ask_txn orelse return null;
        if (tx.claimed) return null;
        tx.claimed = true;
        return tx;
    }

    fn finishAsk(self: *LiveTurn, tx: *AskTxn, out: anyerror![]u8) void {
        tx.mu.lock();
        if (out) |text| {
            tx.out = text;
        } else |err| {
            tx.err = err;
        }
        tx.done = true;
        tx.cv.signal();
        tx.mu.unlock();

        self.mu.lock();
        if (self.ask_txn == tx) self.ask_txn = null;
        self.mu.unlock();
        self.nudge();
    }

    fn failAsk(self: *LiveTurn, err: anyerror) void {
        self.mu.lock();
        const tx = self.ask_txn;
        self.ask_txn = null;
        self.mu.unlock();
        if (tx) |pending| {
            pending.mu.lock();
            if (!pending.done) {
                pending.err = err;
                pending.done = true;
                pending.cv.signal();
            }
            pending.mu.unlock();
        }
    }

    fn enqueueProvider(self: *LiveTurn, ev: core.providers.Event) !void {
        const dup = try dupProviderEv(self.alloc, ev);
        errdefer freeProviderEv(self.alloc, dup);

        self.mu.lock();
        const seq = self.next_seq;
        self.next_seq += 1;
        self.evs.append(self.alloc, .{
            .seq = seq,
            .ev = dup,
        }) catch |append_err| {
            self.mu.unlock();
            return append_err;
        };
        switch (ev) {
            .stop => |s| self.last_stop = s.reason,
            .err => |txt| {
                if (self.last_err) |old| self.alloc.free(old);
                self.last_err = self.alloc.dupe(u8, txt) catch null; // OOM: error still queued in evs, only convenience field lost
            },
            else => {}, // .text, .thinking, .tool_call, .tool_result, .usage: stored in evs list, no extra tracking needed
        }
        self.mu.unlock();
        self.nudge();
    }

    fn popProvider(self: *LiveTurn) ?SeqProviderEv {
        self.mu.lock();
        defer self.mu.unlock();

        if (self.ev_head >= self.evs.items.len) return null;
        const ev = self.evs.items[self.ev_head];
        self.ev_head += 1;
        if (self.ev_head == self.evs.items.len) {
            self.evs.items.len = 0;
            self.ev_head = 0;
        }
        return ev;
    }

    fn enqueueAgent(self: *LiveTurn, agent_id: []const u8, phase: core.loop.AgentPhase) !void {
        const id_dup = try self.alloc.dupe(u8, agent_id);
        errdefer self.alloc.free(id_dup);

        self.mu.lock();
        self.agent_statuses.append(self.alloc, .{
            .agent_id = id_dup,
            .phase = phase,
        }) catch |err| {
            self.mu.unlock();
            return err;
        };
        self.mu.unlock();
        self.nudge();
    }

    fn popAgent(self: *LiveTurn) ?AgentStatusEntry {
        self.mu.lock();
        defer self.mu.unlock();

        if (self.agent_head >= self.agent_statuses.items.len) return null;
        const entry = self.agent_statuses.items[self.agent_head];
        self.agent_head += 1;
        if (self.agent_head == self.agent_statuses.items.len) {
            self.agent_statuses.items.len = 0;
            self.agent_head = 0;
        }
        return entry;
    }

    const Completion = struct {
        err_name: ?[]u8 = null,
    };

    fn takeCompletion(self: *LiveTurn) ?Completion {
        var thr: ?std.Thread = null;
        var out: Completion = .{};

        self.mu.lock();
        if (!self.done) {
            self.mu.unlock();
            return null;
        }
        self.done = false;
        thr = self.thr;
        self.thr = null;
        out.err_name = self.err_name;
        self.err_name = null;
        self.mu.unlock();

        if (thr) |t| t.join();
        return out;
    }

    fn cloneReq(self: *LiveTurn, alloc: std.mem.Allocator) !?Req {
        self.mu.lock();
        defer self.mu.unlock();
        const req = self.last_req orelse return null;
        return try dupeReq(alloc, req);
    }

    fn start(self: *LiveTurn, tctx: *const TurnCtx, opts: TurnCtx.TurnOpts) !void {
        var saved_req = try dupeReq(self.alloc, opts);
        errdefer saved_req.deinit(self.alloc);

        self.mu.lock();
        if (self.running) {
            self.mu.unlock();
            return error.AlreadyRunning;
        }
        self.running = true;
        self.done = false;
        if (self.err_name) |name| {
            self.alloc.free(name);
            self.err_name = null;
        }
        self.last_stop = null;
        if (self.last_err) |e| {
            self.alloc.free(e);
            self.last_err = null;
        }
        if (self.last_model) |m| {
            self.alloc.free(m);
            self.last_model = null;
        }
        for (self.evs.items[self.ev_head..]) |sev| freeProviderEv(self.alloc, sev.ev);
        self.evs.items.len = 0;
        self.ev_head = 0;
        for (self.agent_statuses.items[self.agent_head..]) |as| self.alloc.free(as.agent_id);
        self.agent_statuses.items.len = 0;
        self.agent_head = 0;
        self.next_seq = 1;
        self.last_model = self.alloc.dupe(u8, opts.model) catch null; // OOM: overflow retry skips model match (conservative)
        self.mu.unlock();

        self.cancel_flag.clear();

        const ctx = try self.alloc.create(ThreadCtx);
        errdefer self.alloc.destroy(ctx);
        ctx.* = .{
            .live = self,
            .tctx = tctx,
            .req = try dupeReq(self.alloc, opts),
        };

        const thr = std.Thread.spawn(.{}, runThread, .{ctx}) catch |spawn_err| {
            ctx.req.deinit(self.alloc);
            self.alloc.destroy(ctx);
            self.mu.lock();
            self.running = false;
            self.done = false;
            self.mu.unlock();
            return spawn_err;
        };

        self.mu.lock();
        if (self.last_req) |*req| req.deinit(self.alloc);
        self.last_req = saved_req;
        self.thr = thr;
        self.mu.unlock();
    }

    fn runThread(ctx: *ThreadCtx) void {
        defer {
            ctx.req.deinit(ctx.live.alloc);
            ctx.live.alloc.destroy(ctx);
        }

        const run_res = ctx.tctx.run(.{
            .sid = ctx.req.sid,
            .prompt = ctx.req.prompt,
            .model = ctx.req.model,
            .provider_label = ctx.req.provider_label,
            .provider_opts = ctx.req.provider_opts,
            .system_prompt = ctx.req.system_prompt,
        });

        var err_name: ?[]u8 = null;
        if (run_res) |_| {} else |err| {
            err_name = ctx.live.alloc.dupe(u8, @errorName(err)) catch null;
        }

        ctx.live.mu.lock();
        ctx.live.running = false;
        ctx.live.done = true;
        if (ctx.live.err_name) |name| ctx.live.alloc.free(name);
        ctx.live.err_name = err_name;
        ctx.live.mu.unlock();
        ctx.live.nudge();
    }

    fn nudge(self: *LiveTurn) void {
        const b = [_]u8{1};
        _ = fdWrite(self.wake_w, &b) catch {}; // cleanup: propagation impossible
    }
};

const LiveTurnSink = struct {
    mode_sink: core.loop.ModeSink = .{ .vt = &core.loop.ModeSink.Bind(@This(), @This().push).vt },
    live: *LiveTurn,

    fn push(self: *LiveTurnSink, ev: core.loop.ModeEv) !void {
        switch (ev) {
            .provider => |pev| try self.live.enqueueProvider(pev),
            .agent_status => |as| try self.live.enqueueAgent(as.agent_id, as.phase),
            else => {}, // .replay, .session, .tool, .session_write_err not forwarded to live turn
        }
    }
};

const LiveAskCtx = struct {
    ask_hook: core.tools.builtin.AskHook = .{ .vt = &AskBind.vt },
    live: *LiveTurn,

    const AskBind = core.tools.builtin.AskHook.Bind(@This(), run);

    fn run(self: *LiveAskCtx, args: core.tools.Call.AskArgs) ![]u8 {
        return self.live.ask(args);
    }
};

fn dupeReq(alloc: std.mem.Allocator, src: anytype) !LiveTurn.Req {
    const sid = try alloc.dupe(u8, src.sid);
    errdefer alloc.free(sid);
    const prompt = try alloc.dupe(u8, src.prompt);
    errdefer alloc.free(prompt);
    const model = try alloc.dupe(u8, src.model);
    errdefer alloc.free(model);
    const provider_label = try alloc.dupe(u8, src.provider_label);
    errdefer alloc.free(provider_label);
    const system_prompt = if (src.system_prompt) |sp| try alloc.dupe(u8, sp) else null;
    errdefer if (system_prompt) |sp| alloc.free(sp);

    return .{
        .sid = sid,
        .prompt = prompt,
        .model = model,
        .provider_label = provider_label,
        .provider_opts = src.provider_opts,
        .system_prompt = system_prompt,
    };
}

const OwnedAskArgs = struct {
    questions: []core.tools.Call.AskArgs.Question,

    fn view(self: *const OwnedAskArgs) core.tools.Call.AskArgs {
        return .{ .questions = self.questions };
    }

    fn deinit(self: *OwnedAskArgs, alloc: std.mem.Allocator) void {
        for (self.questions) |q| {
            alloc.free(q.id);
            alloc.free(q.header);
            alloc.free(q.question);
            for (q.options) |opt| {
                alloc.free(opt.label);
                alloc.free(opt.description);
            }
            alloc.free(q.options);
        }
        alloc.free(self.questions);
        self.questions = &.{};
    }
};

fn dupAskArgs(alloc: std.mem.Allocator, args: core.tools.Call.AskArgs) !OwnedAskArgs {
    const qs = try alloc.alloc(core.tools.Call.AskArgs.Question, args.questions.len);
    var q_n: usize = 0;
    errdefer {
        for (qs[0..q_n]) |q| {
            alloc.free(q.id);
            alloc.free(q.header);
            alloc.free(q.question);
            for (q.options) |opt| {
                alloc.free(opt.label);
                alloc.free(opt.description);
            }
            alloc.free(q.options);
        }
        alloc.free(qs);
    }

    for (args.questions, 0..) |q, i| {
        const opts = try alloc.alloc(core.tools.Call.AskArgs.Option, q.options.len);
        var opt_n: usize = 0;
        errdefer {
            for (opts[0..opt_n]) |opt| {
                alloc.free(opt.label);
                alloc.free(opt.description);
            }
            alloc.free(opts);
        }
        for (q.options, 0..) |opt, j| {
            opts[j] = .{
                .label = try alloc.dupe(u8, opt.label),
                .description = try alloc.dupe(u8, opt.description),
            };
            opt_n = j + 1;
        }
        qs[i] = .{
            .id = try alloc.dupe(u8, q.id),
            .header = try alloc.dupe(u8, q.header),
            .question = try alloc.dupe(u8, q.question),
            .options = opts,
            .allow_other = q.allow_other,
        };
        q_n = i + 1;
    }

    return .{ .questions = qs };
}

fn dupProviderEv(alloc: std.mem.Allocator, ev: core.providers.Event) !core.providers.Event {
    return switch (ev) {
        .text => |txt| .{ .text = try alloc.dupe(u8, txt) },
        .thinking => |txt| .{ .thinking = try alloc.dupe(u8, txt) },
        .tool_call => |tc| blk: {
            const id = try alloc.dupe(u8, tc.id);
            errdefer alloc.free(id);
            const name = try alloc.dupe(u8, tc.name);
            errdefer alloc.free(name);
            const args = try alloc.dupe(u8, tc.args);
            break :blk .{
                .tool_call = .{
                    .id = id,
                    .name = name,
                    .args = args,
                },
            };
        },
        .tool_result => |tr| blk: {
            const id = try alloc.dupe(u8, tr.id);
            errdefer alloc.free(id);
            const out = try alloc.dupe(u8, tr.output);
            break :blk .{
                .tool_result = .{
                    .id = id,
                    .output = out,
                    .is_err = tr.is_err,
                },
            };
        },
        .usage => |usage| .{ .usage = usage },
        .stop => |stop| .{ .stop = stop },
        .err => |txt| .{ .err = try alloc.dupe(u8, txt) },
    };
}

fn freeProviderEv(alloc: std.mem.Allocator, ev: core.providers.Event) void {
    switch (ev) {
        .text => |txt| alloc.free(txt),
        .thinking => |txt| alloc.free(txt),
        .tool_call => |tc| {
            alloc.free(tc.id);
            alloc.free(tc.name);
            alloc.free(tc.args);
        },
        .tool_result => |tr| {
            alloc.free(tr.id);
            alloc.free(tr.output);
        },
        .usage, .stop => {},
        .err => |txt| alloc.free(txt),
    }
}

const JsonSink = struct {
    mode_sink: core.loop.ModeSink = .{ .vt = &core.loop.ModeSink.Bind(@This(), @This().push).vt },
    alloc: std.mem.Allocator,
    out: *std.Io.Writer,

    fn push(self: *JsonSink, ev: core.loop.ModeEv) !void {
        switch (ev) {
            .replay => |payload| try self.emit("replay", payload),
            .session => |payload| try self.emit("session", payload),
            .provider => |payload| try self.emit("provider", payload),
            .tool => |payload| try self.emit("tool", payload),
            .session_write_err => |msg| try self.emit("session_write_err", msg),
            .agent_status => |as| try self.emit("agent_status", as),
            .retry_attempt => |ra| try self.emit("retry_attempt", ra),
            .overflow_detected => try self.emit("overflow_detected", {}),
            .compaction_triggered => try self.emit("compaction_triggered", {}),
            .stream_timeout => |st| try self.emit("stream_timeout", st),
        }
    }

    fn emit(self: *JsonSink, typ: []const u8, payload: anytype) !void {
        const raw = try std.json.Stringify.valueAlloc(self.alloc, .{
            .type = typ,
            .event = payload,
        }, .{});
        defer self.alloc.free(raw);
        try self.out.writeAll(raw);
        try self.out.writeAll("\n");
    }
};

const RpcReq = struct {
    id: ?[]const u8 = null,
    cmd: ?[]const u8 = null,
    type: ?[]const u8 = null,
    text: ?[]const u8 = null,
    arg: ?[]const u8 = null,
    tools: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    session: ?[]const u8 = null,
    model: ?[]const u8 = null,
    model_id: ?[]const u8 = null,
    session_path: ?[]const u8 = null,
    sid: ?[]const u8 = null,
};

const AuditHooks = struct {
    io: std.Io = std.Io.failing,
    audit_emitter: ?*core.audit.Emitter = null,
    now_ms: *const fn () i64 = core.time.milliTimestamp,
    auth_home: ?[]const u8 = null,
    auth_lock: core.policy.Lock = .{},
    ca_file: ?[]const u8 = null,
    share_gist: *const fn (std.mem.Allocator, std.Io, []const u8, *const RuntimePolicy) anyerror![]u8 = shareGist,
    run_upgrade: *const fn (std.mem.Allocator, update_mod.AuditHooks) anyerror!update_mod.Outcome = update_mod.runOutcomeAudited,
    seq_tracker: ?*core.audit_integrity.SeqTracker = null,

    fn auth(self: AuditHooks) core.providers.auth.Hooks {
        return .{
            .home_override = self.auth_home,
            .ca_file = self.ca_file,
            .lock = self.auth_lock,
            .audit_emitter = self.audit_emitter,
            .now_ms = self.now_ms,
        };
    }
};

/// Live audit forwarder: wraps SyslogShipper via Emitter interface.
/// Events are syslog-framed, buffered to a durable Ring spool on disconnect,
/// and flushed in order on reconnect.
const AuditShipper = struct {
    emitter: core.audit.Emitter = .{ .vt = &core.audit.Emitter.Bind(@This(), emitAudit).vt },
    alloc: std.mem.Allocator,
    shipper: core.audit.SyslogShipper,
    sender_conn: core.audit.SenderConnector,
    now_ms: *const fn () i64,

    const InitOpts = struct {
        alloc: std.mem.Allocator,
        host: []const u8,
        port: u16,
        transport: core.syslog.Transport,
        overflow: core.audit.OverflowPolicy,
        buf_cap: u16,
        io: std.Io,
        spool_dir: ?std.Io.Dir,
        allow_private: bool = false,
        ca_file: ?[]const u8 = null,
        now_ms: *const fn () i64 = core.time.milliTimestamp,
    };

    fn init(self: *AuditShipper, opts: InitOpts) !void {
        self.alloc = opts.alloc;
        self.now_ms = opts.now_ms;
        self.sender_conn = .{
            .alloc = opts.alloc,
            .opts = .{
                .io = opts.io,
                .transport = opts.transport,
                .host = opts.host,
                .port = opts.port,
                .allow_private = opts.allow_private,
                .tls = .{ .ca_file = opts.ca_file },
            },
        };
        self.shipper = try core.audit.SyslogShipper.init(opts.alloc, .{}, .{
            .connector = &self.sender_conn.connector,
            .buf_cap = opts.buf_cap,
            .overflow = opts.overflow,
            .io = opts.io,
            .spool_dir = opts.spool_dir,
        });
    }

    fn deinit(self: *AuditShipper) void {
        self.shipper.deinit();
    }

    fn emitAudit(self: *AuditShipper, _: std.mem.Allocator, ent: core.audit.Entry) !void {
        _ = try self.shipper.send(ent, self.now_ms());
    }
};

const RuntimeCtlAudit = struct {
    hooks: AuditHooks,
    seq: u64 = 1,

    const Req = struct {
        op: []const u8,
        res_kind: core.audit.ResourceKind,
        res_name: core.audit.Str,
        outcome: core.audit.Outcome = .ok,
        severity: core.audit.Severity = .info,
        msg: core.audit.Str,
        argv: ?core.audit.Str = null,
        attrs: []const core.audit.Attribute = &.{},
    };

    fn emit(self: *RuntimeCtlAudit, alloc: std.mem.Allocator, req: Req) !void {
        const e = self.hooks.audit_emitter orelse return;
        const seq = self.seq;
        self.seq +%= 1;
        try e.emit(alloc, .{
            .ts_ms = self.hooks.now_ms(),
            .sid = "runtime",
            .seq = seq,
            .severity = req.severity,
            .outcome = req.outcome,
            .actor = .{ .kind = .sys },
            .res = .{
                .kind = req.res_kind,
                .name = req.res_name,
                .op = req.op,
            },
            .msg = req.msg,
            .data = .{
                .tool = .{
                    .name = .{ .text = "runtime", .vis = .@"pub" },
                    .call_id = req.op,
                    .argv = req.argv,
                },
            },
            .attrs = req.attrs,
        });
    }
};

const PolicyToolAudit = struct {
    alloc: std.mem.Allocator,
    hooks: AuditHooks,
    sid: []const u8,
    seq: *u64,

    fn emit(self: PolicyToolAudit, call: core.tools.Call, name: []const u8) !void {
        const e = self.hooks.audit_emitter orelse return;
        const seq = self.seq.*;
        self.seq.* +%= 1;
        try e.emit(self.alloc, .{
            .ts_ms = self.hooks.now_ms(),
            .sid = self.sid,
            .seq = seq,
            .outcome = .deny,
            .actor = .{ .kind = .sys },
            .res = .{
                .kind = auditResMap(call.kind).kind,
                .name = .{ .text = name, .vis = .@"pub" },
                .op = auditResMap(call.kind).op,
            },
            .msg = .{ .text = policy_denied_msg, .vis = .@"pub" },
            .data = .{
                .policy = .{
                    .effect = .deny,
                    .scope = "tool",
                },
            },
        });
    }
};

const AuditResMap = struct {
    kind: core.audit.ResourceKind,
    op: []const u8,
};

fn auditResMap(kind: core.tools.Kind) AuditResMap {
    return switch (kind) {
        .read => .{ .kind = .file, .op = "read" },
        .write => .{ .kind = .file, .op = "write" },
        .edit => .{ .kind = .file, .op = "edit" },
        .grep => .{ .kind = .file, .op = "grep" },
        .find => .{ .kind = .file, .op = "find" },
        .ls => .{ .kind = .file, .op = "list" },
        .web => .{ .kind = .net, .op = "request" },
        .agent => .{ .kind = .cmd, .op = "spawn" },
        .bash => .{ .kind = .cmd, .op = "run" },
        .skill => .{ .kind = .cmd, .op = "run" },
        .ask => .{ .kind = .cfg, .op = "prompt" },
    };
}

fn runtimeCfgResName() core.audit.Str {
    return .{ .text = "runtime", .vis = .@"pub" };
}

fn runtimeSessResName() core.audit.Str {
    return .{ .text = "session", .vis = .@"pub" };
}

fn runtimeExportResName() core.audit.Str {
    return .{ .text = "session-export", .vis = .@"pub" };
}

fn runtimeShareResName() core.audit.Str {
    return .{ .text = "gist", .vis = .@"pub" };
}

fn runtimeUpgradeResName() core.audit.Str {
    return .{ .text = "upgrade", .vis = .@"pub" };
}

fn exportAuditHooks(hooks: AuditHooks) core.session.@"export".AuditHooks {
    return .{
        .audit_emitter = hooks.audit_emitter,
        .now_ms = hooks.now_ms,
    };
}

fn updateAuditHooks(hooks: AuditHooks, io: std.Io, home: ?[]const u8) update_mod.AuditHooks {
    return .{
        .io = io,
        .http_deps = .{ .io = io },
        .home = home,
        .audit_emitter = hooks.audit_emitter,
        .now_ms = hooks.now_ms,
    };
}

const CtlOutcome = enum { start, ok, fail };

fn runtimeCtlAudit(
    audit: anytype,
    alloc: std.mem.Allocator,
    op: []const u8,
    res_kind: core.audit.ResourceKind,
    res_name: core.audit.Str,
    argv: ?core.audit.Str,
    outcome: CtlOutcome,
    msg: ?core.audit.Str,
    attrs: []const core.audit.Attribute,
) !void {
    try audit.emit(alloc, .{
        .op = op,
        .res_kind = res_kind,
        .res_name = res_name,
        .outcome = switch (outcome) {
            .start, .ok => .ok,
            .fail => .fail,
        },
        .severity = switch (outcome) {
            .start => .info,
            .ok => .notice,
            .fail => .err,
        },
        .msg = msg orelse switch (outcome) {
            .start => .{ .text = "runtime control start", .vis = .@"pub" },
            .ok => .{ .text = "runtime control success", .vis = .@"pub" },
            .fail => .{ .text = "runtime control failure", .vis = .@"pub" },
        },
        .argv = argv,
        .attrs = attrs,
    });
}

fn replaceOwnedText(
    alloc: std.mem.Allocator,
    current: *([]const u8),
    owned: *?[]u8,
    next: []const u8,
) !void {
    const dup = try alloc.dupe(u8, next);
    if (owned.*) |old| alloc.free(old);
    owned.* = dup;
    current.* = dup;
}

const ReloadRes = enum {
    loaded,
    empty,
};

fn reloadContextWithAudit(
    alloc: std.mem.Allocator,
    sys_prompt: *?[]const u8,
    sys_prompt_owned: *?[]u8,
    audit: *RuntimeCtlAudit,
    load_fn: *const fn (std.mem.Allocator, std.Io, ?[]const u8) anyerror!?[]u8,
    home: ?[]const u8,
) !ReloadRes {
    try runtimeCtlAudit(audit, alloc, "reload", .cfg, runtimeCfgResName(), null, .start, null, &.{});
    const next_ctx = load_fn(alloc, defaultIo(), home) catch |err| {
        try runtimeCtlAudit(
            audit,
            alloc,
            "reload",
            .cfg,
            runtimeCfgResName(),
            null,
            .fail,
            .{ .text = @errorName(err), .vis = .mask },
            &.{},
        );
        return err;
    };
    if (next_ctx) |new_ctx| {
        if (sys_prompt_owned.*) |old| alloc.free(old);
        sys_prompt_owned.* = new_ctx;
        sys_prompt.* = new_ctx;
        const attrs = [_]core.audit.Attribute{
            .{
                .key = "loaded",
                .vis = .@"pub",
                .val = .{ .bool = true },
            },
        };
        try runtimeCtlAudit(audit, alloc, "reload", .cfg, runtimeCfgResName(), null, .ok, null, &attrs);
        return .loaded;
    }
    if (sys_prompt_owned.*) |old| alloc.free(old);
    sys_prompt_owned.* = null;
    sys_prompt.* = null;
    const attrs = [_]core.audit.Attribute{
        .{
            .key = "loaded",
            .vis = .@"pub",
            .val = .{ .bool = false },
        },
    };
    try runtimeCtlAudit(audit, alloc, "reload", .cfg, runtimeCfgResName(), null, .ok, null, &attrs);
    return .empty;
}

pub fn exec(alloc: std.mem.Allocator, run_cmd: cli.Run) (Err || anyerror)![]u8 {
    return execWithIo(alloc, run_cmd, null, null);
}

pub fn execWithWriter(
    alloc: std.mem.Allocator,
    run_cmd: cli.Run,
    out: ?*std.Io.Writer,
) (Err || anyerror)![]u8 {
    return execWithIo(alloc, run_cmd, null, out);
}

pub fn execWithIo(
    alloc: std.mem.Allocator,
    run_cmd: cli.Run,
    in: ?*std.Io.Reader,
    out: ?*std.Io.Writer,
) (Err || anyerror)![]u8 {
    return execWithIoHooks(alloc, run_cmd, in, out, .{});
}

const TuiHooks = struct {
    stdin_fd: std.posix.fd_t = std.posix.STDIN_FILENO,
    live: ?bool = null,
    raw_mode: bool = true,
    exit_on_idle: bool = false,
    stop_after_completions: ?u8 = null,
    submit_text: ?[]const u8 = null,
};

fn readLineAlloc(alloc: std.mem.Allocator, in: *std.Io.Reader, limit: usize) !?[]u8 {
    var buf: std.Io.Writer.Allocating = .init(alloc);
    errdefer buf.deinit();

    const n = in.streamDelimiterLimit(&buf.writer, '\n', .limited(limit)) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |e| return e,
    };

    var had_delimiter = false;
    if (in.bufferedLen() > 0) {
        const peeked = try in.peek(1);
        if (peeked.len > 0 and peeked[0] == '\n') {
            in.toss(1);
            had_delimiter = true;
        }
    }

    if (!had_delimiter and n == 0) return null;
    return try buf.toOwnedSlice();
}

fn getenv(name: [*:0]const u8) ?[]const u8 {
    return if (std.c.getenv(name)) |value| std.mem.span(value) else null;
}

fn defaultIo() std.Io {
    return @import("../core/rt_io.zig").default();
}

fn testRealPathAlloc(alloc: std.mem.Allocator, dir: std.Io.Dir, sub_path: []const u8) ![]u8 {
    const resolved = try dir.realPathFileAlloc(std.testing.io, sub_path, alloc);
    defer alloc.free(resolved);
    return try alloc.dupe(u8, resolved);
}

fn testCwdRealPathAlloc(alloc: std.mem.Allocator, sub_path: []const u8) ![]u8 {
    const resolved = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, sub_path, alloc);
    defer alloc.free(resolved);
    return try alloc.dupe(u8, resolved);
}

fn isTty(fd: std.posix.fd_t) bool {
    return std.c.isatty(fd) == 1;
}

fn openDirPath(path: []const u8, options: std.Io.Dir.OpenOptions) !std.Io.Dir {
    if (std.fs.path.isAbsolute(path)) {
        return std.Io.Dir.openDirAbsolute(defaultIo(), path, options);
    }
    return std.Io.Dir.cwd().openDir(defaultIo(), path, options);
}

fn closeFd(fd: std.posix.fd_t) void {
    _ = std.c.close(fd);
}

fn chdirPath(path: []const u8) !void {
    const path_z = try std.posix.toPosixPath(path);
    if (std.c.chdir(&path_z) != 0) return std.posix.unexpectedErrno(std.posix.errno(-1));
}

fn makePipe(nonblocking: bool) ![2]std.posix.fd_t {
    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return std.posix.unexpectedErrno(std.posix.errno(-1));
    errdefer {
        closeFd(fds[0]);
        closeFd(fds[1]);
    }
    try setCloexec(fds[0]);
    try setCloexec(fds[1]);
    if (nonblocking) {
        try setNonblockFd(fds[0]);
        try setNonblockFd(fds[1]);
    }
    return fds;
}

fn setCloexec(fd: std.posix.fd_t) !void {
    const flags = std.c.fcntl(fd, @as(c_int, std.posix.F.GETFD), @as(c_int, 0));
    if (flags == -1) return std.posix.unexpectedErrno(std.posix.errno(-1));
    if (std.c.fcntl(fd, @as(c_int, std.posix.F.SETFD), flags | @as(c_int, std.posix.FD_CLOEXEC)) == -1) {
        return std.posix.unexpectedErrno(std.posix.errno(-1));
    }
}

fn setNonblockFd(fd: std.posix.fd_t) !void {
    const flags = std.c.fcntl(fd, @as(c_int, std.posix.F.GETFL), @as(c_int, 0));
    if (flags == -1) return std.posix.unexpectedErrno(std.posix.errno(-1));
    const nonblock: c_int = @bitCast(std.posix.O{ .NONBLOCK = true });
    if (std.c.fcntl(fd, @as(c_int, std.posix.F.SETFL), flags | nonblock) == -1) {
        return std.posix.unexpectedErrno(std.posix.errno(-1));
    }
}

fn fdRead(fd: std.posix.fd_t, buf: []u8) !usize {
    while (true) {
        const rc = std.c.read(fd, buf.ptr, buf.len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

fn fdWrite(fd: std.posix.fd_t, bytes: []const u8) !usize {
    while (true) {
        const rc = std.c.write(fd, bytes.ptr, bytes.len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

fn fdWriteAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) off += try fdWrite(fd, bytes[off..]);
}

fn execWithIoHooks(
    alloc: std.mem.Allocator,
    run_cmd: cli.Run,
    in: ?*std.Io.Reader,
    out: ?*std.Io.Writer,
    audit_hooks: AuditHooks,
) (Err || anyerror)![]u8 {
    return execWithIoAllHooks(alloc, run_cmd, in, out, audit_hooks, .{}, .{});
}

fn execWithIoTuiHooks(
    alloc: std.mem.Allocator,
    run_cmd: cli.Run,
    in: ?*std.Io.Reader,
    out: ?*std.Io.Writer,
    audit_hooks: AuditHooks,
    tui_hooks: TuiHooks,
) (Err || anyerror)![]u8 {
    return execWithIoAllHooks(alloc, run_cmd, in, out, audit_hooks, tui_hooks, .{});
}

fn execWithIoActivityHooks(
    alloc: std.mem.Allocator,
    run_cmd: cli.Run,
    in: ?*std.Io.Reader,
    out: ?*std.Io.Writer,
    activity_hooks: activity.ActivityHooks,
) (Err || anyerror)![]u8 {
    return execWithIoAllHooks(alloc, run_cmd, in, out, .{}, .{}, activity_hooks);
}

fn execWithIoAllHooks(
    alloc: std.mem.Allocator,
    run_cmd: cli.Run,
    in: ?*std.Io.Reader,
    out: ?*std.Io.Writer,
    audit_hooks: AuditHooks,
    tui_hooks: TuiHooks,
    activity_hooks: activity.ActivityHooks,
) (Err || anyerror)![]u8 {
    var provider_rt: ProviderRuntime = undefined;
    var hooks = audit_hooks;
    hooks.io = run_cmd.io;
    if (hooks.ca_file == null) hooks.ca_file = run_cmd.cfg.ca_file;
    hooks.auth_lock = run_cmd.cfg.policy_lock;
    if (hooks.auth_home == null) hooks.auth_home = run_cmd.home;
    var missing_provider = MissingProvider{
        .alloc = alloc,
        .msg = missing_provider_msg,
    };
    var provider: *core.providers.Provider = undefined;
    var has_provider_rt = false;
    defer if (has_provider_rt) provider_rt.deinit();

    const home = run_cmd.home;
    var activity_bridge: activity.Bridge = undefined;
    var has_activity_bridge = false;
    defer if (has_activity_bridge) activity_bridge.deinit();
    var activity_sink = activity_hooks.sink;
    if (activity_sink == null) {
        if (home) |h| {
            if (activity.Bridge.init(alloc, run_cmd.io, h)) |bridge| {
                activity_bridge = bridge;
                has_activity_bridge = true;
                activity_sink = activity_bridge.activitySink();
            } else |_| {}
        }
    }
    var pol = try RuntimePolicy.load(alloc, defaultIo(), home);
    defer pol.deinit();

    // Durable audit sequence tracker: persists high-water mark so
    // replayed audit entries are detected across process restarts.
    var seq_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const seq_path: ?[]const u8 = if (home) |h| blk: {
        break :blk std.fmt.bufPrint(&seq_path_buf, "{s}/.pz/audit_seq", .{h}) catch unreachable; // max_path_bytes (4096) >> home + 16 chars
    } else null;
    var seq_tracker = core.audit_integrity.SeqTracker.init(alloc, defaultIo(), seq_path);
    hooks.seq_tracker = &seq_tracker;

    // Durable audit forwarding: when syslog is configured, create a
    // SyslogShipper with disk-backed spool so collector outages don't
    // silently drop privileged audit events.
    var audit_shipper: AuditShipper = undefined;
    var has_audit_shipper = false;
    var spool_dir: ?std.Io.Dir = null;
    defer if (spool_dir) |d| d.close(defaultIo());
    defer if (has_audit_shipper) audit_shipper.deinit();

    if (hooks.audit_emitter == null) {
        if (run_cmd.cfg.syslog_fwd) |fwd| {
            if (parseSyslogTransport(fwd.transport)) |transport| {
                const overflow: core.audit.OverflowPolicy = switch (run_cmd.cfg.audit_overflow) {
                    .drop_oldest => .drop_oldest,
                    .fail_closed => .fail_closed,
                };

                // Create spool directory under ~/.pz/audit_spool/.
                // Under fail_closed, spool creation failure is fatal.
                // Under drop_oldest, falls back to in-memory ring.
                if (home) |h| {
                    var spool_path_buf: [std.fs.max_path_bytes]u8 = undefined;
                    const spool_path = std.fmt.bufPrint(&spool_path_buf, "{s}/.pz/audit_spool", .{h}) catch
                        if (overflow == .fail_closed) return error.AuditSpoolSetup else null;
                    if (spool_path) |sp| {
                        if (core.fs_secure.ensureDirPath(sp)) {
                            spool_dir = std.Io.Dir.openDirAbsolute(run_cmd.io, sp, .{ .iterate = true }) catch
                                if (overflow == .fail_closed) return error.AuditSpoolSetup else null;
                        } else |_| {
                            if (overflow == .fail_closed) return error.AuditSpoolSetup;
                        }
                    }
                } else if (overflow == .fail_closed) {
                    return error.AuditSpoolSetup;
                }

                try audit_shipper.init(.{
                    .alloc = alloc,
                    .host = fwd.host,
                    .port = fwd.port,
                    .transport = transport,
                    .overflow = overflow,
                    .buf_cap = fwd.buf_cap,
                    .io = run_cmd.io,
                    .spool_dir = spool_dir,
                    .ca_file = run_cmd.cfg.ca_file,
                    .now_ms = hooks.now_ms,
                });
                has_audit_shipper = true;
                hooks.audit_emitter = &audit_shipper.emitter;
            } else return error.InvalidSyslogTransport;
        }
    }

    // Shared event loop for TUI mode — providers and tools use it
    // instead of creating per-call instances.
    var el: ?event_loop.EventLoop = if (run_cmd.mode == .tui)
        try event_loop.EventLoop.init()
    else
        null;
    defer if (el) |*e| e.deinit();

    var tools_rt = core.tools.builtin.Runtime.init(.{
        .alloc = alloc,
        .tool_mask = run_cmd.tool_mask,
        .home = home,
    });

    var sid: []u8 = &.{};
    var session_dir_path: ?[]u8 = null;
    defer if (session_dir_path) |path| alloc.free(path);
    errdefer if (sid.len > 0) alloc.free(sid);

    var store: ?*core.session.SessionStore = null;
    var fs_store_impl: core.session.fs_store.Store = undefined;
    var null_store_impl = core.session.NullStore.init();

    defer if (store) |s| s.deinit();

    var stdout_buf: [4096]u8 = undefined;
    var stdin_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(run_cmd.io, &stdout_buf);
    var stdin_reader = std.Io.File.stdin().readerStreaming(run_cmd.io, &stdin_buf);
    const writer = if (out) |w| w else &stdout_writer.interface;
    const reader = if (in) |r| r else &stdin_reader.interface;

    // Init provider
    const needs_login: ?NativeProviderKind = null;
    if (run_cmd.cfg.provider_cmd) |provider_cmd| {
        try provider_rt.init(alloc, defaultIo(), provider_cmd);
        has_provider_rt = true;
        provider = &provider_rt.client.provider;
    } else {
        const provider_name = resolveDefaultProvider(run_cmd.cfg.provider);
        if (parseNativeProviderKind(provider_name)) |native_kind| {
            missing_provider.msg = missingProviderMsgForInitErr(native_kind, error.AuthNotFound);
            provider = &missing_provider.provider;
        } else {
            missing_provider.msg = unsupported_native_provider_msg;
            provider = &missing_provider.provider;
        }
    }

    // Init store
    // Headless modes (print/json) disable durable session writes
    // by default. The user must opt in via --continue, --resume,
    // or an explicit session ID.  --no-session always wins.
    const headless_default = run_cmd.session == .auto and
        core.policy.SessionPersist.forMode(run_cmd.mode) == .off;
    if (run_cmd.no_session or headless_default) {
        sid = try newSid(alloc);
        store = &null_store_impl.session_store;
    } else {
        const plan = try resolveSessionPlan(alloc, run_cmd);
        sid = plan.sid;
        session_dir_path = plan.dir_path;

        try core.fs_secure.ensureDirPath(plan.dir_path);
        var session_dir = try std.Io.Dir.cwd().openDir(defaultIo(), plan.dir_path, .{ .iterate = true });
        errdefer session_dir.close(defaultIo());
        core.session.cleanOrphanTmpFiles(session_dir);
        fs_store_impl = try core.session.fs_store.Store.init(.{
            .alloc = alloc,
            .dir = session_dir,
            .flush = .{
                .always = {},
            },
            .replay = .{},
        });
        store = &fs_store_impl.session_store;
    }

    var activity_sid: ?[]u8 = null;
    defer if (activity_sid) |owned_sid| alloc.free(owned_sid);
    defer if (activity_sid) |owned_sid| activity_sink.?.emit(.{ .stop = .{ .session_id = owned_sid } });
    if (activity_sink) |sink| {
        activity_sid = alloc.dupe(u8, sid) catch null;
        if (activity_sid) |owned_sid| sink.emit(.{ .session_start = .{ .session_id = owned_sid } });
    }

    // Dispatch
    {
        const sess_store = store.?;
        const sys_prompt = try buildSystemPrompt(alloc, run_cmd, home);
        defer if (sys_prompt) |sp| alloc.free(sp);

        switch (run_cmd.mode) {
            .print => try runPrint(
                alloc,
                run_cmd,
                sid,
                provider,
                sess_store,
                &pol,
                &tools_rt,
                writer,
                sys_prompt,
                audit_hooks,
                activity_sink,
                false,
            ),
            .json => try runJson(
                alloc,
                run_cmd,
                sid,
                provider,
                sess_store,
                &pol,
                &tools_rt,
                reader,
                writer,
                sys_prompt,
                hooks,
                activity_sink,
                false,
            ),
            .tui => try runTui(
                alloc,
                run_cmd,
                &sid,
                provider,
                sess_store,
                &pol,
                &tools_rt,
                reader,
                writer,
                session_dir_path,
                run_cmd.no_session,
                sys_prompt,
                false,
                hooks,
                tui_hooks,
                activity_sink,
                null,
                needs_login,
            ),
            .rpc => try runRpc(
                alloc,
                run_cmd,
                &sid,
                provider,
                sess_store,
                &pol,
                &tools_rt,
                reader,
                writer,
                session_dir_path,
                run_cmd.no_session,
                sys_prompt,
                hooks,
                activity_sink,
                false,
            ),
        }
    }

    if (out == null) try stdout_writer.interface.flush();
    return sid;
}

fn runPrint(
    alloc: std.mem.Allocator,
    run_cmd: cli.Run,
    sid: []const u8,
    provider: *core.providers.Provider,
    store: *core.session.SessionStore,
    pol: *const RuntimePolicy,
    tools_rt: *core.tools.builtin.Runtime,
    out: *std.Io.Writer,
    sys_prompt: ?[]const u8,
    audit_hooks: AuditHooks,
    activity_sink: ?*activity.ActivitySink,
    is_oauth: bool,
) !void {
    const home = run_cmd.home;
    const prompt = run_cmd.prompt orelse return error.EmptyPrompt;

    var sink_impl = PrintSink.init(alloc, out);
    defer sink_impl.deinit();
    sink_impl.fmt.verbose = run_cmd.verbose;
    // ML3 --diag handoff: carry the parsed flag into the formatter's per-turn
    // diagnostics gate. With the gate on, `pushDiag` buffers turn timings and
    // `finish()` flushes the breakdown; with it off, `pushDiag` is a no-op.
    // NOTE: the actual per-turn `pushDiag` feed needs turn timings emitted by
    // the agent loop. The loop's `ModeEv` union (core/loop.zig) has no per-turn
    // timing event yet, so the source data is not available without editing
    // loop.zig (RELIABILITY-owned). The gate is wired here; the feed is the
    // documented residual (see PR body / report).
    sink_impl.fmt.diag_enabled = run_cmd.diag;

    var reg: PolicyToolRegistry = undefined;
    var tool_audit_seq: u64 = 1;
    const tool_audit = PolicyToolAudit{
        .alloc = alloc,
        .hooks = audit_hooks,
        .sid = sid,
        .seq = &tool_audit_seq,
    };
    reg.init(pol, tools_rt.registry(), tool_audit);
    var tool_auth_impl = PolicyToolAuth{
        .alloc = alloc,
        .pol = pol,
        .sid = sid,
        .audit_emitter = audit_hooks.audit_emitter,
        .now_ms = audit_hooks.now_ms,
        .seq = &tool_audit_seq,
    };
    var cmd_cache = core.loop.CmdCache.init(alloc);
    defer cmd_cache.deinit();
    const approval_bind = try loadApprovalBindAlloc(alloc, defaultIo(), home);
    defer approval_bind.deinit(alloc);
    const approval_loc = try getApprovalLocAlloc(alloc, defaultIo());
    defer freeApprovalLoc(alloc, approval_loc);

    if (activity_sink) |sink| sink.emit(.{ .prompt = .{
        .session_id = sid,
        .prompt_chars = prompt.len,
    } });
    var activity_mode: ActivityModeSink = undefined;
    const mode = if (activity_sink) |sink| blk: {
        activity_mode = .{
            .inner = &sink_impl.mode_sink,
            .activity_sink = sink,
            .sid = sid,
        };
        break :blk &activity_mode.mode_sink;
    } else &sink_impl.mode_sink;

    _ = try core.loop.run(.{
        .alloc = alloc,
        .sid = sid,
        .prompt = prompt,
        .model = resolveDefault(run_cmd.cfg.model),
        .provider_label = run_cmd.cfg.provider,
        .provider = provider,
        .store = store,
        .reg = reg.registry(),
        .tool_auth = &tool_auth_impl.tool_auth,
        .mode = mode,
        .system_prompt = sys_prompt,
        .provider_opts = run_cmd.thinking.toProviderOpts(),
        .max_turns = run_cmd.max_turns,
        .cmd_cache = &cmd_cache,
        .approval = .{
            .loc = approval_loc,
            .policy = approval_bind,
        },
        .skip_prompt_guard = is_oauth, // OAuth: API rejects <untrusted-input> wrapping
    });

    try sink_impl.fmt.finish();
    if (sink_impl.stop_reason) |reason| {
        if (print_err.mapResult(.{ .stop = reason })) |_| return error.ProviderStopped;
    }
}

const PromptAskCtx = struct {
    ask_hook: core.tools.builtin.AskHook = .{ .vt = &AskBind.vt },
    ask_ui: *AskUiCtx,
    reader: *tui_input.Reader,

    const AskBind = core.tools.builtin.AskHook.Bind(@This(), run);

    fn run(self: *PromptAskCtx, args: core.tools.Call.AskArgs) ![]u8 {
        return self.ask_ui.runOnMain(self.reader, args);
    }
};

const ApprovalAnswer = struct {
    cancelled: bool = false,
    answers: []const struct {
        index: usize = 0,
    } = &.{},
};

const HookApprover = struct {
    approver: core.loop.Approver = .{ .vt = &core.loop.Approver.Bind(@This(), @This().check).vt },
    alloc: std.mem.Allocator,
    hook: *core.tools.builtin.AskHook,
    cache: *core.loop.CmdCache,

    fn check(self: *@This(), key: core.loop.CmdCache.Key, cached: bool) !void {
        if (cached) return;

        const summary = try approvalSummaryFromKeyAlloc(self.alloc, key);
        defer self.alloc.free(summary);
        const question = try std.fmt.allocPrint(
            self.alloc,
            "Run {s}? This action was derived from untrusted input.",
            .{summary},
        );
        defer self.alloc.free(question);

        const options = [_]core.tools.Call.AskArgs.Option{
            .{ .label = "Approve" },
            .{ .label = "Deny" },
        };
        const questions = [_]core.tools.Call.AskArgs.Question{
            .{
                .id = "approve",
                .header = "Approval required",
                .question = question,
                .options = options[0..],
                .allow_other = false,
            },
        };

        const raw = try self.hook.run(.{ .questions = questions[0..] });
        defer self.alloc.free(raw);

        var parsed = try std.json.parseFromSlice(ApprovalAnswer, self.alloc, raw, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        if (parsed.value.cancelled) return error.ApprovalDenied;
        if (parsed.value.answers.len == 0) return error.ApprovalDenied;
        if (parsed.value.answers[0].index != 0) return error.ApprovalDenied;
        try self.cache.add(key);
    }
};

fn approvalSummaryFromKeyAlloc(alloc: std.mem.Allocator, key: core.loop.CmdCache.Key) ![]u8 {
    return switch (key.tool) {
        .write => blk: {
            var parsed = try std.json.parseFromSlice(core.tools.Call.WriteArgs, alloc, key.cmd, .{
                .allocate = .alloc_always,
                .ignore_unknown_fields = true,
            });
            defer parsed.deinit();
            break :blk std.fmt.allocPrint(alloc, "write {s}", .{parsed.value.path});
        },
        .bash => blk: {
            var parsed = try std.json.parseFromSlice(core.tools.Call.BashArgs, alloc, key.cmd, .{
                .allocate = .alloc_always,
                .ignore_unknown_fields = true,
            });
            defer parsed.deinit();
            break :blk std.fmt.allocPrint(alloc, "bash `{s}`", .{parsed.value.cmd});
        },
        .edit => blk: {
            var parsed = try std.json.parseFromSlice(core.tools.Call.EditArgs, alloc, key.cmd, .{
                .allocate = .alloc_always,
                .ignore_unknown_fields = true,
            });
            defer parsed.deinit();
            break :blk std.fmt.allocPrint(alloc, "edit {s}", .{parsed.value.path});
        },
        .web => blk: {
            var parsed = try std.json.parseFromSlice(core.tools.Call.WebArgs, alloc, key.cmd, .{
                .allocate = .alloc_always,
                .ignore_unknown_fields = true,
            });
            defer parsed.deinit();
            break :blk core.tools.web.approvalSummaryAlloc(alloc, parsed.value);
        },
        else => alloc.dupe(u8, key.cmd),
    };
}

fn runJson(
    alloc: std.mem.Allocator,
    run_cmd: cli.Run,
    sid: []const u8,
    provider: *core.providers.Provider,
    store: *core.session.SessionStore,
    pol: *const RuntimePolicy,
    tools_rt: *core.tools.builtin.Runtime,
    in: *std.Io.Reader,
    out: *std.Io.Writer,
    sys_prompt: ?[]const u8,
    audit_hooks: AuditHooks,
    activity_sink: ?*activity.ActivitySink,
    is_oauth: bool,
) !void {
    const home = run_cmd.home;
    var sink_impl = JsonSink{
        .alloc = alloc,
        .out = out,
    };

    const popts = run_cmd.thinking.toProviderOpts();
    var cmd_cache = core.loop.CmdCache.init(alloc);
    defer cmd_cache.deinit();
    const approval_bind = try loadApprovalBindAlloc(alloc, defaultIo(), home);
    defer approval_bind.deinit(alloc);
    const approval_loc = try getApprovalLocAlloc(alloc, defaultIo());
    defer freeApprovalLoc(alloc, approval_loc);
    const tctx = TurnCtx{
        .alloc = alloc,
        .provider = provider,
        .store = store,
        .pol = pol,
        .tools_rt = tools_rt,
        .mode = &sink_impl.mode_sink,
        .max_turns = run_cmd.max_turns,
        .cmd_cache = &cmd_cache,
        .approval_bind = approval_bind,
        .approval_loc = approval_loc,
        .audit_hooks = audit_hooks,
        .activity_sink = activity_sink,
        .skip_prompt_guard = is_oauth,
    };

    if (run_cmd.prompt) |prompt| {
        try tctx.run(.{
            .sid = sid,
            .prompt = prompt,
            .model = resolveDefault(run_cmd.cfg.model),
            .provider_label = resolveDefaultProvider(run_cmd.cfg.provider),
            .provider_opts = popts,
            .system_prompt = sys_prompt,
        });
        return;
    }

    var turn_ct: usize = 0;
    while (try readLineAlloc(alloc, in, 64 * 1024)) |raw_line| {
        defer alloc.free(raw_line);

        var line = raw_line;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;

        try tctx.run(.{
            .sid = sid,
            .prompt = trimmed,
            .model = resolveDefault(run_cmd.cfg.model),
            .provider_label = resolveDefaultProvider(run_cmd.cfg.provider),
            .provider_opts = popts,
            .system_prompt = sys_prompt,
        });
        turn_ct += 1;
    }
    if (turn_ct == 0) return error.EmptyPrompt;
}

fn runTui(
    alloc: std.mem.Allocator,
    run_cmd: cli.Run,
    sid: *([]u8),
    provider: *core.providers.Provider,
    store: *core.session.SessionStore,
    pol: *const RuntimePolicy,
    tools_rt: *core.tools.builtin.Runtime,
    in: *std.Io.Reader,
    out: *std.Io.Writer,
    session_dir_path: ?[]const u8,
    no_session: bool,
    sys_prompt_arg: ?[]const u8,
    is_sub: bool,
    audit_hooks: AuditHooks,
    tui_hooks: TuiHooks,
    activity_sink: ?*activity.ActivitySink,
    native_rt: ?*NativeProviderRuntime,
    needs_login: ?NativeProviderKind,
) !void {
    const home = run_cmd.home;
    var ctl_audit = RuntimeCtlAudit{ .hooks = audit_hooks };
    var model: []const u8 = resolveDefault(run_cmd.cfg.model);
    var model_owned: ?[]u8 = null;
    defer if (model_owned) |m| alloc.free(m);
    var provider_label: []const u8 = resolveDefaultProvider(run_cmd.cfg.provider);
    var provider_owned: ?[]u8 = null;
    defer if (provider_owned) |p| alloc.free(p);
    var sys_prompt: ?[]const u8 = sys_prompt_arg;
    var sys_prompt_owned: ?[]u8 = null;
    defer if (sys_prompt_owned) |s| alloc.free(s);

    // Model cycle list: from config or default
    const cfg_models = run_cmd.cfg.enabled_models;
    const models_list: []const []const u8 = if (cfg_models) |m| blk: {
        const ptr: [*]const []const u8 = @ptrCast(m.ptr);
        break :blk ptr[0..m.len];
    } else &model_cycle;

    const cwd_path = getProjectPath(alloc, defaultIo(), home) catch "";
    defer if (cwd_path.len > 0) alloc.free(cwd_path);
    const branch = getGitBranch(alloc) catch "";
    defer if (branch.len > 0) alloc.free(branch);

    // Sanitize all external text before TUI: model/provider/cwd/branch may
    // originate from JSON, env vars, CLI args, or VCS that contain non-UTF-8.
    const safe_model = try ensureUtf8OrSanitize(alloc, model);
    defer if (safe_model.owned) |o| alloc.free(o);
    const safe_provider = try ensureUtf8OrSanitize(alloc, provider_label);
    defer if (safe_provider.owned) |o| alloc.free(o);
    const safe_cwd = try ensureUtf8OrSanitize(alloc, cwd_path);
    defer if (safe_cwd.owned) |o| alloc.free(o);
    const safe_branch = try ensureUtf8OrSanitize(alloc, branch);
    defer if (safe_branch.owned) |o| alloc.free(o);

    const tsz = tui_term.size(std.posix.STDOUT_FILENO) orelse tui_term.Size{ .w = 80, .h = 24 };
    var ui = try tui_harness.Ui.initFull(alloc, tsz.w, tsz.h, safe_model.text, safe_provider.text, safe_cwd.text, safe_branch.text, run_cmd.cfg.theme);
    defer ui.deinit();
    ui.img_cap = @import("../modes/tui/image.zig").detect();
    ui.panels.ctx_limit = modelCtxWindow(model);
    ui.panels.is_sub = is_sub;

    _ = tui_term.installSigwinch();
    try tui_render.Renderer.setup(out);
    try tui_render.Renderer.setTitle(out, safe_cwd.text);

    defer {
        tui_render.Renderer.setTitle(out, "") catch {}; // cleanup: propagation impossible
        tui_render.Renderer.cleanup(out) catch {}; // cleanup: propagation impossible
    }

    var sink_impl = TuiSink{
        .ui = &ui,
        .out = out,
    };

    const stdin_fd = tui_hooks.stdin_fd;
    const is_tty = tui_hooks.live orelse isTty(stdin_fd);

    // Enable raw mode early so the InputWatcher's poll() works for -p prompts
    if (is_tty and tui_hooks.raw_mode) {
        if (!tui_term.enableRaw(stdin_fd)) return error.TerminalSetupFailed;
    }
    defer if (is_tty and tui_hooks.raw_mode) tui_term.restore(stdin_fd);

    var watcher = try InputWatcher.init(stdin_fd);
    defer watcher.deinit();

    var cmd_cache = core.loop.CmdCache.init(alloc);
    defer cmd_cache.deinit();
    const approval_bind = try loadApprovalBindAlloc(alloc, defaultIo(), home);
    defer approval_bind.deinit(alloc);
    const approval_loc = try getApprovalLocAlloc(alloc, defaultIo());
    defer freeApprovalLoc(alloc, approval_loc);
    var bg_mgr = try bg.Manager.initWithOpts(alloc, .{
        .home = home,
        .tmp_dir = run_cmd.tmp_dir,
        .pz_state_dir = run_cmd.state_dir,
        .xdg_state_home = run_cmd.xdg_state_home,
        .audit_emitter = audit_hooks.audit_emitter,
        .now_ms = audit_hooks.now_ms,
    });
    defer bg_mgr.deinit();
    try syncBgFooter(alloc, &ui, &bg_mgr);

    var ask_ui_ctx = AskUiCtx{
        .alloc = alloc,
        .ui = &ui,
        .out = out,
        .pause = &watcher.pause_ctl,
    };
    var prompt_reader = tui_input.Reader.init(stdin_fd);
    var prompt_ask_ctx = PromptAskCtx{
        .ask_ui = &ask_ui_ctx,
        .reader = &prompt_reader,
    };
    var prompt_approver_impl = HookApprover{
        .alloc = alloc,
        .hook = &prompt_ask_ctx.ask_hook,
        .cache = &cmd_cache,
    };

    const tctx = TurnCtx{
        .alloc = alloc,
        .provider = provider,
        .store = store,
        .pol = pol,
        .tools_rt = tools_rt,
        .mode = &sink_impl.mode_sink,
        .max_turns = run_cmd.max_turns,
        .cancel = &watcher.cancel_src,
        .cmd_cache = &cmd_cache,
        .approval_bind = approval_bind,
        .approval_loc = approval_loc,
        .approver = &prompt_approver_impl.approver,
        .activity_sink = activity_sink,
        .skip_prompt_guard = is_sub,
    };
    defer tools_rt.ask_hook = null;
    var thinking = run_cmd.thinking;
    var popts = thinking.toProviderOpts();
    var auto_compact_on: bool = true;
    ui.panels.thinking_label = thinkingLabel(thinking);
    ui.border_fg = thinkingBorderFg(thinking);

    // Background version check (TUI only, skip for dev builds)
    const force_ver = getenv("PZ_FORCE_VERSION_CHECK") != null;
    const skip_ver = (!force_ver and builtin.is_test) or
        getenv("PZ_SKIP_VERSION_CHECK") != null or
        (!force_ver and std.mem.indexOf(u8, cli.version, "-dev") != null);
    var ver_check = version_check.Checker.init();
    var ver_notice_done = skip_ver;
    if (!skip_ver) try ver_check.spawn();
    defer ver_check.deinit();

    // Startup info matching pi's display
    const is_resumed = switch (run_cmd.session) {
        .cont, .resm, .explicit => true,
        .auto => false,
    };
    if (is_resumed) {
        const restored = try tryRestoreSessionIntoUi(alloc, &ui, session_dir_path, no_session, sid.*);
        if (!restored) try showStartup(alloc, run_cmd.io, &ui, true, home);
    } else {
        try showStartup(alloc, run_cmd.io, &ui, false, home);
    }

    // Set terminal title (OSC 0)
    try out.writeAll("\x1b]0;pz\x07");
    defer out.writeAll("\x1b]0;\x07") catch {}; // cleanup: propagation impossible

    try ui.draw(out);
    try maybeShowVersionUpdate(alloc, &ui, &ver_check, &ver_notice_done, out);

    // Auto-login: start OAuth flow on startup if auth is missing or expired.
    // Skip when using --provider-cmd (tests) or --no-config (no real auth expected).
    if (run_cmd.cfg.provider_cmd == null and !run_cmd.no_config) {
        const login_prov: ?core.providers.auth.Provider = if (native_rt) |nrt|
            nrt.expiredOAuthProvider()
        else if (needs_login) |kind| switch (kind) {
            .anthropic => .anthropic,
            .openai => .openai,
            .openrouter => .openrouter,
            .google => .google,
            .mistral => .mistral,
            .groq => .groq,
            .deepseek => .deepseek,
        } else null;

        if (login_prov) |prov| {
            try ui.tr.infoText("starting login...");
            ui.tr.scrollToBottom();
            try ui.draw(out);
            var login_buf: [4096]u8 = undefined;
            var login_writer: std.Io.Writer = .fixed(&login_buf);
            runLoginFlow(alloc, &login_writer, .{
                .prov = prov,
                .prov_name = core.providers.auth.providerName(prov),
                .key = "",
            }, audit_hooks.auth()) catch |err| {
                const em = try report.fromName(alloc, @errorName(err));
                defer alloc.free(em);
                try ui.tr.infoText(em);
            };
            const login_out = login_writer.buffered();
            if (login_out.len > 0) {
                try infoTextSafe(alloc, &ui, login_out);
            }
            if (native_rt) |nrt| {
                nrt.reloadAuth(alloc, audit_hooks.auth()) catch {};
            }
            try ui.draw(out);
        }
    }

    if (run_cmd.prompt) |prompt| {
        var init_cmd_buf: [4096]u8 = undefined;
        var init_cmd_writer: std.Io.Writer = .fixed(&init_cmd_buf);
        const cmd = try handleSlashCommand(
            alloc,
            prompt,
            sid,
            &model,
            &model_owned,
            &provider_label,
            &provider_owned,
            pol,
            tools_rt,
            &bg_mgr,
            session_dir_path,
            no_session,
            sys_prompt,
            &init_cmd_writer,
            audit_hooks,
            &ctl_audit,
            home,
        );
        if (cmd == .quit) return;
        if (cmd == .clear) {
            ui.clearTranscript();
        }
        if (cmd == .copy) {
            try runtimeCtlAudit(&ctl_audit, alloc, "copy", .cmd, runtimeCfgResName(), null, .start, null, &.{});
            try copyLastResponse(alloc, &ui, pol);
            try runtimeCtlAudit(&ctl_audit, alloc, "copy", .cmd, runtimeCfgResName(), null, .ok, null, &.{});
        }
        if (cmd == .cost) {
            try showCost(alloc, &ui);
        }
        if (cmd == .reload) {
            const reloaded = try reloadContextWithAudit(alloc, &sys_prompt, &sys_prompt_owned, &ctl_audit, core.context.load, home);
            switch (reloaded) {
                .loaded => try ui.tr.infoText("[context reloaded]"),
                .empty => try ui.tr.infoText("[context reloaded (no files)]"),
            }
        }
        if (cmd == .resumed) {
            _ = try tryRestoreSessionIntoUi(alloc, &ui, session_dir_path, no_session, sid.*);
        }
        if (cmd == .select_model) {
            var cur_idx: usize = 0;
            for (models_list, 0..) |m, i| {
                if (std.mem.eql(u8, model, m)) {
                    cur_idx = i;
                    break;
                }
            }
            ui.ov = tui_overlay.Overlay.init(models_list, cur_idx);
        }
        if (cmd == .select_session) {
            _ = try showResumeOverlay(alloc, &ui, session_dir_path);
        }
        if (cmd == .select_settings) {
            ui.ov = try buildSettingsOverlay(alloc, &ui, auto_compact_on);
        }
        if (cmd == .select_fork) {
            if (session_dir_path) |sdp| {
                if (listUserMessages(alloc, sdp, sid.*)) |msgs| {
                    if (msgs.len > 0) {
                        var ov = tui_overlay.Overlay.initDyn(msgs, "Fork from message", .session);
                        ov.sel = msgs.len - 1;
                        ov.fixScroll();
                        ov.kind = .fork;
                        ui.ov = ov;
                    }
                } else |_| {}
            }
        }
        if (cmd == .compacted) {
            ui.panels.noteCompaction();
        }
        if (cmd == .handled or cmd == .compacted or cmd == .resumed or cmd == .clear or cmd == .copy or cmd == .cost or cmd == .reload or cmd == .select_model or cmd == .select_session or cmd == .select_settings or cmd == .select_fork) {
            const cmd_text = init_cmd_writer.buffered();
            if (cmd_text.len > 0) {
                try infoTextSafe(alloc, &ui, cmd_text);
                ui.tr.scrollToBottom();
            }
            try syncBgFooter(alloc, &ui, &bg_mgr);
            try ui.setModel(model);
            try ui.setProvider(provider_label);
        }
        if (cmd == .unhandled) {
            try ui.tr.userText(prompt);
            ui.tr.scrollToBottom();
            try ui.draw(out);
            if (is_tty and !watcher.start()) try ui.tr.infoText("[ESC cancel unavailable]");
            defer if (is_tty) watcher.join(null);
            try tctx.run(.{
                .sid = sid.*,
                .prompt = prompt,
                .model = model,
                .provider_label = provider_label,
                .provider_opts = popts,
                .system_prompt = sys_prompt,
            });
            if (is_tty and watcher.isCanceled()) try ui.tr.infoText("[canceled]");
            ui.panels.run_state = .idle;
        } else {
            try ui.setModel(model);
            try ui.setProvider(provider_label);
            try ui.draw(out);
        }
        // Fall through to input loop (stay in TUI like pi does)
    }

    if (is_tty) {
        // Raw mode already enabled above (before -p prompt path)
        var live_turn = try LiveTurn.init(alloc);
        defer live_turn.deinit();

        // Wire cancel signal to native provider so ESC during SSE streaming
        // triggers CancelPoll check in retryLoop/sseNext. Clear before
        // live_turn.deinit() to prevent dangling ctx pointer.
        if (native_rt) |nrt| {
            nrt.setCancel(&live_turn.cancel_flag.cancel_poll);
        }
        defer if (native_rt) |nrt| nrt.clearCancel();

        var live_sink_impl = LiveTurnSink{
            .live = &live_turn,
        };

        var live_cmd_cache = core.loop.CmdCache.init(alloc);
        defer live_cmd_cache.deinit();
        const live_approval_bind = try loadApprovalBindAlloc(alloc, defaultIo(), home);
        defer live_approval_bind.deinit(alloc);
        const live_approval_loc = try getApprovalLocAlloc(alloc, defaultIo());
        defer freeApprovalLoc(alloc, live_approval_loc);
        var live_tctx = TurnCtx{
            .alloc = alloc,
            .provider = provider,
            .store = store,
            .pol = pol,
            .tools_rt = tools_rt,
            .mode = &live_sink_impl.mode_sink,
            .max_turns = run_cmd.max_turns,
            .cancel = &live_turn.cancel_flag.cancel_src,
            .abort_slot = &live_turn.abort_slot,
            .cmd_cache = &live_cmd_cache,
            .approval_bind = live_approval_bind,
            .approval_loc = live_approval_loc,
            .activity_sink = activity_sink,
            .skip_prompt_guard = is_sub,
        };
        var reader = tui_input.Reader.initWithNotify2(stdin_fd, bg_mgr.wakeFd(), live_turn.wakeFd());
        var live_ask_ctx = LiveAskCtx{
            .live = &live_turn,
        };
        tools_rt.ask_hook = &live_ask_ctx.ask_hook;
        var live_approver_impl = HookApprover{
            .alloc = alloc,
            .hook = tools_rt.ask_hook.?,
            .cache = &live_cmd_cache,
        };

        live_tctx.approver = &live_approver_impl.approver;
        var pending = PendingQueue{};
        defer pending.deinit(alloc);
        const input_mode: tui_panels.InputMode = .steering;
        var retried_overflow = false;
        var stop_after_completions = tui_hooks.stop_after_completions;
        syncInputFooter(&ui, input_mode, pending.total());
        if (tui_hooks.submit_text) |prompt| {
            try startLiveTurnWithPrompt(&live_turn, &live_tctx, &ui, sid.*, prompt, model, provider_label, popts, sys_prompt, &retried_overflow);
            try ui.draw(out);
        }

        while (true) {
            try maybeShowVersionUpdate(alloc, &ui, &ver_check, &ver_notice_done, out);
            if (tui_term.pollResize()) {
                if (tui_term.size(std.posix.STDOUT_FILENO)) |sz| {
                    try ui.resize(sz.w, sz.h);
                    try ui.draw(out);
                }
            }

            const ev = reader.next();
            switch (ev) {
                .key => |key| {
                    // Overlay intercepts keys when open
                    if (ui.ov != null) {
                        switch (key) {
                            .up => ui.ov.?.up(),
                            .down => ui.ov.?.down(),
                            .enter => {
                                const sel = ui.ov.?.selected() orelse {
                                    ui.ov.?.deinit(alloc);
                                    ui.ov = null;
                                    continue;
                                };
                                switch (ui.ov.?.kind) {
                                    .model => {
                                        const argv: core.audit.Str = .{ .text = sel, .vis = .@"pub" };
                                        try runtimeCtlAudit(&ctl_audit, alloc, "model", .cfg, runtimeCfgResName(), argv, .start, null, &.{});
                                        try replaceOwnedText(alloc, &model, &model_owned, sel);
                                        const attrs = [_]core.audit.Attribute{
                                            .{
                                                .key = "provider",
                                                .vis = .@"pub",
                                                .val = .{ .str = provider_label },
                                            },
                                        };
                                        try runtimeCtlAudit(&ctl_audit, alloc, "model", .cfg, runtimeCfgResName(), argv, .ok, null, &attrs);
                                        ui.panels.ctx_limit = modelCtxWindow(model);
                                        try ui.setModel(model);
                                        ui.ov.?.deinit(alloc);
                                        ui.ov = null;
                                    },
                                    .session => {
                                        const argv: core.audit.Str = .{ .text = sel, .vis = .mask };
                                        try runtimeCtlAudit(&ctl_audit, alloc, "resume", .sess, runtimeSessResName(), argv, .start, null, &.{});
                                        const next_sid = try alloc.dupe(u8, sel);
                                        const prev_sid = sid.*;
                                        sid.* = next_sid;
                                        const ok = tryRestoreSessionIntoUi(alloc, &ui, session_dir_path, no_session, sid.*) catch |err| {
                                            // Rollback: restore previous sid.
                                            sid.* = prev_sid;
                                            alloc.free(next_sid);
                                            return err;
                                        };
                                        alloc.free(prev_sid);
                                        if (ok) {
                                            try runtimeCtlAudit(&ctl_audit, alloc, "resume", .sess, runtimeSessResName(), argv, .ok, null, &.{});
                                            const msg = try std.fmt.allocPrint(alloc, "resumed session {s}", .{sid.*});
                                            defer alloc.free(msg);
                                            try ui.tr.infoText(msg);
                                        }
                                        ui.ov.?.deinit(alloc);
                                        ui.ov = null;
                                    },
                                    .settings => {
                                        // Toggle the selected setting
                                        ui.ov.?.toggle();
                                        applySettingsToggle(&ui, ui.ov.?.sel, ui.ov.?.getToggle(ui.ov.?.sel) orelse false, &auto_compact_on);
                                    },
                                    .fork => {
                                        try runtimeCtlAudit(&ctl_audit, alloc, "fork", .sess, runtimeSessResName(), null, .start, null, &.{});
                                        const next_sid = try newSid(alloc);
                                        errdefer alloc.free(next_sid);
                                        if (session_dir_path) |sdp| {
                                            try forkSessionFile(sdp, sid.*, next_sid);
                                        }
                                        const prev_sid = sid.*;
                                        sid.* = next_sid;
                                        ui.ed.setText(sel) catch |err| {
                                            sid.* = prev_sid;
                                            return err;
                                        };
                                        alloc.free(prev_sid);
                                        try ui.tr.infoText("[forked session]");
                                        try runtimeCtlAudit(&ctl_audit, alloc, "fork", .sess, runtimeSessResName(), null, .ok, null, &.{});
                                        ui.ov.?.deinit(alloc);
                                        ui.ov = null;
                                    },
                                    .login => {
                                        const msg = try std.fmt.allocPrint(
                                            alloc,
                                            "Direct {s} login is disabled by policy; " ++
                                                "configure PZ_PROVIDER_CMD for an approved CLI adapter.",
                                            .{sel},
                                        );
                                        defer alloc.free(msg);
                                        try ui.tr.infoText(msg);
                                        ui.ov.?.deinit(alloc);
                                        ui.ov = null;
                                    },
                                    .logout => {
                                        // Remove credentials for selected provider
                                        if (parseAuthProvider(sel)) |prov| {
                                            try core.providers.auth.logoutWithHooks(alloc, prov, audit_hooks.auth());
                                            const msg2 = try std.fmt.allocPrint(alloc, "logged out of {s}", .{core.providers.auth.providerName(prov)});
                                            defer alloc.free(msg2);
                                            try ui.tr.infoText(msg2);
                                        }
                                        ui.ov.?.deinit(alloc);
                                        ui.ov = null;
                                    },
                                    .queue => {
                                        ui.ov.?.deinit(alloc);
                                        ui.ov = null;
                                    },
                                }
                            },
                            .esc, .ctrl_c, .ctrl_l => {
                                ui.ov.?.deinit(alloc);
                                ui.ov = null;
                            },
                            else => {}, // other keys ignored while overlay is active
                        }
                        try ui.draw(out);
                        continue;
                    }

                    // Command preview intercept
                    if (ui.picker) |*cp| {
                        switch (key) {
                            .up => {
                                cp.up();
                                try ui.draw(out);
                                continue;
                            },
                            .down => {
                                cp.down();
                                try ui.draw(out);
                                continue;
                            },
                            .tab, .enter => {
                                if (ui.path_items != null) {
                                    // File mode: replace last word
                                    if (cp.selectedArg()) |path| {
                                        const text = ui.ed.text();
                                        const cur = ui.ed.cursor();
                                        const ws = ui.ed.wordStart(cur);
                                        const has_at = ws < cur and text[ws] == '@';
                                        const at_s: []const u8 = if (has_at) "@" else "";
                                        const new_text = std.fmt.allocPrint(alloc, "{s}{s}{s}{s}", .{
                                            text[0..ws], at_s, path, text[cur..],
                                        }) catch continue;
                                        defer alloc.free(new_text);
                                        const new_cur = ws + at_s.len + path.len;
                                        ui.ed.buf.items.len = 0;
                                        try ui.ed.buf.appendSlice(ui.ed.alloc, new_text);
                                        ui.ed.cur = new_cur;
                                    }
                                } else if (cp.arg_src != null) {
                                    // Arg mode: complete arg + submit on Enter.
                                    if (cp.selectedArg()) |arg| {
                                        const text = ui.ed.text();
                                        const sp = std.mem.indexOfScalar(u8, text, ' ') orelse text.len;
                                        ui.ed.buf.items.len = sp;
                                        try ui.ed.buf.appendSlice(ui.ed.alloc, " ");
                                        try ui.ed.buf.appendSlice(ui.ed.alloc, arg);
                                        ui.ed.cur = ui.ed.buf.items.len;
                                    }
                                    if (key == .enter) {
                                        ui.picker = null;
                                        ui.clearPathItems();
                                        break; // complete + submit
                                    }
                                } else {
                                    // Cmd mode: if editor already has arguments (space after /cmd),
                                    // submit directly instead of autocompleting.
                                    const text = ui.ed.text();
                                    if (std.mem.indexOfScalar(u8, text, ' ') != null) {
                                        ui.picker = null;
                                        ui.clearPathItems();
                                        break; // fall through to submit handling below
                                    }
                                    // No arguments yet: fill command name
                                    const cmd = cp.selected();
                                    ui.ed.buf.items.len = 0;
                                    try ui.ed.buf.appendSlice(ui.ed.alloc, "/");
                                    try ui.ed.buf.appendSlice(ui.ed.alloc, cmd.name);
                                    try ui.ed.buf.appendSlice(ui.ed.alloc, " ");
                                    ui.ed.cur = ui.ed.buf.items.len;
                                }
                                ui.picker = null;
                                ui.arg_src = resolveArgSrc(ui.ed.text(), models_list);
                                try ui.updatePreview();
                                try ui.draw(out);
                                continue;
                            },
                            .esc => {
                                ui.picker = null;
                                ui.clearPathItems();
                                try ui.draw(out);
                                continue;
                            },
                            else => {}, // other keys fall through to editor when picker is active
                        }
                    }

                    // Capture editor text before onKey clears it on submit
                    const snap = ui.editorText();
                    var pre: ?[]u8 = if (snap.len > 0) try alloc.dupe(u8, snap) else null;

                    const act = try ui.onKey(key);
                    switch (act) {
                        .submit => {
                            const prompt = pre orelse {
                                try ui.draw(out);
                                continue;
                            };
                            pre = null; // ownership transferred
                            defer alloc.free(prompt);

                            var cmd_buf: [4096]u8 = undefined;
                            var cmd_writer: std.Io.Writer = .fixed(&cmd_buf);
                            const cmd = try handleSlashCommand(
                                alloc,
                                prompt,
                                sid,
                                &model,
                                &model_owned,
                                &provider_label,
                                &provider_owned,
                                pol,
                                tools_rt,
                                &bg_mgr,
                                session_dir_path,
                                no_session,
                                sys_prompt,
                                &cmd_writer,
                                audit_hooks,
                                &ctl_audit,
                                home,
                            );
                            if (cmd == .quit) return;
                            if (cmd == .clear) {
                                ui.clearTranscript();
                                try ui.draw(out);
                                continue;
                            }
                            if (cmd == .copy) {
                                try runtimeCtlAudit(&ctl_audit, alloc, "copy", .cmd, runtimeCfgResName(), null, .start, null, &.{});
                                try copyLastResponse(alloc, &ui, pol);
                                try runtimeCtlAudit(&ctl_audit, alloc, "copy", .cmd, runtimeCfgResName(), null, .ok, null, &.{});
                                try ui.draw(out);
                                continue;
                            }
                            if (cmd == .cost) {
                                try showCost(alloc, &ui);
                                try ui.draw(out);
                                continue;
                            }
                            if (cmd == .reload) {
                                const reloaded = try reloadContextWithAudit(alloc, &sys_prompt, &sys_prompt_owned, &ctl_audit, core.context.load, home);
                                switch (reloaded) {
                                    .loaded => try ui.tr.infoText("[context reloaded]"),
                                    .empty => try ui.tr.infoText("[context reloaded (no files)]"),
                                }
                                try ui.draw(out);
                                continue;
                            }
                            if (cmd == .resumed) {
                                _ = try tryRestoreSessionIntoUi(alloc, &ui, session_dir_path, no_session, sid.*);
                            }
                            if (cmd == .select_model) {
                                var cur_idx: usize = 0;
                                for (models_list, 0..) |m, i| {
                                    if (std.mem.eql(u8, model, m)) {
                                        cur_idx = i;
                                        break;
                                    }
                                }
                                ui.ov = tui_overlay.Overlay.init(models_list, cur_idx);
                                try ui.draw(out);
                                continue;
                            }
                            if (cmd == .select_session) {
                                _ = try showResumeOverlay(alloc, &ui, session_dir_path);
                                try ui.draw(out);
                                continue;
                            }
                            if (cmd == .select_settings) {
                                ui.ov = try buildSettingsOverlay(alloc, &ui, auto_compact_on);
                                try ui.draw(out);
                                continue;
                            }
                            if (cmd == .select_fork) {
                                if (session_dir_path) |sdp| {
                                    if (listUserMessages(alloc, sdp, sid.*)) |msgs| {
                                        if (msgs.len > 0) {
                                            var ov = tui_overlay.Overlay.initDyn(msgs, "Fork from message", .session);
                                            ov.sel = msgs.len - 1; // select last message
                                            ov.fixScroll();
                                            ov.kind = .fork;
                                            ui.ov = ov;
                                        }
                                    } else |_| {}
                                }
                                try ui.draw(out);
                                continue;
                            }
                            if (cmd == .select_login) {
                                var ov = tui_overlay.Overlay.init(&core.providers.auth.provider_names, 0);
                                ov.title = "Login disabled by policy";
                                ov.kind = .login;
                                ui.ov = ov;
                                try ui.draw(out);
                                continue;
                            }
                            if (cmd == .select_logout) {
                                const providers = core.providers.auth.listLoggedIn(alloc, home) catch try alloc.alloc(core.providers.auth.Provider, 0);
                                defer alloc.free(providers);
                                if (!try showLogoutOverlay(alloc, &ui, providers)) {
                                    try ui.tr.infoText("no providers logged in");
                                }
                                try ui.draw(out);
                                continue;
                            }
                            if (cmd == .handled or cmd == .compacted or cmd == .resumed) {
                                if (cmd == .compacted) ui.panels.noteCompaction();
                                const cmd_text = cmd_writer.buffered();
                                if (cmd_text.len > 0) {
                                    try infoTextSafe(alloc, &ui, cmd_text);
                                    ui.tr.scrollToBottom();
                                }
                                try syncBgFooter(alloc, &ui, &bg_mgr);
                                try ui.setModel(model);
                                try ui.setProvider(provider_label);
                                try ui.draw(out);
                                continue;
                            }

                            // Bash mode: !cmd or !!cmd
                            if (parseBashCmd(prompt)) |bcmd| {
                                try runBashMode(alloc, &ui, bcmd, sid.*, store, pol);
                                try ui.draw(out);
                                continue;
                            }

                            if (live_turn.isRunning()) {
                                try pending.pushSteering(alloc, prompt);
                                syncInputFooter(&ui, input_mode, pending.total());
                                live_turn.requestCancel();
                                try ui.tr.infoText("(queued steering message)");
                                try ui.draw(out);
                                continue;
                            }

                            try startLiveTurnWithPrompt(&live_turn, &live_tctx, &ui, sid.*, prompt, model, provider_label, popts, sys_prompt, &retried_overflow);
                            try ui.draw(out);
                        },
                        .cancel => {
                            if (pre) |p| alloc.free(p);
                            return;
                        },
                        .interrupt => {
                            if (pre) |p| alloc.free(p);
                            if (live_turn.isRunning()) {
                                const restored = try pending.restoreToEditor(alloc, &ui);
                                syncInputFooter(&ui, input_mode, pending.total());
                                live_turn.requestCancel();
                                if (restored > 0) {
                                    const msg = try std.fmt.allocPrint(alloc, "(restored {d} queued message{s})", .{
                                        restored,
                                        if (restored == 1) "" else "s",
                                    });
                                    defer alloc.free(msg);
                                    try ui.tr.infoText(msg);
                                }
                            }
                            try ui.draw(out);
                        },
                        .cycle_thinking => {
                            if (pre) |p| alloc.free(p);
                            thinking = cycleThinking(thinking);
                            popts = thinking.toProviderOpts();
                            ui.panels.thinking_label = thinkingLabel(thinking);
                            ui.border_fg = thinkingBorderFg(thinking);
                            try ui.draw(out);
                        },
                        .cycle_model => {
                            if (pre) |p| alloc.free(p);
                            model = try cycleModel(alloc, model, &model_owned, models_list);
                            ui.panels.ctx_limit = modelCtxWindow(model);
                            try ui.setModel(model);
                            try ui.draw(out);
                        },
                        .toggle_tools => {
                            if (pre) |p| alloc.free(p);
                            ui.tr.show_tools = !ui.tr.show_tools;
                            try ui.draw(out);
                        },
                        .toggle_thinking => {
                            if (pre) |p| alloc.free(p);
                            ui.tr.show_thinking = !ui.tr.show_thinking;
                            try ui.draw(out);
                        },
                        .kill_to_eol => {
                            if (pre) |p| alloc.free(p);
                            try ui.draw(out);
                        },
                        .@"suspend" => {
                            if (pre) |p| alloc.free(p);
                            // No-op: Ctrl+Z is now undo (handled by editor)
                            try ui.draw(out);
                        },
                        .select_model => {
                            if (pre) |p| alloc.free(p);
                            // Find current model index
                            var cur_idx: usize = 0;
                            for (models_list, 0..) |m, i| {
                                if (std.mem.eql(u8, model, m)) {
                                    cur_idx = i;
                                    break;
                                }
                            }
                            ui.ov = tui_overlay.Overlay.init(models_list, cur_idx);
                            try ui.draw(out);
                        },
                        .ext_editor => {
                            if (pre) |p| alloc.free(p);
                            try runtimeCtlAudit(&ctl_audit, alloc, "editor", .cmd, runtimeCfgResName(), null, .start, null, &.{});
                            tui_term.restore(stdin_fd);
                            const ed_result = openExtEditor(alloc, ui.editorText());
                            _ = tui_term.enableRaw(stdin_fd);
                            if (ed_result) |maybe_txt| {
                                if (maybe_txt) |txt| {
                                    defer alloc.free(txt);
                                    try ui.ed.setText(txt);
                                }
                                try runtimeCtlAudit(&ctl_audit, alloc, "editor", .cmd, runtimeCfgResName(), null, .ok, null, &.{});
                            } else |err| {
                                const detail = try report.inlineMsg(alloc, err);
                                defer alloc.free(detail);
                                const msg = try std.fmt.allocPrint(alloc, "[editor failed: {s}]", .{detail});
                                defer alloc.free(msg);
                                try ui.tr.infoText(msg);
                                try runtimeCtlAudit(&ctl_audit, alloc, "editor", .cmd, runtimeCfgResName(), null, .fail, .{ .text = "editor failed", .vis = .@"pub" }, &.{});
                            }
                            try ui.draw(out);
                        },
                        .queue_followup => {
                            if (pre) |p| alloc.free(p);
                            const snap2 = ui.editorText();
                            if (snap2.len > 0) {
                                try pending.pushFollowUp(alloc, snap2);
                                ui.ed.clear();
                                try ui.updatePreview();
                                syncInputFooter(&ui, input_mode, pending.total());
                                try ui.tr.infoText(if (live_turn.isRunning()) "(queued follow-up message)" else "(queued message)");
                            }
                            try ui.draw(out);
                        },
                        .edit_queued => {
                            if (pre) |p| alloc.free(p);
                            const restored = try pending.restoreToEditor(alloc, &ui);
                            syncInputFooter(&ui, input_mode, pending.total());
                            if (restored == 0) {
                                try ui.tr.infoText("(queue is empty)");
                            } else {
                                const msg = try std.fmt.allocPrint(alloc, "(restored {d} queued message{s})", .{
                                    restored,
                                    if (restored == 1) "" else "s",
                                });
                                defer alloc.free(msg);
                                try ui.tr.infoText(msg);
                            }
                            try ui.draw(out);
                        },
                        .toggle_queue_mode => {
                            if (pre) |p| alloc.free(p);
                            try ui.tr.infoText("(use Enter for steering, Alt+Enter for follow-up)");
                            try ui.draw(out);
                        },
                        .paste_image => {
                            if (pre) |p| alloc.free(p);
                            try pasteImage(alloc, &ui, run_cmd.tmp_dir, pol);
                            try ui.draw(out);
                        },
                        .reverse_cycle_model => {
                            if (pre) |p| alloc.free(p);
                            model = try reverseCycleModel(alloc, model, &model_owned, models_list);
                            ui.panels.ctx_limit = modelCtxWindow(model);
                            try ui.setModel(model);
                            try ui.draw(out);
                        },
                        .tab_complete => {
                            if (pre) |p| alloc.free(p);
                            const tab_text = ui.ed.text();
                            if (tab_text.len > 0 and tab_text[0] == '/') {
                                completeSlashCmd(&ui.ed);
                            } else if (tab_text.len > 0) {
                                try completeFilePath(alloc, &ui);
                            }
                            ui.arg_src = resolveArgSrc(ui.ed.text(), models_list);
                            try ui.updatePreview();
                            try ui.draw(out);
                        },
                        .scroll_up => {
                            if (pre) |p| alloc.free(p);
                            ui.tr.scrollUp(ui.frm.h / 2);
                            try ui.draw(out);
                        },
                        .scroll_down => {
                            if (pre) |p| alloc.free(p);
                            ui.tr.scrollDown(ui.frm.h / 2);
                            try ui.draw(out);
                        },
                        .none => {
                            if (pre) |p| alloc.free(p);
                            ui.arg_src = resolveArgSrc(ui.ed.text(), models_list);
                            try ui.updatePreview();
                            try ui.draw(out);
                        },
                    }
                },
                .mouse => |mev| {
                    ui.onMouse(mev);
                    try ui.draw(out);
                },
                .notify => {
                    while (live_turn.takeAsk()) |ask_txn| {
                        live_turn.finishAsk(ask_txn, ask_ui_ctx.runOnMain(&reader, ask_txn.args.view()));
                    }

                    while (live_turn.popProvider()) |sev| {
                        defer freeProviderEv(alloc, sev.ev);
                        try ui.onProviderSeq(sev.seq, sev.ev);
                    }

                    // Drain agent status updates from loop thread.
                    while (live_turn.popAgent()) |as| {
                        defer alloc.free(as.agent_id);
                        const phase: tui_transcript.AgentPhase = switch (as.phase) {
                            .running => .running,
                            .done => .done,
                            .err => .err,
                            .canceled => .canceled,
                        };
                        ui.tr.updateAgent(as.agent_id, phase) catch {
                            try ui.tr.agentBlock(as.agent_id, phase);
                        };
                    }

                    if (live_turn.takeCompletion()) |done| {
                        defer if (done.err_name) |name| alloc.free(name);
                        var compact_out: AutoCompactOutcome = .skipped;

                        if (shouldRetryOverflow(alloc, &live_turn, model, retried_overflow)) {
                            compact_out = try autoCompact(alloc, &ui, out, sid.*, session_dir_path, no_session, true);
                            if (compact_out == .compacted) {
                                const retry_req = (try live_turn.cloneReq(alloc)) orelse return error.TestUnexpectedResult;
                                defer {
                                    var req = retry_req;
                                    req.deinit(alloc);
                                }
                                try ui.tr.infoText("[overflow detected: compacting and retrying]");
                                live_turn.start(&live_tctx, .{
                                    .sid = retry_req.sid,
                                    .prompt = retry_req.prompt,
                                    .model = retry_req.model,
                                    .provider_label = retry_req.provider_label,
                                    .provider_opts = retry_req.provider_opts,
                                    .system_prompt = retry_req.system_prompt,
                                }) catch |start_err| {
                                    const detail = try report.inlineMsg(alloc, start_err);
                                    defer alloc.free(detail);
                                    const msg = try std.fmt.allocPrint(alloc, "[retry start failed: {s}]", .{detail});
                                    defer alloc.free(msg);
                                    try ui.tr.infoText(msg);
                                    ui.panels.run_state = .idle;
                                    retried_overflow = false;
                                    try flushBgDone(alloc, &ui, &bg_mgr);
                                    try syncBgFooter(alloc, &ui, &bg_mgr);
                                    try ui.draw(out);
                                    continue;
                                };
                                retried_overflow = true;
                                ui.panels.run_state = .streaming;
                                try flushBgDone(alloc, &ui, &bg_mgr);
                                try syncBgFooter(alloc, &ui, &bg_mgr);
                                try ui.draw(out);
                                continue;
                            }
                        }

                        retried_overflow = false;
                        if (done.err_name) |name| {
                            if (compact_out != .stopped) {
                                const msg = try report.fromName(alloc, name);
                                defer alloc.free(msg);
                                try ui.tr.infoText(msg);
                            }
                        } else if (auto_compact_on) {
                            _ = try autoCompact(alloc, &ui, out, sid.*, session_dir_path, no_session, false);
                        }

                        if (pending.popNext()) |next_turn| {
                            defer alloc.free(next_turn.text);
                            syncInputFooter(&ui, input_mode, pending.total());
                            live_turn.start(&live_tctx, .{
                                .sid = sid.*,
                                .prompt = next_turn.text,
                                .model = model,
                                .provider_label = provider_label,
                                .provider_opts = popts,
                                .system_prompt = sys_prompt,
                            }) catch |start_err| {
                                const detail = try report.inlineMsg(alloc, start_err);
                                defer alloc.free(detail);
                                const msg = try std.fmt.allocPrint(alloc, "[queue start failed: {s}]", .{detail});
                                defer alloc.free(msg);
                                try ui.tr.infoText(msg);
                                ui.panels.run_state = .idle;
                                try flushBgDone(alloc, &ui, &bg_mgr);
                                try syncBgFooter(alloc, &ui, &bg_mgr);
                                try ui.draw(out);
                                continue;
                            };
                            retried_overflow = false;
                            ui.panels.run_state = .streaming;
                            try ui.tr.infoText(if (next_turn.kind == .steering) "(sending queued steering message)" else "(sending queued follow-up message)");
                        } else {
                            ui.panels.run_state = .idle;
                        }
                        if (stop_after_completions) |n| {
                            const next_n = n - 1;
                            stop_after_completions = next_n;
                            if (next_n == 0 and pending.total() == 0 and !live_turn.isRunning()) {
                                try flushBgDone(alloc, &ui, &bg_mgr);
                                try syncBgFooter(alloc, &ui, &bg_mgr);
                                try ui.draw(out);
                                return;
                            }
                        }
                    }

                    try flushBgDone(alloc, &ui, &bg_mgr);
                    try syncBgFooter(alloc, &ui, &bg_mgr);
                    try ui.draw(out);
                    if (tui_hooks.exit_on_idle and !live_turn.isRunning() and pending.total() == 0) return;
                },
                .paste => |text| {
                    if (text.len > 0) {
                        ui.ed.insertSlice(text) catch {
                            try ui.tr.infoText("[paste: invalid UTF-8]");
                        };
                        ui.arg_src = resolveArgSrc(ui.ed.text(), models_list);
                        try ui.updatePreview();
                        try ui.draw(out);
                    }
                },
                .resize => {
                    if (tui_term.size(std.posix.STDOUT_FILENO)) |sz| {
                        try ui.resize(sz.w, sz.h);
                        try ui.draw(out);
                    }
                },
                .none => {
                    if (ui.panels.bg_running > 0) {
                        ui.panels.tickBgSpinner();
                        try ui.draw(out);
                    }
                },
                .err => {
                    try ui.tr.infoText("[stdin read error — exiting]");
                    try ui.draw(out);
                    return;
                },
            }
        }
    } else {
        // Non-TTY (piped input): line-buffered mode for tests/scripts
        var turn_ct: usize = 0;
        var cmd_ct: usize = 0;
        while (try readLineAlloc(alloc, in, 64 * 1024)) |raw_line| {
            defer alloc.free(raw_line);
            try maybeShowVersionUpdate(alloc, &ui, &ver_check, &ver_notice_done, out);

            if (tui_term.pollResize()) {
                if (tui_term.size(std.posix.STDOUT_FILENO)) |sz| {
                    try ui.resize(sz.w, sz.h);
                    try ui.draw(out);
                }
            }

            var line = raw_line;
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            const trimmed = std.mem.trim(u8, line, " \t");
            if (trimmed.len == 0) continue;

            const cmd = try handleSlashCommand(
                alloc,
                trimmed,
                sid,
                &model,
                &model_owned,
                &provider_label,
                &provider_owned,
                pol,
                tools_rt,
                &bg_mgr,
                session_dir_path,
                no_session,
                sys_prompt,
                out,
                audit_hooks,
                &ctl_audit,
                home,
            );
            if (cmd == .quit) return;
            if (cmd == .clear) {
                ui.clearTranscript();
                try ui.draw(out);
                cmd_ct += 1;
                continue;
            }
            if (cmd == .copy) {
                try runtimeCtlAudit(&ctl_audit, alloc, "copy", .cmd, runtimeCfgResName(), null, .start, null, &.{});
                try copyLastResponse(alloc, &ui, pol);
                try runtimeCtlAudit(&ctl_audit, alloc, "copy", .cmd, runtimeCfgResName(), null, .ok, null, &.{});
                try ui.draw(out);
                cmd_ct += 1;
                continue;
            }
            if (cmd == .cost) {
                try showCost(alloc, &ui);
                try ui.draw(out);
                cmd_ct += 1;
                continue;
            }
            if (cmd == .reload) {
                _ = try reloadContextWithAudit(alloc, &sys_prompt, &sys_prompt_owned, &ctl_audit, core.context.load, home);
                try ui.draw(out);
                cmd_ct += 1;
                continue;
            }
            if (cmd == .resumed) {
                _ = try tryRestoreSessionIntoUi(alloc, &ui, session_dir_path, no_session, sid.*);
            }
            if (cmd == .handled or cmd == .compacted or cmd == .resumed) {
                if (cmd == .compacted) ui.panels.noteCompaction();
                try syncBgFooter(alloc, &ui, &bg_mgr);
                try ui.setModel(model);
                try ui.setProvider(provider_label);
                try ui.draw(out);
                cmd_ct += 1;
                continue;
            }

            // Bash mode: !cmd or !!cmd
            if (parseBashCmd(trimmed)) |bcmd| {
                try runBashMode(alloc, &ui, bcmd, sid.*, store, pol);
                try ui.draw(out);
                turn_ct += 1;
                continue;
            }

            try tctx.run(.{
                .sid = sid.*,
                .prompt = trimmed,
                .model = model,
                .provider_label = provider_label,
                .provider_opts = popts,
                .system_prompt = sys_prompt,
            });
            if (auto_compact_on) _ = try autoCompact(alloc, &ui, out, sid.*, session_dir_path, no_session, false);
            turn_ct += 1;
        }
        if (turn_ct == 0 and cmd_ct == 0 and run_cmd.prompt == null) return error.EmptyPrompt;
    }
}

fn runRpc(
    alloc: std.mem.Allocator,
    run_cmd: cli.Run,
    sid: *([]u8),
    provider: *core.providers.Provider,
    store: *core.session.SessionStore,
    pol: *const RuntimePolicy,
    tools_rt: *core.tools.builtin.Runtime,
    in: *std.Io.Reader,
    out: *std.Io.Writer,
    session_dir_path: ?[]const u8,
    no_session: bool,
    sys_prompt: ?[]const u8,
    audit_hooks: AuditHooks,
    activity_sink: ?*activity.ActivitySink,
    is_oauth: bool,
) !void {
    const home = run_cmd.home;
    var ctl_audit = RuntimeCtlAudit{ .hooks = audit_hooks };
    var model: []const u8 = resolveDefault(run_cmd.cfg.model);
    var model_owned: ?[]u8 = null;
    defer if (model_owned) |m| alloc.free(m);
    var provider_label: []const u8 = resolveDefaultProvider(run_cmd.cfg.provider);
    var provider_owned: ?[]u8 = null;
    defer if (provider_owned) |p| alloc.free(p);

    var sink_impl = JsonSink{
        .alloc = alloc,
        .out = out,
    };

    const popts = run_cmd.thinking.toProviderOpts();
    var cmd_cache = core.loop.CmdCache.init(alloc);
    defer cmd_cache.deinit();
    const approval_bind = try loadApprovalBindAlloc(alloc, defaultIo(), home);
    defer approval_bind.deinit(alloc);
    const approval_loc = try getApprovalLocAlloc(alloc, defaultIo());
    defer freeApprovalLoc(alloc, approval_loc);
    const tctx = TurnCtx{
        .alloc = alloc,
        .provider = provider,
        .store = store,
        .pol = pol,
        .tools_rt = tools_rt,
        .mode = &sink_impl.mode_sink,
        .max_turns = run_cmd.max_turns,
        .cmd_cache = &cmd_cache,
        .approval_bind = approval_bind,
        .approval_loc = approval_loc,
        .activity_sink = activity_sink,
        .skip_prompt_guard = is_oauth,
    };
    var bg_mgr = try bg.Manager.initWithOpts(alloc, .{
        .home = home,
        .tmp_dir = run_cmd.tmp_dir,
        .pz_state_dir = run_cmd.state_dir,
        .xdg_state_home = run_cmd.xdg_state_home,
        .audit_emitter = audit_hooks.audit_emitter,
        .now_ms = audit_hooks.now_ms,
    });
    defer bg_mgr.deinit();

    while (try readLineAlloc(alloc, in, 128 * 1024)) |raw_line| {
        defer alloc.free(raw_line);

        const bg_done = try bg_mgr.drainDone(alloc);
        defer bg.deinitViews(alloc, bg_done);
        for (bg_done) |job| {
            try writeJsonLine(alloc, out, .{
                .type = "rpc_bg_done",
                .bg_id = job.id,
                .state = bg.stateName(job.state),
                .code = job.code,
                .log = job.log_path,
                .cmdline = job.cmd,
            });
        }

        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        const parsed = std.json.parseFromSlice(RpcReq, alloc, line, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch {
            try writeJsonLine(alloc, out, .{
                .type = "rpc_error",
                .msg = "invalid JSON request payload",
            });
            continue;
        };
        defer parsed.deinit();
        const req = parsed.value;
        const raw_cmd = req.cmd orelse req.type orelse "";
        if (raw_cmd.len == 0) {
            try writeJsonLine(alloc, out, .{
                .type = "rpc_error",
                .id = req.id,
                .msg = "missing command field (cmd or type)",
            });
            continue;
        }
        const cmd = normalizeRpcCmd(raw_cmd);

        const RpcCmd = enum { prompt, model, provider, tools, bg, login, logout, upgrade, new, @"resume", session, tree, fork, compact, help, commands, quit, exit };
        const rpc_map = std.StaticStringMap(RpcCmd).initComptime(.{
            .{ "prompt", .prompt },
            .{ "model", .model },
            .{ "provider", .provider },
            .{ "tools", .tools },
            .{ "bg", .bg },
            .{ "login", .login },
            .{ "logout", .logout },
            .{ "upgrade", .upgrade },
            .{ "new", .new },
            .{ "resume", .@"resume" },
            .{ "session", .session },
            .{ "tree", .tree },
            .{ "fork", .fork },
            .{ "compact", .compact },
            .{ "help", .help },
            .{ "commands", .commands },
            .{ "quit", .quit },
            .{ "exit", .exit },
        });

        const resolved = rpc_map.get(cmd) orelse {
            try writeJsonLine(alloc, out, .{
                .type = "rpc_error",
                .id = req.id,
                .cmd = raw_cmd,
                .msg = "unknown command; run rpc help or rpc commands",
            });
            continue;
        };

        if (!pol.allowsCmd(cmd)) {
            try writeJsonLine(alloc, out, .{
                .type = "rpc_error",
                .id = req.id,
                .cmd = raw_cmd,
                .msg = policy_denied_msg,
            });
            continue;
        }

        switch (resolved) {
            .prompt => {
                const prompt = req.text orelse req.arg orelse "";
                if (prompt.len == 0) {
                    try writeJsonLine(alloc, out, .{
                        .type = "rpc_error",
                        .id = req.id,
                        .cmd = raw_cmd,
                        .msg = "missing prompt text",
                    });
                    continue;
                }
                try tctx.run(.{
                    .sid = sid.*,
                    .prompt = prompt,
                    .model = model,
                    .provider_label = provider_label,
                    .provider_opts = popts,
                    .system_prompt = sys_prompt,
                });
                try writeJsonLine(alloc, out, .{
                    .type = "rpc_ack",
                    .id = req.id,
                    .cmd = raw_cmd,
                });
            },
            .model => {
                const next = req.model_id orelse req.model orelse req.arg orelse "";
                const argv = if (next.len > 0) core.audit.Str{ .text = next, .vis = .@"pub" } else null;
                const has_alias_provider = isSetModelAlias(raw_cmd) and req.provider != null and req.provider.?.len > 0;
                if (has_alias_provider) {
                    const start_attrs = [_]core.audit.Attribute{
                        .{
                            .key = "provider",
                            .vis = .@"pub",
                            .val = .{ .str = req.provider.? },
                        },
                    };
                    try runtimeCtlAudit(&ctl_audit, alloc, "model", .cfg, runtimeCfgResName(), argv, .start, null, &start_attrs);
                } else {
                    try runtimeCtlAudit(&ctl_audit, alloc, "model", .cfg, runtimeCfgResName(), argv, .start, null, &.{});
                }
                if (next.len == 0) {
                    try runtimeCtlAudit(
                        &ctl_audit,
                        alloc,
                        "model",
                        .cfg,
                        runtimeCfgResName(),
                        null,
                        .fail,
                        .{ .text = "missing model value", .vis = .mask },
                        &.{},
                    );
                    try writeJsonLine(alloc, out, .{
                        .type = "rpc_error",
                        .id = req.id,
                        .cmd = raw_cmd,
                        .msg = "missing model value",
                    });
                    continue;
                }
                if (has_alias_provider) {
                    try replaceOwnedText(alloc, &provider_label, &provider_owned, req.provider.?);
                }
                try replaceOwnedText(alloc, &model, &model_owned, next);
                const done_attrs = [_]core.audit.Attribute{
                    .{
                        .key = "provider",
                        .vis = .@"pub",
                        .val = .{ .str = provider_label },
                    },
                };
                try runtimeCtlAudit(&ctl_audit, alloc, "model", .cfg, runtimeCfgResName(), argv, .ok, null, &done_attrs);
                try writeJsonLine(alloc, out, .{
                    .type = "rpc_ack",
                    .id = req.id,
                    .cmd = raw_cmd,
                    .model = model,
                    .provider = provider_label,
                });
            },
            .provider => {
                const next = req.provider orelse req.arg orelse "";
                const argv = if (next.len > 0) core.audit.Str{ .text = next, .vis = .@"pub" } else null;
                try runtimeCtlAudit(&ctl_audit, alloc, "provider", .cfg, runtimeCfgResName(), argv, .start, null, &.{});
                if (next.len == 0) {
                    try runtimeCtlAudit(
                        &ctl_audit,
                        alloc,
                        "provider",
                        .cfg,
                        runtimeCfgResName(),
                        null,
                        .fail,
                        .{ .text = "missing provider value", .vis = .mask },
                        &.{},
                    );
                    try writeJsonLine(alloc, out, .{
                        .type = "rpc_error",
                        .id = req.id,
                        .cmd = raw_cmd,
                        .msg = "missing provider value",
                    });
                    continue;
                }
                try replaceOwnedText(alloc, &provider_label, &provider_owned, next);
                try runtimeCtlAudit(&ctl_audit, alloc, "provider", .cfg, runtimeCfgResName(), argv, .ok, null, &.{});
                try writeJsonLine(alloc, out, .{
                    .type = "rpc_ack",
                    .id = req.id,
                    .cmd = raw_cmd,
                    .provider = provider_label,
                });
            },
            .tools => {
                const raw = req.tools orelse req.arg orelse "";
                if (raw.len != 0) {
                    const argv: core.audit.Str = .{ .text = raw, .vis = .@"pub" };
                    try runtimeCtlAudit(&ctl_audit, alloc, "tools", .cfg, runtimeCfgResName(), argv, .start, null, &.{});
                    const mask = parseCmdToolMask(raw) catch {
                        try runtimeCtlAudit(
                            &ctl_audit,
                            alloc,
                            "tools",
                            .cfg,
                            runtimeCfgResName(),
                            argv,
                            .fail,
                            .{ .text = "invalid tools value", .vis = .mask },
                            &.{},
                        );
                        try writeJsonLine(alloc, out, .{
                            .type = "rpc_error",
                            .id = req.id,
                            .cmd = raw_cmd,
                            .msg = "invalid tools value",
                        });
                        continue;
                    };
                    tools_rt.tool_mask = mask;
                }
                const tool_csv = try toolMaskCsvAlloc(alloc, tools_rt.tool_mask);
                defer alloc.free(tool_csv);
                if (raw.len != 0) {
                    const argv: core.audit.Str = .{ .text = raw, .vis = .@"pub" };
                    const attrs = [_]core.audit.Attribute{
                        .{
                            .key = "tools",
                            .vis = .@"pub",
                            .val = .{ .str = tool_csv },
                        },
                    };
                    try runtimeCtlAudit(&ctl_audit, alloc, "tools", .cfg, runtimeCfgResName(), argv, .ok, null, &attrs);
                }
                try writeJsonLine(alloc, out, .{
                    .type = "rpc_ack",
                    .id = req.id,
                    .cmd = raw_cmd,
                    .tools = tool_csv,
                });
            },
            .bg => {
                const bg_arg = req.arg orelse req.text orelse "list";
                const msg = try runBgCommand(alloc, &bg_mgr, bg_arg);
                defer alloc.free(msg);
                try writeJsonLine(alloc, out, .{
                    .type = "rpc_bg",
                    .id = req.id,
                    .cmd = raw_cmd,
                    .msg = msg,
                });
            },
            .login => {
                const msg = runRpcLogin(alloc, req, audit_hooks.auth()) catch |err| {
                    const err_msg = try report.rpc(alloc, "login", err);
                    defer alloc.free(err_msg);
                    try writeJsonLine(alloc, out, .{
                        .type = "rpc_error",
                        .id = req.id,
                        .cmd = raw_cmd,
                        .msg = err_msg,
                    });
                    continue;
                };
                defer alloc.free(msg);
                try writeJsonLine(alloc, out, .{
                    .type = "rpc_auth",
                    .id = req.id,
                    .cmd = raw_cmd,
                    .msg = msg,
                });
            },
            .logout => {
                const msg = runRpcLogout(alloc, req, provider_label, audit_hooks.auth(), home) catch |err| {
                    const err_msg = try report.rpc(alloc, "logout", err);
                    defer alloc.free(err_msg);
                    try writeJsonLine(alloc, out, .{
                        .type = "rpc_error",
                        .id = req.id,
                        .cmd = raw_cmd,
                        .msg = err_msg,
                    });
                    continue;
                };
                defer alloc.free(msg);
                try writeJsonLine(alloc, out, .{
                    .type = "rpc_auth",
                    .id = req.id,
                    .cmd = raw_cmd,
                    .msg = msg,
                });
            },
            .upgrade => {
                try runtimeCtlAudit(&ctl_audit, alloc, "upgrade", .cmd, runtimeUpgradeResName(), null, .start, null, &.{});
                const outcome = audit_hooks.run_upgrade(alloc, updateAuditHooks(audit_hooks, run_cmd.io, home)) catch |err| {
                    try runtimeCtlAudit(
                        &ctl_audit,
                        alloc,
                        "upgrade",
                        .cmd,
                        runtimeUpgradeResName(),
                        null,
                        .fail,
                        .{ .text = @errorName(err), .vis = .mask },
                        &.{},
                    );
                    const err_msg = try report.rpc(alloc, "upgrade", err);
                    defer alloc.free(err_msg);
                    try writeJsonLine(alloc, out, .{
                        .type = "rpc_error",
                        .id = req.id,
                        .cmd = raw_cmd,
                        .msg = err_msg,
                    });
                    continue;
                };
                defer outcome.deinit(alloc);
                if (outcome.ok) {
                    try runtimeCtlAudit(&ctl_audit, alloc, "upgrade", .cmd, runtimeUpgradeResName(), null, .ok, null, &.{});
                    try writeJsonLine(alloc, out, .{
                        .type = "rpc_upgrade",
                        .id = req.id,
                        .cmd = raw_cmd,
                        .msg = outcome.msg,
                    });
                } else {
                    try runtimeCtlAudit(
                        &ctl_audit,
                        alloc,
                        "upgrade",
                        .cmd,
                        runtimeUpgradeResName(),
                        null,
                        .fail,
                        .{ .text = outcome.msg, .vis = .mask },
                        &.{},
                    );
                    try writeJsonLine(alloc, out, .{
                        .type = "rpc_error",
                        .id = req.id,
                        .cmd = raw_cmd,
                        .msg = outcome.msg,
                    });
                }
            },
            .new => {
                try runtimeCtlAudit(&ctl_audit, alloc, "new", .sess, runtimeSessResName(), null, .start, null, &.{});
                const next_sid = try newSid(alloc);
                alloc.free(sid.*);
                sid.* = next_sid;
                try runtimeCtlAudit(&ctl_audit, alloc, "new", .sess, runtimeSessResName(), null, .ok, null, &.{});
                try writeJsonLine(alloc, out, .{
                    .type = "rpc_ack",
                    .id = req.id,
                    .cmd = raw_cmd,
                    .sid = sid.*,
                });
            },
            .@"resume" => {
                const token = req.session_path orelse req.session orelse req.sid orelse req.arg;
                if (token) |raw| {
                    const argv: core.audit.Str = .{ .text = raw, .vis = .mask };
                    try runtimeCtlAudit(&ctl_audit, alloc, "resume", .sess, runtimeSessResName(), argv, .start, null, &.{});
                }
                applyResumeSid(alloc, sid, session_dir_path, no_session, token) catch |err| {
                    try runtimeCtlAudit(
                        &ctl_audit,
                        alloc,
                        "resume",
                        .sess,
                        runtimeSessResName(),
                        if (token) |raw| .{ .text = raw, .vis = .mask } else null,
                        .fail,
                        .{ .text = @errorName(err), .vis = .mask },
                        &.{},
                    );
                    const err_msg = try report.rpc(alloc, "resume session", err);
                    defer alloc.free(err_msg);
                    try writeJsonLine(alloc, out, .{
                        .type = "rpc_error",
                        .id = req.id,
                        .cmd = raw_cmd,
                        .msg = err_msg,
                    });
                    continue;
                };
                try runtimeCtlAudit(
                    &ctl_audit,
                    alloc,
                    "resume",
                    .sess,
                    runtimeSessResName(),
                    if (token) |raw| .{ .text = raw, .vis = .mask } else null,
                    .ok,
                    null,
                    &.{},
                );
                try writeJsonLine(alloc, out, .{
                    .type = "rpc_ack",
                    .id = req.id,
                    .cmd = raw_cmd,
                    .sid = sid.*,
                });
            },
            .session => {
                const tool_csv = try toolMaskCsvAlloc(alloc, tools_rt.tool_mask);
                defer alloc.free(tool_csv);
                const stats = try sessionStats(alloc, session_dir_path, sid.*, no_session);
                defer if (stats.path_owned) |path| alloc.free(path);
                try writeJsonLine(alloc, out, .{
                    .type = "rpc_session",
                    .id = req.id,
                    .sid = sid.*,
                    .model = model,
                    .provider = provider_label,
                    .tools = tool_csv,
                    .session_dir = session_dir_path orelse "",
                    .session_file = stats.path,
                    .session_bytes = stats.bytes,
                    .session_lines = stats.lines,
                    .no_session = no_session,
                });
            },
            .tree => {
                const session_dir = requireSessionDir(session_dir_path, no_session) catch {
                    const err_msg = try report.rpc(alloc, "list sessions", error.SessionDisabled);
                    defer alloc.free(err_msg);
                    try writeJsonLine(alloc, out, .{
                        .type = "rpc_error",
                        .id = req.id,
                        .cmd = raw_cmd,
                        .msg = err_msg,
                    });
                    continue;
                };
                const tree = try listSessionsAlloc(alloc, session_dir);
                defer alloc.free(tree);
                try writeJsonLine(alloc, out, .{
                    .type = "rpc_tree",
                    .id = req.id,
                    .sessions = tree,
                });
            },
            .fork => {
                const fork_arg = req.sid orelse req.arg;
                if (fork_arg) |raw| {
                    const argv: core.audit.Str = .{ .text = raw, .vis = .mask };
                    try runtimeCtlAudit(&ctl_audit, alloc, "fork", .sess, runtimeSessResName(), argv, .start, null, &.{});
                }
                applyForkSid(alloc, sid, session_dir_path, no_session, req.sid orelse req.arg) catch |err| {
                    try runtimeCtlAudit(
                        &ctl_audit,
                        alloc,
                        "fork",
                        .sess,
                        runtimeSessResName(),
                        if (fork_arg) |raw| .{ .text = raw, .vis = .mask } else null,
                        .fail,
                        .{ .text = @errorName(err), .vis = .mask },
                        &.{},
                    );
                    const err_msg = try report.rpc(alloc, "fork session", err);
                    defer alloc.free(err_msg);
                    try writeJsonLine(alloc, out, .{
                        .type = "rpc_error",
                        .id = req.id,
                        .cmd = raw_cmd,
                        .msg = err_msg,
                    });
                    continue;
                };
                try runtimeCtlAudit(
                    &ctl_audit,
                    alloc,
                    "fork",
                    .sess,
                    runtimeSessResName(),
                    if (fork_arg) |raw| .{ .text = raw, .vis = .mask } else null,
                    .ok,
                    null,
                    &.{},
                );
                try writeJsonLine(alloc, out, .{
                    .type = "rpc_ack",
                    .id = req.id,
                    .cmd = raw_cmd,
                    .sid = sid.*,
                });
            },
            .compact => {
                try runtimeCtlAudit(&ctl_audit, alloc, "compact", .sess, runtimeSessResName(), null, .start, null, &.{});
                const session_dir = requireSessionDir(session_dir_path, no_session) catch {
                    try runtimeCtlAudit(
                        &ctl_audit,
                        alloc,
                        "compact",
                        .sess,
                        runtimeSessResName(),
                        null,
                        .fail,
                        .{ .text = @errorName(error.SessionDisabled), .vis = .mask },
                        &.{},
                    );
                    const err_msg = try report.rpc(alloc, "compact session", error.SessionDisabled);
                    defer alloc.free(err_msg);
                    try writeJsonLine(alloc, out, .{
                        .type = "rpc_error",
                        .id = req.id,
                        .cmd = raw_cmd,
                        .msg = err_msg,
                    });
                    continue;
                };
                const dir = try openDirPath(session_dir, .{});
                defer dir.close(defaultIo());
                const ck = core.session.compactSession(alloc, dir, sid.*, audit_hooks.now_ms()) catch |err| {
                    try runtimeCtlAudit(
                        &ctl_audit,
                        alloc,
                        "compact",
                        .sess,
                        runtimeSessResName(),
                        null,
                        .fail,
                        .{ .text = @errorName(err), .vis = .mask },
                        &.{},
                    );
                    const err_msg = try report.rpc(alloc, "compact session", err);
                    defer alloc.free(err_msg);
                    try writeJsonLine(alloc, out, .{
                        .type = "rpc_error",
                        .id = req.id,
                        .cmd = raw_cmd,
                        .msg = err_msg,
                    });
                    continue;
                };
                const attrs = [_]core.audit.Attribute{
                    .{
                        .key = "in_lines",
                        .vis = .@"pub",
                        .val = .{ .uint = @intCast(ck.in_lines) },
                    },
                    .{
                        .key = "out_lines",
                        .vis = .@"pub",
                        .val = .{ .uint = @intCast(ck.out_lines) },
                    },
                };
                try runtimeCtlAudit(&ctl_audit, alloc, "compact", .sess, runtimeSessResName(), null, .ok, null, &attrs);
                try writeJsonLine(alloc, out, .{
                    .type = "rpc_compact",
                    .id = req.id,
                    .sid = sid.*,
                    .in_lines = ck.in_lines,
                    .out_lines = ck.out_lines,
                    .in_bytes = ck.in_bytes,
                    .out_bytes = ck.out_bytes,
                });
            },
            .help => {
                try writeJsonLine(alloc, out, .{
                    .type = "rpc_help",
                    .id = req.id,
                    .commands = "prompt,model,provider,tools,bg,login,logout,upgrade,new,resume,session,tree,fork,compact,quit",
                });
            },
            .commands => {
                const commands = [_][]const u8{
                    "prompt", "model", "provider", "tools", "bg", "login", "logout", "upgrade", "new", "resume", "session", "tree", "fork", "compact", "help", "quit",
                };
                try writeJsonLine(alloc, out, .{
                    .type = "rpc_commands",
                    .id = req.id,
                    .commands = commands[0..],
                });
            },
            .quit, .exit => {
                try writeJsonLine(alloc, out, .{
                    .type = "rpc_ack",
                    .id = req.id,
                    .cmd = raw_cmd,
                });
                return;
            },
        }
    }
}

const AuthReq = struct {
    prov: core.providers.auth.Provider,
    prov_name: []const u8,
    key: []const u8,
};

/// Stores the PKCE verifier from a pending OAuth flow so that manual
/// completion via `/login <provider> <callback-url>` can supply it
/// independently of the CSRF state parameter.
var pending_oauth_verifier: ?struct {
    prov: core.providers.auth.Provider,
    verifier: []u8,
    alloc: std.mem.Allocator,

    fn deinit(self: *@This()) void {
        self.alloc.free(self.verifier);
        self.* = undefined;
    }
} = null;

fn storePendingVerifier(alloc: std.mem.Allocator, prov: core.providers.auth.Provider, verifier: []const u8) void {
    clearPendingVerifier();
    pending_oauth_verifier = .{
        .prov = prov,
        .verifier = alloc.dupe(u8, verifier) catch return,
        .alloc = alloc,
    };
}

fn clearPendingVerifier() void {
    if (pending_oauth_verifier) |*v| v.deinit();
    pending_oauth_verifier = null;
}

fn takePendingVerifier(prov: core.providers.auth.Provider) ?[]const u8 {
    const pv = pending_oauth_verifier orelse return null;
    if (pv.prov != prov) return null;
    return pv.verifier;
}

fn parseAuthReq(arg: []const u8, provider_hint: ?[]const u8) !AuthReq {
    const trimmed = std.mem.trim(u8, arg, " \t");
    if (provider_hint) |name| {
        const prov_name = std.mem.trim(u8, name, " \t");
        if (prov_name.len == 0) return error.InvalidArgs;
        return .{
            .prov = parseAuthProvider(prov_name) orelse return error.UnknownProvider,
            .prov_name = prov_name,
            .key = trimmed,
        };
    }

    if (trimmed.len == 0) return error.InvalidArgs;
    const sp = std.mem.indexOfAny(u8, trimmed, " \t");
    const prov_name = if (sp) |i| trimmed[0..i] else trimmed;
    return .{
        .prov = parseAuthProvider(prov_name) orelse return error.UnknownProvider,
        .prov_name = prov_name,
        .key = if (sp) |i| std.mem.trim(u8, trimmed[i + 1 ..], " \t") else "",
    };
}

fn runLoginFlow(
    alloc: std.mem.Allocator,
    out: *std.Io.Writer,
    req: AuthReq,
    hooks: core.providers.auth.Hooks,
) !void {
    _ = alloc;
    _ = req;
    _ = hooks;
    try out.writeAll(direct_provider_login_disabled_msg);
}

fn runOAuthCallbackLogin(
    alloc: std.mem.Allocator,
    out: *std.Io.Writer,
    prov: core.providers.auth.Provider,
    oauth_name: []const u8,
    listener: *core.providers.oauth_callback.Listener,
    flow: *const core.providers.auth.OAuthStart,
    hooks: core.providers.auth.Hooks,
) !void {
    if (core.providers.auth.openBrowser(alloc, flow.url)) {
        try writeTextLine(alloc, out, "opened browser for {s} oauth\n", .{oauth_name});
    } else |_| {
        try out.writeAll("could not open browser automatically\n");
        try writeTextLine(alloc, out, "auth url: {s}\n", .{flow.url});
    }
    try out.writeAll("waiting for oauth callback...\n");

    var callback = listener.waitForCodeState(alloc, 5 * 60 * 1000) catch |err| {
        if (err != error.OAuthCallbackTimeout) return err;
        storePendingVerifier(alloc, prov, flow.verifier);
        try writeTextLine(alloc, out, "auth url: {s}\n", .{flow.url});
        try out.writeAll("if your browser showed localhost callback URL, run:\n");
        try writeTextLine(alloc, out, "  /login {s} <callback-url>\n", .{oauth_name});
        return err;
    };
    defer callback.deinit(alloc);

    try core.providers.auth.completeOAuthFromLocalCallbackWithHooks(
        alloc,
        prov,
        callback,
        listener.redirect_uri,
        flow.state,
        flow.verifier,
        hooks,
    );
    clearPendingVerifier();
    try writeTextLine(alloc, out, "{s} oauth login complete\n", .{oauth_name});
}

fn runRpcLogin(alloc: std.mem.Allocator, req: RpcReq, hooks: core.providers.auth.Hooks) ![]u8 {
    const auth_req = try parseAuthReq(req.arg orelse req.text orelse "", req.provider);
    _ = auth_req;
    _ = hooks;
    return alloc.dupe(u8, direct_provider_login_disabled_msg);
}

fn runRpcLogout(
    alloc: std.mem.Allocator,
    req: RpcReq,
    active_name: []const u8,
    hooks: core.providers.auth.Hooks,
    home: ?[]const u8,
) ![]u8 {
    const provider_name = if (req.provider) |name|
        std.mem.trim(u8, name, " \t")
    else
        std.mem.trim(u8, req.arg orelse req.text orelse "", " \t");

    if (provider_name.len != 0) {
        const prov = parseAuthProvider(provider_name) orelse return error.UnknownProvider;
        try core.providers.auth.logoutWithHooks(alloc, prov, hooks);
        return std.fmt.allocPrint(alloc, "logged out of {s}\n", .{core.providers.auth.providerName(prov)});
    }

    const logged_in = core.providers.auth.listLoggedIn(alloc, home) catch try alloc.alloc(core.providers.auth.Provider, 0);
    defer alloc.free(logged_in);
    if (logged_in.len == 0) return alloc.dupe(u8, "no providers logged in\n");
    const prov = chooseLogoutProvider(active_name, logged_in) orelse return error.InvalidArgs;
    try core.providers.auth.logoutWithHooks(alloc, prov, hooks);
    return std.fmt.allocPrint(alloc, "logged out of {s}\n", .{core.providers.auth.providerName(prov)});
}

const CmdRes = enum {
    unhandled,
    handled,
    compacted,
    resumed,
    quit,
    clear,
    copy,
    cost,
    reload,
    select_model,
    select_session,
    select_settings,
    select_fork,
    select_login,
    select_logout,
};

const SlashSkill = enum {
    missing,
    blocked,
    allowed,
};

fn classifySlashSkill(skills: []const core_skill.SkillInfo, name: []const u8) SlashSkill {
    const info = core_skill.findByDirName(skills, name) orelse return .missing;
    if (!info.meta.user_invocable) return .blocked;
    if (info.meta.disable_model_invocation) return .blocked;
    return .allowed;
}

fn loadSlashSkill(alloc: std.mem.Allocator, name: []const u8, home: ?[]const u8) !SlashSkill {
    const skills = try core_skill.discoverAndRead(alloc, home);
    defer core_skill.freeSkills(alloc, skills);
    return classifySlashSkill(skills, name);
}

fn handleSlashCommand(
    alloc: std.mem.Allocator,
    line: []const u8,
    sid: *([]u8),
    model: *([]const u8),
    model_owned: *?[]u8,
    provider: *([]const u8),
    provider_owned: *?[]u8,
    pol: *const RuntimePolicy,
    tools_rt: *core.tools.builtin.Runtime,
    bg_mgr: *bg.Manager,
    session_dir_path: ?[]const u8,
    no_session: bool,
    _: ?[]const u8, // sys_prompt (unused after settings became interactive)
    out: *std.Io.Writer,
    audit_hooks: AuditHooks,
    ctl_audit: *RuntimeCtlAudit,
    home: ?[]const u8,
) !CmdRes {
    if (line.len == 0 or line[0] != '/') return .unhandled;

    const body = std.mem.trim(u8, line[1..], " \t");
    if (body.len == 0) return .handled;

    const sp = std.mem.indexOfAny(u8, body, " \t");
    const cmd = if (sp) |i| body[0..i] else body;
    const arg = if (sp) |i| std.mem.trim(u8, body[i + 1 ..], " \t") else "";

    const Cmd = enum { help, quit, exit, session, model, provider, tools, bg, upgrade, new, @"resume", tree, fork, compact, @"export", settings, hotkeys, login, logout, clear, cost, copy, name, reload, share, changelog };
    const cmd_map = std.StaticStringMap(Cmd).initComptime(.{
        .{ "help", .help },
        .{ "quit", .quit },
        .{ "exit", .exit },
        .{ "session", .session },
        .{ "model", .model },
        .{ "provider", .provider },
        .{ "tools", .tools },
        .{ "bg", .bg },
        .{ "upgrade", .upgrade },
        .{ "new", .new },
        .{ "resume", .@"resume" },
        .{ "tree", .tree },
        .{ "fork", .fork },
        .{ "compact", .compact },
        .{ "export", .@"export" },
        .{ "settings", .settings },
        .{ "hotkeys", .hotkeys },
        .{ "login", .login },
        .{ "logout", .logout },
        .{ "clear", .clear },
        .{ "cost", .cost },
        .{ "copy", .copy },
        .{ "name", .name },
        .{ "reload", .reload },
        .{ "share", .share },
        .{ "changelog", .changelog },
    });

    const resolved = cmd_map.get(cmd) orelse {
        switch (try loadSlashSkill(alloc, cmd, home)) {
            .allowed => {
                if (pol.allowsCmd(cmd)) return .unhandled;
                try writeTextLine(alloc, out, "blocked by policy: /{s}\n", .{cmd});
            },
            .blocked => try writeTextLine(alloc, out, "skill blocked: /{s}\n", .{cmd}),
            .missing => try writeTextLine(alloc, out, "unknown command: /{s}\n", .{cmd}),
        }
        return .handled;
    };

    if (!pol.allowsCmd(cmd)) {
        try writeTextLine(alloc, out, "blocked by policy: /{s}\n", .{cmd});
        return .handled;
    }

    switch (resolved) {
        .help => {
            try out.writeAll(
                \\Commands:
                \\  /help              Show this help
                \\  /session           Session info
                \\  /settings          Current settings
                \\  /model [id]        Set/select model
                \\  /provider <id>     Set/show provider
                \\  /tools [list|all]  Set/show tools
                \\  /bg <subcommand>   Background jobs
                \\  /upgrade           Self-update to latest release
                \\  /clear             Clear transcript
                \\  /copy              Copy last response
                \\  /export [path]     Export to markdown
                \\  /share             Share as gist
                \\  /name <name>       Name session
                \\  /new               New session
                \\  /resume [id]       Resume session
                \\  /tree              List sessions
                \\  /fork [id]         Fork session
                \\  /compact           Compact session
                \\  /reload            Reload context files
                \\  /login             Show provider-command policy guidance
                \\  /logout            Logout
                \\  /changelog         What's new
                \\  /hotkeys           Keyboard shortcuts
                \\  /quit              Exit
                \\
            );
        },
        .quit, .exit => return .quit,
        .session => {
            const stats = try sessionStats(alloc, session_dir_path, sid.*, no_session);
            defer if (stats.path_owned) |path| alloc.free(path);
            const total = stats.user_msgs + stats.asst_msgs + stats.tool_calls + stats.tool_results;
            const info = try std.fmt.allocPrint(
                alloc,
                "Session Info\n\nFile: {s}\nID:   {s}\n\nMessages\n" ++
                    "  User:         {d}\n  Assistant:    {d}\n  Tool Calls:   {d}\n" ++
                    "  Tool Results: {d}\n  Total:        {d}\n",
                .{ stats.path, sid.*, stats.user_msgs, stats.asst_msgs, stats.tool_calls, stats.tool_results, total },
            );
            defer alloc.free(info);
            try out.writeAll(info);
        },
        .model => {
            if (arg.len == 0) return .select_model;
            const argv: core.audit.Str = .{ .text = arg, .vis = .@"pub" };
            try runtimeCtlAudit(ctl_audit, alloc, "model", .cfg, runtimeCfgResName(), argv, .start, null, &.{});
            try replaceOwnedText(alloc, model, model_owned, arg);
            const attrs = [_]core.audit.Attribute{
                .{
                    .key = "provider",
                    .vis = .@"pub",
                    .val = .{ .str = provider.* },
                },
            };
            try runtimeCtlAudit(ctl_audit, alloc, "model", .cfg, runtimeCfgResName(), argv, .ok, null, &attrs);
            try writeTextLine(alloc, out, "model set to {s}\n", .{model.*});
        },
        .provider => {
            if (arg.len == 0) {
                try writeTextLine(alloc, out, "provider {s}\n", .{provider.*});
                return .handled;
            }
            const argv: core.audit.Str = .{ .text = arg, .vis = .@"pub" };
            try runtimeCtlAudit(ctl_audit, alloc, "provider", .cfg, runtimeCfgResName(), argv, .start, null, &.{});
            try replaceOwnedText(alloc, provider, provider_owned, arg);
            try runtimeCtlAudit(ctl_audit, alloc, "provider", .cfg, runtimeCfgResName(), argv, .ok, null, &.{});
            try writeTextLine(alloc, out, "provider set to {s}\n", .{provider.*});
        },
        .tools => {
            if (arg.len != 0) {
                const argv: core.audit.Str = .{ .text = arg, .vis = .@"pub" };
                try runtimeCtlAudit(ctl_audit, alloc, "tools", .cfg, runtimeCfgResName(), argv, .start, null, &.{});
                const mask = parseCmdToolMask(arg) catch {
                    try runtimeCtlAudit(
                        ctl_audit,
                        alloc,
                        "tools",
                        .cfg,
                        runtimeCfgResName(),
                        argv,
                        .fail,
                        .{ .text = "invalid tools value", .vis = .mask },
                        &.{},
                    );
                    try out.writeAll("error: invalid tools value; use all, none, or comma list of read,write,bash,edit,grep,find,ls,ask,skill\n");
                    return .handled;
                };
                tools_rt.tool_mask = mask;
                const tool_csv = try toolMaskCsvAlloc(alloc, tools_rt.tool_mask);
                defer alloc.free(tool_csv);
                const attrs = [_]core.audit.Attribute{
                    .{
                        .key = "tools",
                        .vis = .@"pub",
                        .val = .{ .str = tool_csv },
                    },
                };
                try runtimeCtlAudit(ctl_audit, alloc, "tools", .cfg, runtimeCfgResName(), argv, .ok, null, &attrs);
                try writeTextLine(alloc, out, "tools set to {s}\n", .{tool_csv});
                return .handled;
            }
            const tool_csv = try toolMaskCsvAlloc(alloc, tools_rt.tool_mask);
            defer alloc.free(tool_csv);
            try writeTextLine(alloc, out, "tools {s}\n", .{tool_csv});
        },
        .bg => {
            if (arg.len == 0) {
                const usage =
                    \\usage:
                    \\  /bg run <cmd>
                    \\  /bg list
                    \\  /bg show <id>
                    \\  /bg stop <id>
                    \\
                ;
                try out.writeAll(usage);
                return .handled;
            }
            const bg_out = try runBgCommand(alloc, bg_mgr, arg);
            defer alloc.free(bg_out);
            try out.writeAll(bg_out);
        },
        .upgrade => {
            try runtimeCtlAudit(ctl_audit, alloc, "upgrade", .cmd, runtimeUpgradeResName(), null, .start, null, &.{});
            const outcome = audit_hooks.run_upgrade(alloc, updateAuditHooks(audit_hooks, audit_hooks.io, home)) catch |err| {
                try runtimeCtlAudit(
                    ctl_audit,
                    alloc,
                    "upgrade",
                    .cmd,
                    runtimeUpgradeResName(),
                    null,
                    .fail,
                    .{ .text = @errorName(err), .vis = .mask },
                    &.{},
                );
                return err;
            };
            defer outcome.deinit(alloc);
            if (outcome.ok) {
                try runtimeCtlAudit(ctl_audit, alloc, "upgrade", .cmd, runtimeUpgradeResName(), null, .ok, null, &.{});
            } else {
                try runtimeCtlAudit(
                    ctl_audit,
                    alloc,
                    "upgrade",
                    .cmd,
                    runtimeUpgradeResName(),
                    null,
                    .fail,
                    .{ .text = outcome.msg, .vis = .mask },
                    &.{},
                );
            }
            try out.writeAll(outcome.msg);
        },
        .new => {
            try runtimeCtlAudit(ctl_audit, alloc, "new", .sess, runtimeSessResName(), null, .start, null, &.{});
            const next_sid = try newSid(alloc);
            alloc.free(sid.*);
            sid.* = next_sid;
            try runtimeCtlAudit(ctl_audit, alloc, "new", .sess, runtimeSessResName(), null, .ok, null, &.{});
            try writeTextLine(alloc, out, "new session {s}\n", .{sid.*});
        },
        .@"resume" => {
            if (arg.len == 0) return .select_session;
            const argv: core.audit.Str = .{ .text = arg, .vis = .mask };
            try runtimeCtlAudit(ctl_audit, alloc, "resume", .sess, runtimeSessResName(), argv, .start, null, &.{});
            applyResumeSid(alloc, sid, session_dir_path, no_session, arg) catch |err| {
                try runtimeCtlAudit(
                    ctl_audit,
                    alloc,
                    "resume",
                    .sess,
                    runtimeSessResName(),
                    argv,
                    .fail,
                    .{ .text = @errorName(err), .vis = .mask },
                    &.{},
                );
                const em = try report.cli(alloc, "resume session", err);
                defer alloc.free(em);
                try out.writeAll(em);
                return .handled;
            };
            try runtimeCtlAudit(ctl_audit, alloc, "resume", .sess, runtimeSessResName(), argv, .ok, null, &.{});
            try writeTextLine(alloc, out, "resumed session {s}\n", .{sid.*});
            return .resumed;
        },
        .tree => {
            const session_dir = requireSessionDir(session_dir_path, no_session) catch {
                const em = try report.cli(alloc, "list sessions", error.SessionDisabled);
                defer alloc.free(em);
                try out.writeAll(em);
                return .handled;
            };
            const tree = try listSessionsAlloc(alloc, session_dir);
            defer alloc.free(tree);
            try out.writeAll(tree);
            if (tree.len == 0 or tree[tree.len - 1] != '\n') try out.writeAll("\n");
        },
        .fork => {
            if (arg.len == 0) return .select_fork;
            const argv: core.audit.Str = .{ .text = arg, .vis = .mask };
            try runtimeCtlAudit(ctl_audit, alloc, "fork", .sess, runtimeSessResName(), argv, .start, null, &.{});
            applyForkSid(alloc, sid, session_dir_path, no_session, arg) catch |err| {
                try runtimeCtlAudit(
                    ctl_audit,
                    alloc,
                    "fork",
                    .sess,
                    runtimeSessResName(),
                    argv,
                    .fail,
                    .{ .text = @errorName(err), .vis = .mask },
                    &.{},
                );
                const em = try report.cli(alloc, "fork session", err);
                defer alloc.free(em);
                try out.writeAll(em);
                return .handled;
            };
            try runtimeCtlAudit(ctl_audit, alloc, "fork", .sess, runtimeSessResName(), argv, .ok, null, &.{});
            try writeTextLine(alloc, out, "forked session {s}\n", .{sid.*});
        },
        .compact => {
            try runtimeCtlAudit(ctl_audit, alloc, "compact", .sess, runtimeSessResName(), null, .start, null, &.{});
            const session_dir = requireSessionDir(session_dir_path, no_session) catch {
                try runtimeCtlAudit(
                    ctl_audit,
                    alloc,
                    "compact",
                    .sess,
                    runtimeSessResName(),
                    null,
                    .fail,
                    .{ .text = @errorName(error.SessionDisabled), .vis = .mask },
                    &.{},
                );
                const em = try report.cli(alloc, "compact session", error.SessionDisabled);
                defer alloc.free(em);
                try out.writeAll(em);
                return .handled;
            };
            const dir = try openDirPath(session_dir, .{});
            defer dir.close(defaultIo());
            const ck = core.session.compactSession(alloc, dir, sid.*, audit_hooks.now_ms()) catch |err| {
                try runtimeCtlAudit(
                    ctl_audit,
                    alloc,
                    "compact",
                    .sess,
                    runtimeSessResName(),
                    null,
                    .fail,
                    .{ .text = @errorName(err), .vis = .mask },
                    &.{},
                );
                const em = try report.cli(alloc, "compact session", err);
                defer alloc.free(em);
                try out.writeAll(em);
                return .handled;
            };
            const attrs = [_]core.audit.Attribute{
                .{
                    .key = "in_lines",
                    .vis = .@"pub",
                    .val = .{ .uint = @intCast(ck.in_lines) },
                },
                .{
                    .key = "out_lines",
                    .vis = .@"pub",
                    .val = .{ .uint = @intCast(ck.out_lines) },
                },
            };
            try runtimeCtlAudit(ctl_audit, alloc, "compact", .sess, runtimeSessResName(), null, .ok, null, &attrs);
            try writeTextLine(alloc, out, "compacted in={d} out={d}\n", .{ ck.in_lines, ck.out_lines });
            return .compacted;
        },
        .@"export" => {
            const argv = if (arg.len > 0) core.audit.Str{ .text = arg, .vis = .mask } else null;
            try runtimeCtlAudit(ctl_audit, alloc, "export", .file, runtimeExportResName(), argv, .start, null, &.{});
            const session_dir = requireSessionDir(session_dir_path, no_session) catch {
                try runtimeCtlAudit(
                    ctl_audit,
                    alloc,
                    "export",
                    .file,
                    runtimeExportResName(),
                    argv,
                    .fail,
                    .{ .text = @errorName(error.SessionDisabled), .vis = .mask },
                    &.{},
                );
                const em = try report.cli(alloc, "export session", error.SessionDisabled);
                defer alloc.free(em);
                try out.writeAll(em);
                return .handled;
            };
            const dir = try openDirPath(session_dir, .{});
            defer dir.close(defaultIo());
            const out_path = if (arg.len > 0) arg else null;
            const path = core.session.@"export".toMarkdownAudited(alloc, dir, sid.*, out_path, exportAuditHooks(audit_hooks)) catch |err| {
                try runtimeCtlAudit(
                    ctl_audit,
                    alloc,
                    "export",
                    .file,
                    runtimeExportResName(),
                    argv,
                    .fail,
                    .{ .text = @errorName(err), .vis = .mask },
                    &.{},
                );
                const em = try report.cli(alloc, "export session", err);
                defer alloc.free(em);
                try out.writeAll(em);
                return .handled;
            };
            defer alloc.free(path);
            const attrs = [_]core.audit.Attribute{
                .{
                    .key = "path",
                    .vis = .mask,
                    .val = .{ .str = path },
                },
            };
            try runtimeCtlAudit(ctl_audit, alloc, "export", .file, runtimeExportResName(), argv, .ok, null, &attrs);
            try writeTextLine(alloc, out, "exported to {s}\n", .{path});
        },
        .settings => return .select_settings,
        .hotkeys => {
            try out.writeAll(
                \\Keyboard shortcuts:
                \\  Enter          Submit message (steer while running)
                \\  ESC            Clear input / Cancel
                \\  Ctrl+C         Clear input / Quit
                \\  Ctrl+D         Quit (when input empty)
                \\  Ctrl+Z         Undo
                \\  Ctrl+Shift+Z   Redo
                \\  Up/Down        Input history
                \\  Ctrl+A         Move to start
                \\  Ctrl+E         Move to end
                \\  Ctrl+J         Insert newline
                \\  Ctrl+K         Delete to end of line
                \\  Ctrl+U         Delete whole line
                \\  Ctrl+W         Delete word backward
                \\  Alt+D          Delete word forward
                \\  Ctrl+Y         Yank (paste from kill ring)
                \\  Alt+Y          Yank-pop (cycle kill ring)
                \\  Ctrl+]         Jump to character
                \\  Alt+B/Ctrl+←   Move word left
                \\  Alt+F/Ctrl+→   Move word right
                \\  Shift+Tab      Cycle thinking level
                \\  Ctrl+P         Cycle model
                \\  Shift+Ctrl+P   Reverse cycle model
                \\  Ctrl+L         Select model
                \\  Ctrl+O         Toggle tool output
                \\  Ctrl+T         Toggle thinking blocks
                \\  Ctrl+G         External editor
                \\  Ctrl+V         Paste image
                \\  Alt+Enter      Queue follow-up message
                \\  Alt+Up         Restore queued messages to editor
                \\  Page Up/Down   Scroll transcript (half page)
                \\  Scroll Up/Down Scroll transcript
                \\  Shift+Drag     Select text
                \\  !cmd           Run bash (include)
                \\  !!cmd          Run bash (exclude)
                \\  /              Commands
                \\
            );
        },
        .clear => return .clear,
        .cost => return .cost,
        .copy => return .copy,
        .name => {
            if (arg.len == 0) {
                try out.writeAll("usage: /name <display name>\n");
                return .handled;
            }
            // Store name as a session event
            if (!no_session and session_dir_path != null) {
                try writeTextLine(alloc, out, "session named: {s}\n", .{arg});
            } else {
                const em = try report.cli(alloc, "name session", error.SessionDisabled);
                defer alloc.free(em);
                try out.writeAll(em);
            }
        },
        .login => {
            if (arg.len == 0) return .select_login;
            const req = parseAuthReq(arg, null) catch {
                const prov_name = if (std.mem.indexOfAny(u8, arg, " \t")) |i| arg[0..i] else arg;
                try writeTextLine(alloc, out, "unknown provider: {s}\n", .{prov_name});
                return .handled;
            };
            _ = req;
            try out.writeAll(direct_provider_login_disabled_msg);
            return .handled;
        },
        .logout => {
            if (arg.len != 0) {
                const prov = parseAuthProvider(arg) orelse {
                    try writeTextLine(alloc, out, "unknown provider: {s}\n", .{arg});
                    return .handled;
                };
                core.providers.auth.logoutWithHooks(alloc, prov, audit_hooks.auth()) catch |err| {
                    const em = try report.cli(alloc, "logout", err);
                    defer alloc.free(em);
                    try out.writeAll(em);
                    return .handled;
                };
                try writeTextLine(alloc, out, "logged out of {s}\n", .{core.providers.auth.providerName(prov)});
                return .handled;
            }

            const logged_in = core.providers.auth.listLoggedIn(alloc, home) catch try alloc.alloc(core.providers.auth.Provider, 0);
            defer alloc.free(logged_in);
            if (logged_in.len == 0) {
                try out.writeAll("no providers logged in\n");
                return .handled;
            }

            const active_name = resolveDefaultProvider(provider.*);
            if (chooseLogoutProvider(active_name, logged_in)) |prov| {
                core.providers.auth.logoutWithHooks(alloc, prov, audit_hooks.auth()) catch |err| {
                    const em = try report.cli(alloc, "logout", err);
                    defer alloc.free(em);
                    try out.writeAll(em);
                    return .handled;
                };
                try writeTextLine(alloc, out, "logged out of {s}\n", .{core.providers.auth.providerName(prov)});
                return .handled;
            }
            return .select_logout;
        },
        .reload => return .reload,
        .share => {
            try runtimeCtlAudit(ctl_audit, alloc, "share", .net, runtimeShareResName(), null, .start, null, &.{});
            const session_dir = requireSessionDir(session_dir_path, no_session) catch {
                try runtimeCtlAudit(
                    ctl_audit,
                    alloc,
                    "share",
                    .net,
                    runtimeShareResName(),
                    null,
                    .fail,
                    .{ .text = @errorName(error.SessionDisabled), .vis = .mask },
                    &.{},
                );
                const em = try report.cli(alloc, "share session", error.SessionDisabled);
                defer alloc.free(em);
                try out.writeAll(em);
                return .handled;
            };
            const dir = try openDirPath(session_dir, .{});
            defer dir.close(defaultIo());
            const md_path = core.session.@"export".toMarkdownAudited(alloc, dir, sid.*, null, exportAuditHooks(audit_hooks)) catch |err| {
                try runtimeCtlAudit(
                    ctl_audit,
                    alloc,
                    "share",
                    .net,
                    runtimeShareResName(),
                    null,
                    .fail,
                    .{ .text = @errorName(err), .vis = .mask },
                    &.{},
                );
                const em = try report.cli(alloc, "share session", err);
                defer alloc.free(em);
                try out.writeAll(em);
                return .handled;
            };
            defer alloc.free(md_path);
            const gist_url = audit_hooks.share_gist(alloc, audit_hooks.io, md_path, pol) catch |err| {
                try runtimeCtlAudit(
                    ctl_audit,
                    alloc,
                    "share",
                    .net,
                    runtimeShareResName(),
                    null,
                    .fail,
                    .{ .text = @errorName(err), .vis = .mask },
                    &.{},
                );
                const em = try report.cli(alloc, "publish gist", err);
                defer alloc.free(em);
                try out.writeAll(em);
                return .handled;
            };
            defer alloc.free(gist_url);
            const attrs = [_]core.audit.Attribute{
                .{
                    .key = "url",
                    .vis = .mask,
                    .val = .{ .str = gist_url },
                },
            };
            try runtimeCtlAudit(ctl_audit, alloc, "share", .net, runtimeShareResName(), null, .ok, null, &attrs);
            try writeTextLine(alloc, out, "shared: {s}\n", .{gist_url});
        },
        .changelog => {
            const cl = try changelog.formatForDisplay(alloc, 50);
            defer alloc.free(cl);
            try out.writeAll("[What's New]\n");
            try out.writeAll(cl);
            try out.writeAll("\n");
        },
    }
    return .handled;
}

fn runBgCommand(alloc: std.mem.Allocator, bg_mgr: *bg.Manager, arg: []const u8) ![]u8 {
    const body = std.mem.trim(u8, arg, " \t");
    if (body.len == 0) {
        return alloc.dupe(u8, bg_usage);
    }

    const sp = std.mem.indexOfAny(u8, body, " \t");
    const sub = if (sp) |i| body[0..i] else body;
    const rest = if (sp) |i| std.mem.trim(u8, body[i + 1 ..], " \t") else "";

    switch (bg_sub_map.get(sub) orelse return alloc.dupe(u8, bg_usage)) {
        .run => {
            if (rest.len == 0) {
                return alloc.dupe(u8, "usage: /bg run <cmd>\n");
            }
            const id = try bg_mgr.start(rest, null);
            const v = (try bg_mgr.view(alloc, id)) orelse return error.InternalError;
            defer bg.deinitView(alloc, v);
            return std.fmt.allocPrint(alloc, "bg started id={d} pid={d} log={s}\n", .{
                v.id,
                v.pid,
                v.log_path,
            });
        },
        .list => {
            const jobs = try bg_mgr.list(alloc);
            defer bg.deinitViews(alloc, jobs);
            if (jobs.len == 0) return alloc.dupe(u8, "no background jobs\n");

            var out = std.ArrayList(u8).empty;
            errdefer out.deinit(alloc);
            try out.appendSlice(alloc, "id pid state code log cmd\n");
            for (jobs) |j| {
                const code = j.code orelse -1;
                const line = try std.fmt.allocPrint(alloc, "{d} {d} {s} {d} {s} {s}\n", .{
                    j.id,
                    j.pid,
                    bg.stateName(j.state),
                    code,
                    j.log_path,
                    j.cmd,
                });
                defer alloc.free(line);
                try out.appendSlice(alloc, line);
            }
            return out.toOwnedSlice(alloc);
        },
        .show => {
            const id = parseBgId(rest) catch return alloc.dupe(u8, "usage: /bg show <id>\n");
            const v = (try bg_mgr.view(alloc, id)) orelse return alloc.dupe(u8, "bg: not found\n");
            defer bg.deinitView(alloc, v);

            return std.fmt.allocPrint(alloc, "id={d}\npid={d}\nstate={s}\ncode={?}\nstarted_ms={d}\nended_ms={?}\nlog={s}\ncmd={s}\n", .{
                v.id,
                v.pid,
                bg.stateName(v.state),
                v.code,
                v.started_at_ms,
                v.ended_at_ms,
                v.log_path,
                v.cmd,
            });
        },
        .stop => {
            const id = parseBgId(rest) catch return alloc.dupe(u8, "usage: /bg stop <id>\n");
            const stop = try bg_mgr.stop(id);
            return switch (stop) {
                .sent => std.fmt.allocPrint(alloc, "bg stop sent id={d}\n", .{id}),
                .already_done => std.fmt.allocPrint(alloc, "bg already done id={d}\n", .{id}),
                .not_found => std.fmt.allocPrint(alloc, "bg not found id={d}\n", .{id}),
            };
        },
    }
}

fn parseBgId(text: []const u8) !u64 {
    const tok = std.mem.trim(u8, text, " \t");
    if (tok.len == 0) return error.InvalidId;
    return std.fmt.parseInt(u64, tok, 10);
}

fn flushBgDone(alloc: std.mem.Allocator, ui: *tui_harness.Ui, bg_mgr: *bg.Manager) !void {
    const done = try bg_mgr.drainDone(alloc);
    defer bg.deinitViews(alloc, done);

    for (done) |job| {
        const msg = if (job.state == .wait_err)
            try std.fmt.allocPrint(alloc, "[bg {d} {s} err={s} log={s}]", .{
                job.id,
                bg.stateName(job.state),
                job.err_name orelse "",
                job.log_path,
            })
        else
            try std.fmt.allocPrint(alloc, "[bg {d} {s} code={?} log={s}]", .{
                job.id,
                bg.stateName(job.state),
                job.code,
                job.log_path,
            });
        defer alloc.free(msg);
        try ui.tr.infoText(msg);
    }
    if (done.len > 0) ui.tr.scrollToBottom();
}

fn syncBgFooter(alloc: std.mem.Allocator, ui: *tui_harness.Ui, bg_mgr: *bg.Manager) !void {
    const jobs = try bg_mgr.list(alloc);
    defer bg.deinitViews(alloc, jobs);

    const launched: u32 = @intCast(jobs.len);
    var running: u32 = 0;
    for (jobs) |job| {
        if (job.state == .running) running +%= 1;
    }
    const done: u32 = launched -| running;
    ui.panels.setBgStatus(launched, running, done);
}

fn maybeShowVersionUpdate(
    alloc: std.mem.Allocator,
    ui: *tui_harness.Ui,
    check: *version_check.Checker,
    done: *bool,
    out: *std.Io.Writer,
) !void {
    if (done.*) return;
    if (check.poll()) |new_ver| {
        const t = tui_theme.get();
        const ver_msg = try std.fmt.allocPrint(alloc, "Update available: {s}", .{new_ver});
        defer alloc.free(ver_msg);
        try ui.tr.styledText(ver_msg, .{ .fg = t.accent });
        try ui.tr.infoText("  /upgrade or pz --upgrade");
        try ui.tr.infoText("  https://github.com/joelreymont/pz/releases");
        try ui.draw(out);
        done.* = true;
        return;
    }
    if (check.isDone()) done.* = true;
}

/// Resolve a command to an absolute path from hardcoded candidates only.
/// Never consults PATH. Caller must free the returned slice.
fn resolveAbsCmd(alloc: std.mem.Allocator, io: std.Io, candidates: []const []const u8) ![]const u8 {
    for (candidates) |p| {
        std.Io.Dir.accessAbsolute(io, p, .{}) catch continue;
        return try alloc.dupe(u8, p);
    }
    return error.CmdNotFound;
}

const gh_paths = if (builtin.target.os.tag == .macos)
    &[_][]const u8{ "/opt/homebrew/bin/gh", "/usr/local/bin/gh" }
else
    &[_][]const u8{ "/usr/bin/gh", "/usr/local/bin/gh" };

fn shareGist(alloc: std.mem.Allocator, io: std.Io, md_path: []const u8, pol: *const RuntimePolicy) ![]u8 {
    if (!pol.allowsCmdKind("gh", null, "egress")) return error.PolicyDenied;
    const gh = try resolveAbsCmd(alloc, io, gh_paths);
    defer alloc.free(gh);
    const result = try std.process.run(alloc, io, .{
        .argv = &.{ gh, "gist", "create", "--public=false", md_path },
    });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.GistFailed;
    const url = std.mem.trim(u8, result.stdout, " \t\n\r");
    if (url.len == 0) return error.GistFailed;
    return try alloc.dupe(u8, url);
}

fn writeJsonLine(
    alloc: std.mem.Allocator,
    out: *std.Io.Writer,
    value: anytype,
) !void {
    const raw = try std.json.Stringify.valueAlloc(alloc, value, .{});
    defer alloc.free(raw);
    try out.writeAll(raw);
    try out.writeAll("\n");
}

fn writeTextLine(
    alloc: std.mem.Allocator,
    out: *std.Io.Writer,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const raw = try std.fmt.allocPrint(alloc, fmt, args);
    defer alloc.free(raw);
    try out.writeAll(raw);
}

fn listUserMessages(alloc: std.mem.Allocator, session_dir: []const u8, sid: []const u8) ![][]u8 {
    const dir = try openDirPath(session_dir, .{});
    defer dir.close(defaultIo());

    var rdr = core.session.reader.ReplayReader.init(alloc, dir, sid, .{}) catch return try alloc.alloc([]u8, 0);
    defer rdr.deinit();

    var msgs = std.ArrayList([]u8).empty;
    errdefer {
        for (msgs.items) |m| alloc.free(m);
        msgs.deinit(alloc);
    }

    while (try rdr.next()) |ev| {
        if (ev.data == .prompt) {
            const text = ev.data.prompt.text;
            // Truncate to single line, max 80 chars for display
            const nl = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
            const end = @min(nl, 80);
            const display = if (end < text.len) blk: {
                const trimmed = try std.fmt.allocPrint(alloc, "{s}...", .{text[0..end]});
                break :blk trimmed;
            } else try alloc.dupe(u8, text);
            errdefer alloc.free(display);
            try msgs.append(alloc, display);
        }
    }
    return try msgs.toOwnedSlice(alloc);
}

fn applySettingsToggle(ui: *tui_harness.Ui, idx: usize, val: bool, auto_compact_on: *bool) void {
    const si: SettingIdx = @enumFromInt(idx);
    switch (si) {
        .show_tools => ui.tr.show_tools = val,
        .show_thinking => ui.tr.show_thinking = val,
        .auto_compact => auto_compact_on.* = val,
    }
}

const SettingIdx = enum(u8) {
    show_tools = 0,
    show_thinking = 1,
    auto_compact = 2,
};
const setting_labels = [_][]const u8{
    "Show tool output",
    "Show thinking",
    "Auto-compact",
};

fn buildSettingsOverlay(alloc: std.mem.Allocator, ui: *const tui_harness.Ui, auto_compact_on: bool) !tui_overlay.Overlay {
    const toggles = try alloc.alloc(bool, setting_labels.len);
    toggles[@intFromEnum(SettingIdx.show_tools)] = ui.tr.show_tools;
    toggles[@intFromEnum(SettingIdx.show_thinking)] = ui.tr.show_thinking;
    toggles[@intFromEnum(SettingIdx.auto_compact)] = auto_compact_on;
    return .{
        .items = &setting_labels,
        .title = "Settings",
        .kind = .settings,
        .toggles = toggles,
    };
}

fn startLiveTurnWithPrompt(
    live_turn: *LiveTurn,
    live_tctx: *const TurnCtx,
    ui: *tui_harness.Ui,
    sid: []const u8,
    prompt: []const u8,
    model: []const u8,
    provider_label: []const u8,
    popts: core.providers.Opts,
    sys_prompt: ?[]const u8,
    retried_overflow: *bool,
) !void {
    try live_turn.start(live_tctx, .{
        .sid = sid,
        .prompt = prompt,
        .model = model,
        .provider_label = provider_label,
        .provider_opts = popts,
        .system_prompt = sys_prompt,
    });
    retried_overflow.* = false;
    ui.panels.run_state = .streaming;
}

fn normalizeRpcCmd(raw: []const u8) []const u8 {
    const map = std.StaticStringMap([]const u8).initComptime(.{
        .{ "new_session", "new" },
        .{ "get_state", "session" },
        .{ "get_commands", "commands" },
        .{ "set_model", "model" },
        .{ "switch_session", "resume" },
        .{ "follow_up", "prompt" },
        .{ "steer", "prompt" },
    });
    return map.get(raw) orelse raw;
}

fn isSetModelAlias(raw: []const u8) bool {
    return set_model_alias_map.get(raw) != null;
}

const SessStats = struct {
    path: []const u8,
    path_owned: ?[]u8 = null,
    bytes: u64,
    lines: usize,
    user_msgs: u32 = 0,
    asst_msgs: u32 = 0,
    tool_calls: u32 = 0,
    tool_results: u32 = 0,
};

fn sessionStats(
    alloc: std.mem.Allocator,
    session_dir_path: ?[]const u8,
    sid: []const u8,
    no_session: bool,
) !SessStats {
    if (no_session or session_dir_path == null) {
        return .{
            .path = "",
            .bytes = 0,
            .lines = 0,
        };
    }

    const rel = try core.session.path.sidJsonlAlloc(alloc, sid);
    defer alloc.free(rel);
    const abs = try std.fs.path.join(alloc, &.{ session_dir_path.?, rel });
    errdefer alloc.free(abs);

    const f = std.Io.Dir.openFileAbsolute(defaultIo(), abs, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => {
            return .{
                .path = abs,
                .path_owned = abs,
                .bytes = 0,
                .lines = 0,
            };
        },
        else => return err,
    };
    defer f.close(defaultIo());

    const st = try f.stat(defaultIo());
    var lines: usize = 0;
    var user_msgs: u32 = 0;
    var asst_msgs: u32 = 0;
    var tool_calls: u32 = 0;
    var tool_results: u32 = 0;
    // Replay once to count lines and message types.
    if (session_dir_path) |sdp| {
        const dir = openDirPath(sdp, .{}) catch return .{
            .path = abs,
            .path_owned = abs,
            .bytes = st.size,
            .lines = lines,
        };
        defer dir.close(defaultIo());
        var rdr = core.session.ReplayReader.init(alloc, dir, sid, .{}) catch return .{
            .path = abs,
            .path_owned = abs,
            .bytes = st.size,
            .lines = lines,
        };
        defer rdr.deinit();
        while (true) {
            const ev = rdr.next() catch break;
            lines = rdr.line();
            const item = ev orelse break;
            switch (item.data) {
                .prompt => user_msgs += 1,
                .text => asst_msgs += 1,
                .tool_call => tool_calls += 1,
                .tool_result => tool_results += 1,
                else => {}, // .noop, .thinking, .usage, .stop, .err not counted in session stats
            }
        }
        lines = rdr.line();
    }

    return .{
        .path = abs,
        .path_owned = abs,
        .bytes = st.size,
        .lines = lines,
        .user_msgs = user_msgs,
        .asst_msgs = asst_msgs,
        .tool_calls = tool_calls,
        .tool_results = tool_results,
    };
}

fn parseCmdToolMask(raw: []const u8) !u16 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidToolMask;
    const special = std.StaticStringMap(u16).initComptime(.{
        .{ "all", core.tools.builtin.mask_all },
        .{ "none", 0 },
    });
    if (special.get(trimmed)) |m| return m;

    var mask: u16 = 0;
    var it = std.mem.splitScalar(u8, trimmed, ',');
    while (it.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t\r\n");
        if (part.len == 0) return error.InvalidToolMask;
        const bit = core.tools.builtin.maskForName(part) orelse return error.InvalidToolMask;
        if ((mask & bit) != 0) return error.InvalidToolMask;
        mask |= bit;
    }
    return mask;
}

const tui_cmdpicker = @import("../modes/tui/cmdpicker.zig");

fn completeSlashCmd(ed: *tui_harness.editor.Editor) void {
    const text = ed.text();
    if (text.len == 0 or text[0] != '/') return;
    const prefix = text[1..];
    var match: ?[]const u8 = null;
    var count: usize = 0;
    for (tui_cmdpicker.cmds) |cmd| {
        if (prefix.len <= cmd.name.len and std.mem.startsWith(u8, cmd.name, prefix)) {
            if (match == null) match = cmd.name;
            count += 1;
        }
    }
    if (count == 1) {
        if (match) |m| {
            const old_len = ed.buf.items.len;
            const old_cur = ed.cur;
            ed.buf.items.len = 0;
            ed.buf.appendSlice(ed.alloc, "/") catch {
                ed.buf.items.len = old_len;
                ed.cur = old_cur;
                return;
            };
            ed.buf.appendSlice(ed.alloc, m) catch {
                ed.buf.items.len = old_len;
                ed.cur = old_cur;
                return;
            };
            ed.buf.appendSlice(ed.alloc, " ") catch {
                ed.buf.items.len = old_len;
                ed.cur = old_cur;
                return;
            };
            ed.cur = ed.buf.items.len;
        }
    }
}

fn completeFilePath(alloc: std.mem.Allocator, ui: *tui_harness.Ui) !void {
    const text = ui.ed.text();
    const cur = ui.ed.cursor();
    if (cur == 0) return;

    const ws = ui.ed.wordStart(cur);
    const word = text[ws..cur];
    if (word.len == 0) return;

    // Strip @ prefix
    const has_at = word[0] == '@';
    const prefix = if (has_at) word[1..] else word;

    const items = (try tui_path_complete.list(alloc, prefix)) orelse return;
    defer tui_path_complete.freeList(alloc, items);

    const repl: []const u8 = if (items.len == 1)
        items[0]
    else blk: {
        const cp = tui_path_complete.commonPrefix(tui_path_complete.asConst(items));
        if (cp.len <= prefix.len) return; // no progress
        break :blk cp;
    };

    // Build new text: before + [@] + replacement + after
    const at_s: []const u8 = if (has_at) "@" else "";
    const new_text = try std.fmt.allocPrint(alloc, "{s}{s}{s}{s}", .{
        text[0..ws], at_s, repl, text[cur..],
    });
    defer alloc.free(new_text);

    const new_cur = ws + at_s.len + repl.len;
    ui.ed.buf.items.len = 0;
    try ui.ed.buf.appendSlice(ui.ed.alloc, new_text);
    ui.ed.cur = new_cur;
}

fn toolMaskCsvAlloc(alloc: std.mem.Allocator, mask: u16) ![]u8 {
    if (mask == 0) return alloc.dupe(u8, "none");

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);

    const names = [_][]const u8{
        "read",
        "write",
        "bash",
        "edit",
        "grep",
        "find",
        "ls",
        "agent",
        "ask",
        "skill",
    };
    const bits = [_]u16{
        core.tools.builtin.mask_read,
        core.tools.builtin.mask_write,
        core.tools.builtin.mask_bash,
        core.tools.builtin.mask_edit,
        core.tools.builtin.mask_grep,
        core.tools.builtin.mask_find,
        core.tools.builtin.mask_ls,
        core.tools.builtin.mask_agent,
        core.tools.builtin.mask_ask,
        core.tools.builtin.mask_skill,
    };

    var need_sep = false;
    for (names, bits) |name, bit| {
        if ((mask & bit) == 0) continue;
        if (need_sep) try out.append(alloc, ',');
        try out.appendSlice(alloc, name);
        need_sep = true;
    }
    if (!need_sep) try out.appendSlice(alloc, "none");
    return try out.toOwnedSlice(alloc);
}

fn resolveResumeSid(
    alloc: std.mem.Allocator,
    session_dir: []const u8,
    token: ?[]const u8,
) ![]u8 {
    const plan = if (token) |tok|
        try core.session.selector.fromIdOrPrefix(alloc, session_dir, tok)
    else
        try core.session.selector.latestInDir(alloc, session_dir);
    defer alloc.free(plan.dir_path);
    return plan.sid;
}

const SessionOpErr = error{SessionDisabled};

fn requireSessionDir(session_dir_path: ?[]const u8, no_session: bool) SessionOpErr![]const u8 {
    if (no_session or session_dir_path == null) return error.SessionDisabled;
    return session_dir_path.?;
}

/// Resume: resolve the target sid and atomically swap.
/// On error, sid.* is unchanged (rollback-safe).
fn applyResumeSid(
    alloc: std.mem.Allocator,
    sid: *([]u8),
    session_dir_path: ?[]const u8,
    no_session: bool,
    token: ?[]const u8,
) !void {
    const dir = try requireSessionDir(session_dir_path, no_session);
    const next_sid = try resolveResumeSid(alloc, dir, token);
    // Commit: swap only after all fallible ops succeed.
    alloc.free(sid.*);
    sid.* = next_sid;
}

fn mapSessionStopReason(reason: core.session.Event.StopReason) core.providers.StopReason {
    return switch (reason) {
        .done => .done,
        .max_out => .max_out,
        .tool => .tool,
        .canceled => .canceled,
        .err => .err,
    };
}

fn restoreSessionIntoUi(
    alloc: std.mem.Allocator,
    ui: *tui_harness.Ui,
    session_dir_path: ?[]const u8,
    no_session: bool,
    sid: []const u8,
) !void {
    const dir_path = try requireSessionDir(session_dir_path, no_session);
    var dir = try openDirPath(dir_path, .{});
    defer dir.close(defaultIo());

    var rdr = try core.session.ReplayReader.init(alloc, dir, sid, .{});
    defer rdr.deinit();

    // Save transcript block count for atomicity: replay appends new
    // blocks after existing ones. On success we remove the old prefix;
    // on failure we truncate back, preserving the prior transcript.
    const saved_count = ui.tr.blocks.items.len;
    const saved_scroll = ui.tr.scroll_off;

    ui.panels.resetSessionView();

    errdefer {
        // Replay failed: free partially-replayed new blocks, keep old.
        var i = ui.tr.blocks.items.len;
        while (i > saved_count) {
            i -= 1;
            ui.tr.blocks.items[i].deinit(alloc);
        }
        ui.tr.blocks.items.len = saved_count;
        ui.tr.scroll_off = saved_scroll;
    }

    while (try rdr.next()) |ev| {
        // Session JSONL may contain non-UTF-8 bytes from corrupted files
        // or tool output that was persisted verbatim. Sanitize all text
        // fields before passing to TUI which requires valid UTF-8.
        switch (ev.data) {
            .noop => {},
            .prompt => |p| {
                const s = try ensureUtf8OrSanitize(alloc, p.text);
                defer if (s.owned) |o| alloc.free(o);
                try ui.tr.userText(s.text);
            },
            .text => |t| {
                const s = try ensureUtf8OrSanitize(alloc, t.text);
                defer if (s.owned) |o| alloc.free(o);
                try ui.onProvider(.{ .text = s.text });
            },
            .thinking => |t| {
                const s = try ensureUtf8OrSanitize(alloc, t.text);
                defer if (s.owned) |o| alloc.free(o);
                try ui.onProvider(.{ .thinking = s.text });
            },
            .tool_call => |tc| {
                const s_id = try ensureUtf8OrSanitize(alloc, tc.id);
                defer if (s_id.owned) |o| alloc.free(o);
                const s_name = try ensureUtf8OrSanitize(alloc, tc.name);
                defer if (s_name.owned) |o| alloc.free(o);
                const s_args = try ensureUtf8OrSanitize(alloc, tc.args);
                defer if (s_args.owned) |o| alloc.free(o);
                try ui.onProvider(.{ .tool_call = .{
                    .id = s_id.text,
                    .name = s_name.text,
                    .args = s_args.text,
                } });
            },
            .tool_result => |tr| {
                const s_id = try ensureUtf8OrSanitize(alloc, tr.id);
                defer if (s_id.owned) |o| alloc.free(o);
                const s_out = try ensureUtf8OrSanitize(alloc, tr.output);
                defer if (s_out.owned) |o| alloc.free(o);
                try ui.onProvider(.{ .tool_result = .{
                    .id = s_id.text,
                    .output = s_out.text,
                    .is_err = tr.is_err,
                } });
            },
            .usage => |u| try ui.onProvider(.{ .usage = .{
                .in_tok = u.in_tok,
                .out_tok = u.out_tok,
                .tot_tok = u.tot_tok,
                .cache_read = u.cache_read,
                .cache_write = u.cache_write,
            } }),
            .stop => |stop| try ui.onProvider(.{ .stop = .{
                .reason = mapSessionStopReason(stop.reason),
            } }),
            .err => |msg| {
                const s = try ensureUtf8OrSanitize(alloc, msg.text);
                defer if (s.owned) |o| alloc.free(o);
                try ui.onProvider(.{ .err = s.text });
            },
        }
    }

    // Replay succeeded: remove the old transcript prefix.
    for (ui.tr.blocks.items[0..saved_count]) |*b| b.deinit(alloc);
    const new_len = ui.tr.blocks.items.len - saved_count;
    const items = ui.tr.blocks.items;
    for (0..new_len) |i| {
        items[i] = items[saved_count + i];
    }
    ui.tr.blocks.items.len = new_len;

    ui.panels.run_state = .idle;
    ui.tr.scrollToBottom();
}

fn tryRestoreSessionIntoUi(
    alloc: std.mem.Allocator,
    ui: *tui_harness.Ui,
    session_dir_path: ?[]const u8,
    no_session: bool,
    sid: []const u8,
) !bool {
    restoreSessionIntoUi(alloc, ui, session_dir_path, no_session, sid) catch |err| {
        const detail = try report.inlineMsg(alloc, err);
        defer alloc.free(detail);
        const msg = try std.fmt.allocPrint(alloc, "[resume restore failed: {s}]", .{detail});
        defer alloc.free(msg);
        try ui.tr.infoText(msg);
        return false;
    };
    return true;
}

fn applyForkSid(
    alloc: std.mem.Allocator,
    sid: *([]u8),
    session_dir_path: ?[]const u8,
    no_session: bool,
    token: ?[]const u8,
) !void {
    const dir = try requireSessionDir(session_dir_path, no_session);
    const next_sid = if (token) |raw| blk: {
        try core.session.path.validateSid(raw);
        break :blk try alloc.dupe(u8, raw);
    } else try newSid(alloc);
    errdefer alloc.free(next_sid);
    try forkSessionFile(dir, sid.*, next_sid);
    alloc.free(sid.*);
    sid.* = next_sid;
}

fn listSessionsAlloc(alloc: std.mem.Allocator, session_dir: []const u8) ![]u8 {
    const dir = try openDirPath(session_dir, .{ .iterate = true });
    defer dir.close(defaultIo());

    var names = std.ArrayList([]u8).empty;
    defer {
        for (names.items) |n| alloc.free(n);
        names.deinit(alloc);
    }

    var it = dir.iterate();
    while (try it.next(defaultIo())) |ent| {
        if (ent.kind != .file) continue;
        const sid = fileSidFromName(ent.name) orelse continue;
        const dup = try alloc.dupe(u8, sid);
        errdefer alloc.free(dup);
        try names.append(alloc, dup);
    }

    std.sort.pdq([]u8, names.items, {}, lessSid);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    for (names.items) |sid| {
        try out.appendSlice(alloc, sid);
        try out.append(alloc, '\n');
    }
    return try out.toOwnedSlice(alloc);
}

fn listSessionRows(alloc: std.mem.Allocator, session_dir: []const u8) ![]tui_overlay.Overlay.SessionRow {
    const dir = try openDirPath(session_dir, .{ .iterate = true });
    defer dir.close(defaultIo());

    var names = std.ArrayList([]u8).empty;
    defer {
        for (names.items) |n| alloc.free(n);
        names.deinit(alloc);
    }

    var it = dir.iterate();
    while (try it.next(defaultIo())) |ent| {
        if (ent.kind != .file) continue;
        const sid = fileSidFromName(ent.name) orelse continue;
        const dup = try alloc.dupe(u8, sid);
        errdefer alloc.free(dup);
        try names.append(alloc, dup);
    }

    std.sort.pdq([]u8, names.items, {}, lessSid);

    const rows = try alloc.alloc(tui_overlay.Overlay.SessionRow, names.items.len);
    errdefer {
        for (rows) |row| {
            if (row.sid.len > 0) alloc.free(row.sid);
            if (row.title.len > 0) alloc.free(row.title);
            if (row.time.len > 0) alloc.free(row.time);
            if (row.tokens.len > 0) alloc.free(row.tokens);
        }
        alloc.free(rows);
    }
    @memset(rows, .{
        .sid = &.{},
        .title = &.{},
        .time = &.{},
        .tokens = &.{},
    });

    const now_ms = core.time.milliTimestamp();
    for (names.items, 0..) |sid, idx| {
        rows[idx] = try buildSessionRow(alloc, dir, sid, now_ms);
    }
    return rows;
}

fn listSessionSids(alloc: std.mem.Allocator, session_dir: []const u8) ![][]u8 {
    const dir = try openDirPath(session_dir, .{ .iterate = true });
    defer dir.close(defaultIo());

    var names = std.ArrayList([]u8).empty;
    errdefer {
        for (names.items) |n| alloc.free(n);
        names.deinit(alloc);
    }

    var it = dir.iterate();
    while (try it.next(defaultIo())) |ent| {
        if (ent.kind != .file) continue;
        const sid = fileSidFromName(ent.name) orelse continue;
        const dup = try alloc.dupe(u8, sid);
        errdefer alloc.free(dup);
        try names.append(alloc, dup);
    }

    std.sort.pdq([]u8, names.items, {}, lessSid);
    return try names.toOwnedSlice(alloc);
}

fn lessSid(_: void, a: []u8, b: []u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn buildSessionRow(
    alloc: std.mem.Allocator,
    dir: std.Io.Dir,
    sid: []const u8,
    now_ms: i64,
) !tui_overlay.Overlay.SessionRow {
    var title: ?[]u8 = null;
    errdefer if (title) |t| alloc.free(t);
    var last_ms: i64 = 0;
    var tot_tok: u64 = 0;

    const path = try core.session.path.sidJsonlAlloc(alloc, sid);
    defer alloc.free(path);
    const st = try dir.statFile(defaultIo(), path, .{});
    if (st.size > 0) {
        var rdr = try core.session.ReplayReader.init(alloc, dir, sid, .{});
        defer rdr.deinit();

        while (try rdr.next()) |ev| {
            if (ev.at_ms > last_ms) last_ms = ev.at_ms;
            switch (ev.data) {
                .prompt => |p| {
                    if (title == null) title = try sessionTitleAlloc(alloc, p.text);
                },
                .usage => |u| tot_tok +|= u.tot_tok,
                else => {}, // .noop, .text, .thinking, .tool_call, .tool_result, .stop, .err not needed for session list
            }
        }
    }

    const sid_dup = try alloc.dupe(u8, sid);
    errdefer alloc.free(sid_dup);
    const row_title = if (title) |t| t else try alloc.dupe(u8, sid);
    errdefer if (title == null) alloc.free(row_title);
    const time = try formatSessionAgeAlloc(alloc, now_ms, last_ms);
    errdefer alloc.free(time);
    const tokens = try formatSessionTokensAlloc(alloc, tot_tok);
    errdefer alloc.free(tokens);

    return .{
        .sid = sid_dup,
        .title = row_title,
        .time = time,
        .tokens = tokens,
    };
}

fn sessionTitleAlloc(alloc: std.mem.Allocator, text: []const u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;
    const line = if (std.mem.indexOfScalar(u8, trimmed, '\n')) |nl| trimmed[0..nl] else trimmed;
    const one = std.mem.trim(u8, line, " \t\r");
    if (one.len == 0) return null;
    return try alloc.dupe(u8, one);
}

fn formatSessionAgeAlloc(alloc: std.mem.Allocator, now_ms: i64, last_ms: i64) ![]u8 {
    if (last_ms <= 0 or last_ms >= now_ms) return alloc.dupe(u8, "now");

    const diff_ms: u64 = @intCast(now_ms - last_ms);
    const diff_min = diff_ms / (60 * std.time.ms_per_s);
    const diff_hour = diff_ms / (60 * 60 * std.time.ms_per_s);
    const diff_day = diff_ms / (24 * 60 * 60 * std.time.ms_per_s);

    if (diff_min < 1) return alloc.dupe(u8, "now");
    if (diff_min < 60) return std.fmt.allocPrint(alloc, "{d}m", .{diff_min});
    if (diff_hour < 24) return std.fmt.allocPrint(alloc, "{d}h", .{diff_hour});
    if (diff_day < 7) return std.fmt.allocPrint(alloc, "{d}d", .{diff_day});
    if (diff_day < 30) return std.fmt.allocPrint(alloc, "{d}w", .{diff_day / 7});
    if (diff_day < 365) return std.fmt.allocPrint(alloc, "{d}mo", .{diff_day / 30});
    return std.fmt.allocPrint(alloc, "{d}y", .{diff_day / 365});
}

fn formatSessionTokensAlloc(alloc: std.mem.Allocator, tot_tok: u64) ![]u8 {
    if (tot_tok >= 1_000_000) {
        return std.fmt.allocPrint(alloc, "{d}.{d}M tok", .{ tot_tok / 1_000_000, (tot_tok % 1_000_000) / 100_000 });
    }
    if (tot_tok >= 1000) {
        return std.fmt.allocPrint(alloc, "{d}.{d}k tok", .{ tot_tok / 1000, (tot_tok % 1000) / 100 });
    }
    return std.fmt.allocPrint(alloc, "{d} tok", .{tot_tok});
}

fn fileSidFromName(name: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, name, ".jsonl")) return null;
    if (name.len <= ".jsonl".len) return null;
    return name[0 .. name.len - ".jsonl".len];
}

fn forkSessionFile(session_dir: []const u8, src_sid: []const u8, dst_sid: []const u8) !void {
    const dir = try openDirPath(session_dir, .{});
    defer dir.close(defaultIo());

    var src_buf: [256]u8 = undefined;
    const src_path = std.fmt.bufPrint(&src_buf, "{s}.jsonl", .{src_sid}) catch return error.NameTooLong;
    var dst_buf: [256]u8 = undefined;
    const dst_path = std.fmt.bufPrint(&dst_buf, "{s}.jsonl", .{dst_sid}) catch return error.NameTooLong;

    const dst = try dir.createFile(defaultIo(), dst_path, .{
        .truncate = true,
    });
    defer dst.close(defaultIo());

    const src = dir.openFile(defaultIo(), src_path, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer src.close(defaultIo());

    var buf: [8192]u8 = undefined;
    while (true) {
        const n = src.readStreaming(defaultIo(), &.{buf[0..]}) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => return err,
        };
        if (n == 0) break;
        try dst.writeStreamingAll(defaultIo(), buf[0..n]);
    }
    try dst.sync(defaultIo());
}

fn newSid(alloc: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(alloc, "{d}", .{core.time.microTimestamp()});
}

fn resolveSessionPlan(alloc: std.mem.Allocator, run_cmd: cli.Run) !core.session.selector.Plan {
    return switch (run_cmd.session) {
        .auto => .{
            .sid = try newSid(alloc),
            .dir_path = try alloc.dupe(u8, run_cmd.cfg.session_dir),
        },
        .cont, .resm => core.session.selector.latestInDir(alloc, run_cmd.cfg.session_dir),
        .explicit => |raw| {
            if (isPathLike(raw)) return core.session.selector.fromPath(alloc, raw);
            return core.session.selector.fromIdOrPrefix(alloc, run_cmd.cfg.session_dir, raw);
        },
    };
}

fn getApprovalLocAlloc(alloc: std.mem.Allocator, io: std.Io) !core.loop.CmdCache.Loc {
    if (try runCmdTrimAlloc(alloc, &.{ "jj", "root" }, 4096)) |root| {
        return .{ .repo_root = root };
    }
    if (try runCmdTrimAlloc(alloc, &.{ "git", "rev-parse", "--show-toplevel" }, 4096)) |root| {
        return .{ .repo_root = root };
    }
    // currentPathAlloc returns a sentinel slice ([:0]u8, n+1 bytes). Loc.cwd is
    // []const u8, which would erase the sentinel length and make freeApprovalLoc
    // free n instead of n+1. Copy into an exact-length []u8 so alloc/free match.
    const abs = try std.process.currentPathAlloc(io, alloc);
    defer alloc.free(abs);
    return .{ .cwd = try alloc.dupe(u8, abs) };
}

fn freeApprovalLoc(alloc: std.mem.Allocator, loc: core.loop.CmdCache.Loc) void {
    switch (loc) {
        .cwd => |cwd| alloc.free(cwd),
        .repo_root => |root| alloc.free(root),
    }
}

fn loadApprovalBindAlloc(alloc: std.mem.Allocator, io: std.Io, home: ?[]const u8) !core.policy.ApprovalBind {
    const cwd = try std.process.currentPathAlloc(io, alloc);
    defer alloc.free(cwd);
    return core.policy.loadApprovalBind(alloc, io, cwd, home);
}

fn getProjectPath(alloc: std.mem.Allocator, io: std.Io, home: ?[]const u8) ![]u8 {
    const loc = try getApprovalLocAlloc(alloc, io);
    defer freeApprovalLoc(alloc, loc);
    switch (loc) {
        .cwd => |cwd| return shortenHomePath(alloc, cwd, home),
        .repo_root => |root| return shortenHomePath(alloc, root, home),
    }
}

fn shortenHomePath(alloc: std.mem.Allocator, full: []const u8, home: ?[]const u8) ![]u8 {
    const h = home orelse "";
    if (h.len > 0 and std.mem.startsWith(u8, full, h)) {
        return std.fmt.allocPrint(alloc, "~{s}", .{full[h.len..]});
    }
    return alloc.dupe(u8, full);
}

fn getGitBranch(alloc: std.mem.Allocator) ![]u8 {
    if (try getJjBranch(alloc)) |b| return b;

    if (try runCmdTrimAlloc(alloc, &.{ "git", "branch", "--show-current" }, 512)) |branch| {
        return branch;
    }
    if (try runCmdTrimAlloc(alloc, &.{ "git", "rev-parse", "--abbrev-ref", "HEAD" }, 512)) |branch| {
        if (!std.mem.eql(u8, branch, "HEAD")) return branch;
        alloc.free(branch);
    }

    const head = std.Io.Dir.cwd().readFileAlloc(defaultIo(), ".git/HEAD", alloc, .limited(256)) catch return error.NotFound;
    defer alloc.free(head);
    const prefix = "ref: refs/heads/";
    if (std.mem.startsWith(u8, head, prefix)) {
        const rest = std.mem.trim(u8, head[prefix.len..], "\n\r ");
        return try alloc.dupe(u8, rest);
    }
    // Detached HEAD — show "detached" like pi
    return try alloc.dupe(u8, "detached");
}

fn getJjBranch(alloc: std.mem.Allocator) error{OutOfMemory}!?[]u8 {
    const current = try runCmdTrimAlloc(alloc, &.{ "jj", "log", "--no-graph", "-r", "@", "-T", "bookmarks" }, 4096);
    if (current) |raw| {
        defer alloc.free(raw);
        if (parseJjBookmark(raw)) |name| {
            return try alloc.dupe(u8, name);
        }
    }

    const parent = try runCmdTrimAlloc(alloc, &.{ "jj", "log", "--no-graph", "-r", "@-", "-T", "bookmarks" }, 4096);
    if (parent) |raw| {
        defer alloc.free(raw);
        if (parseJjBookmark(raw)) |name| {
            return try alloc.dupe(u8, name);
        }
    }

    return null;
}

fn parseJjBookmark(raw: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;

    var it = std.mem.splitScalar(u8, trimmed, ' ');
    const first = it.next() orelse return null;
    const name = if (first.len > 0 and first[first.len - 1] == '*')
        first[0 .. first.len - 1]
    else
        first;
    if (name.len == 0) return null;
    if (looksLikeHexCommit(name)) return null;
    return name;
}

fn looksLikeHexCommit(text: []const u8) bool {
    if (text.len < 12) return false;
    for (text) |c| {
        if ((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F')) {
            continue;
        }
        return false;
    }
    return true;
}

// hardcoded argv, no user input -- policy gate not needed
fn runCmdTrimAlloc(alloc: std.mem.Allocator, argv: []const []const u8, max_bytes: usize) error{OutOfMemory}!?[]u8 {
    const result = std.process.run(alloc, defaultIo(), .{
        .argv = argv,
        .stdout_limit = .limited(max_bytes),
        .stderr_limit = .limited(max_bytes),
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null, // exec failure, command not found — expected for optional lookups
    };
    defer alloc.free(result.stderr);
    defer alloc.free(result.stdout);
    if (result.term != .exited or result.term.exited != 0) return null;
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) return null;
    // Sanitize: external process output may contain invalid UTF-8
    return try sanitizeUtf8LossyAlloc(alloc, trimmed);
}

test "parseJjBookmark extracts first bookmark" {
    const got = parseJjBookmark("main feature") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("main", got);
}

test "parseJjBookmark strips working-copy marker" {
    const got = parseJjBookmark("trunk*") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("trunk", got);
}

test "parseJjBookmark rejects detached hash" {
    try std.testing.expect(parseJjBookmark("44693e6218c0b15a85acf5d2af52149b09dc4c76") == null);
}

test "parseNativeProviderKind resolves native and dynamic providers" {
    // Native fast paths.
    try std.testing.expectEqual(NativeProviderKind.anthropic, parseNativeProviderKind("anthropic").?);
    try std.testing.expectEqual(NativeProviderKind.openai, parseNativeProviderKind("openai").?);
    // MP7: every OpenAI-compatible provider now resolves to a runtime kind
    // (previously these returned null and fell through to "unsupported").
    try std.testing.expectEqual(NativeProviderKind.openrouter, parseNativeProviderKind("openrouter").?);
    try std.testing.expectEqual(NativeProviderKind.google, parseNativeProviderKind("google").?);
    try std.testing.expectEqual(NativeProviderKind.mistral, parseNativeProviderKind("mistral").?);
    try std.testing.expectEqual(NativeProviderKind.groq, parseNativeProviderKind("groq").?);
    try std.testing.expectEqual(NativeProviderKind.deepseek, parseNativeProviderKind("deepseek").?);
    // Unknown names still miss (no silent fallback).
    try std.testing.expect(parseNativeProviderKind("not-a-provider") == null);
}

test "DynamicKind.fromNative splits native fast paths from dynamic providers" {
    // anthropic/openai are native and have NO dynamic kind.
    try std.testing.expect(DynamicKind.fromNative(.anthropic) == null);
    try std.testing.expect(DynamicKind.fromNative(.openai) == null);
    // Every other native kind maps to its dynamic counterpart.
    try std.testing.expectEqual(DynamicKind.openrouter, DynamicKind.fromNative(.openrouter).?);
    try std.testing.expectEqual(DynamicKind.google, DynamicKind.fromNative(.google).?);
    try std.testing.expectEqual(DynamicKind.mistral, DynamicKind.fromNative(.mistral).?);
    try std.testing.expectEqual(DynamicKind.groq, DynamicKind.fromNative(.groq).?);
    try std.testing.expectEqual(DynamicKind.deepseek, DynamicKind.fromNative(.deepseek).?);
}

test "DynamicKind name and auth tag round-trip through the registry" {
    // Each dynamic kind's name must be a registered provider, and its auth tag
    // must match the auth identity the corresponding Cfg was built with.
    inline for (@typeInfo(DynamicKind).@"enum".fields) |field| {
        const dk: DynamicKind = @field(DynamicKind, field.name);
        try std.testing.expect(core.providers.registry.resolveProvider(dk.name()) != null);
    }
    // openrouter/groq/deepseek/mistral reuse the `.openai` auth identity; google
    // has its own. This mirrors each module's Cfg.provider_tag exactly.
    try std.testing.expectEqual(core.providers.auth.Provider.openai, DynamicKind.openrouter.authTag());
    try std.testing.expectEqual(core.providers.auth.Provider.openai, DynamicKind.groq.authTag());
    try std.testing.expectEqual(core.providers.auth.Provider.openai, DynamicKind.deepseek.authTag());
    try std.testing.expectEqual(core.providers.auth.Provider.openai, DynamicKind.mistral.authTag());
    try std.testing.expectEqual(core.providers.auth.Provider.google, DynamicKind.google.authTag());
}

test "missingProviderMsgForInitErr directs users to approved provider command adapters" {
    const msg = missingProviderMsgForInitErr(.anthropic, error.AuthNotFound);
    try std.testing.expect(std.mem.indexOf(u8, msg, "direct provider runtimes are disabled by policy") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "PZ_PROVIDER_CMD") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "approved CLI adapter") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "ANTHROPIC_API_KEY") == null);
    try std.testing.expect(std.mem.indexOf(u8, missingProviderMsgForInitErr(.openai, error.AuthNotFound), "OPENAI_API_KEY") == null);
    try std.testing.expect(std.mem.indexOf(u8, missingProviderMsgForInitErr(.google, error.AuthNotFound), "GOOGLE_API_KEY") == null);
    try std.testing.expect(std.mem.indexOf(u8, missingProviderMsgForInitErr(.deepseek, error.AuthNotFound), "PZ_PROVIDER_CMD") != null);
}

// MP4-R2: `pz login <newprovider>` must resolve provider names, but direct
// credential capture is disabled in this fork. Runtime access goes through an
// explicit `--provider-cmd`/`PZ_PROVIDER_CMD` approved CLI adapter.
test "login name resolves to auth provider for native and new providers" {
    try std.testing.expectEqual(core.providers.auth.Provider.anthropic, parseAuthProvider("anthropic").?);
    try std.testing.expectEqual(core.providers.auth.Provider.openai, parseAuthProvider("openai").?);
    try std.testing.expectEqual(core.providers.auth.Provider.google, parseAuthProvider("google").?);
    // MP4-R2 additions: these previously returned null → "unknown provider".
    try std.testing.expectEqual(core.providers.auth.Provider.openrouter, parseAuthProvider("openrouter").?);
    try std.testing.expectEqual(core.providers.auth.Provider.mistral, parseAuthProvider("mistral").?);
    try std.testing.expectEqual(core.providers.auth.Provider.groq, parseAuthProvider("groq").?);
    try std.testing.expectEqual(core.providers.auth.Provider.deepseek, parseAuthProvider("deepseek").?);
    // A bogus name still fails to resolve (caller surfaces "unknown provider").
    try std.testing.expect(parseAuthProvider("nope") == null);
}

test "pz login <newprovider> resolves names but rejects direct credential capture" {
    const cases = [_]struct { name: []const u8, tag: core.providers.auth.Provider }{
        .{ .name = "mistral", .tag = .mistral },
        .{ .name = "groq", .tag = .groq },
        .{ .name = "deepseek", .tag = .deepseek },
        .{ .name = "openrouter", .tag = .openrouter },
    };
    for (cases) |c| {
        const prov = parseAuthProvider(c.name) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(c.tag, prov);

        const req = try parseAuthReq(c.name, null);
        try std.testing.expectEqual(c.tag, req.prov);
        var out_buf: [512]u8 = undefined;
        var out_writer: std.Io.Writer = .fixed(&out_buf);
        try runLoginFlow(std.testing.allocator, &out_writer, req, .{});
        const written = out_writer.buffered();
        try std.testing.expect(std.mem.indexOf(u8, written, "direct provider login disabled by policy") != null);
        try std.testing.expect(std.mem.indexOf(u8, written, "PZ_PROVIDER_CMD") != null);
        try std.testing.expect(std.mem.indexOf(u8, written, "API_KEY") == null);
    }
}

test "pz login <newprovider> does not save direct provider api keys" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);

    const req = try parseAuthReq("mistral ml-key-789", null);
    try std.testing.expectEqual(core.providers.auth.Provider.mistral, req.prov);
    try std.testing.expectEqualStrings("mistral", req.prov_name);
    try std.testing.expectEqualStrings("ml-key-789", req.key);
    try std.testing.expectEqual(LoginInputKind.api_key, classifyLoginInput(req.prov, req.key));

    var out_buf: [512]u8 = undefined;
    var out_writer: std.Io.Writer = .fixed(&out_buf);
    try runLoginFlow(std.testing.allocator, &out_writer, req, .{ .home_override = home });
    try std.testing.expect(std.mem.indexOf(u8, out_writer.buffered(), "direct provider login disabled by policy") != null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, ".pz/auth.json", .{}));
}

// ── Dynamic provider dispatch e2e (MP7) ──────────────────────────────────────
// Mirrors `client.zig`'s router e2e but exercises the runtime's name-match
// routing contract (`DynamicProvider.lookup` semantics): a request whose
// resolved provider matches the wired backend streams end-to-end; any other
// (still-registered) provider surfaces `error.NoBackend` with NO dispatch.

// A scripted backend Provider that records the model it was forwarded and emits
// a text+stop pair. Single Stream allocation, matching the real contract.
const E2eBackend = struct {
    provider: core.providers.Provider = .{ .vt = &vt },
    seen_model: []u8 = &.{},
    started: usize = 0,

    const vt = core.providers.Provider.Vt{ .start = startFn };

    const E2eStream = struct {
        stream: core.providers.Stream = .{ .vt = &stream_vt },
        alloc: std.mem.Allocator,
        idx: u8 = 0,

        const stream_vt = core.providers.Stream.Vt{ .next = nextFn, .deinit = deinitFn };

        fn nextFn(s: *core.providers.Stream) anyerror!?core.providers.Event {
            const self: *E2eStream = @fieldParentPtr("stream", s);
            defer self.idx +|= 1;
            return switch (self.idx) {
                0 => .{ .text = "from-dynamic" },
                1 => .{ .stop = .{ .reason = .done } },
                else => null,
            };
        }
        fn deinitFn(s: *core.providers.Stream) void {
            const self: *E2eStream = @fieldParentPtr("stream", s);
            self.alloc.destroy(self);
        }
    };

    fn startFn(p: *core.providers.Provider, req: core.providers.Request) anyerror!*core.providers.Stream {
        const self: *E2eBackend = @fieldParentPtr("provider", p);
        self.started += 1;
        self.seen_model = try std.testing.allocator.dupe(u8, req.model);
        const st = try std.testing.allocator.create(E2eStream);
        st.* = .{ .alloc = std.testing.allocator };
        return &st.stream;
    }

    fn freeSeen(self: *E2eBackend) void {
        if (self.seen_model.len != 0) std.testing.allocator.free(self.seen_model);
    }
};

// Routing context that reuses the EXACT name-match contract DynamicProvider
// uses: forward only when the resolved provider equals `kind.name()`.
const E2eRouteCtx = struct {
    kind: DynamicKind,
    backend: *core.providers.Provider,

    fn lookup(self: *E2eRouteCtx, lookup_name: []const u8) ?*core.providers.Provider {
        if (std.mem.eql(u8, lookup_name, self.kind.name())) return self.backend;
        return null;
    }
};

test "dynamic provider streams end-to-end and strips the model suffix" {
    var backend = E2eBackend{};
    defer backend.freeSeen();
    var ctx = E2eRouteCtx{ .kind = .mistral, .backend = &backend.provider };
    var router = core.providers.client.Router.init(
        core.providers.client.DynamicCfg.from(E2eRouteCtx, &ctx, E2eRouteCtx.lookup),
    );

    // Route by model suffix (`<model>:mistral`): the router resolves mistral,
    // forwards the BARE model, and the backend streams the canned events.
    var stream = try router.provider.start(.{ .model = "mistral-large:mistral", .msgs = &.{} });
    defer stream.deinit();

    const ev0 = (try stream.next()) orelse return error.TestUnexpectedResult;
    const ev1 = (try stream.next()) orelse return error.TestUnexpectedResult;
    try std.testing.expect((try stream.next()) == null);
    try std.testing.expectEqualStrings("from-dynamic", ev0.text);
    try std.testing.expectEqual(core.providers.StopReason.done, ev1.stop.reason);

    // Backend saw the bare model (suffix stripped) and was started exactly once.
    try std.testing.expectEqual(@as(usize, 1), backend.started);
    try std.testing.expectEqualStrings("mistral-large", backend.seen_model);
}

test "dynamic provider rejects a non-matching provider with a named error" {
    var backend = E2eBackend{};
    defer backend.freeSeen();
    var ctx = E2eRouteCtx{ .kind = .mistral, .backend = &backend.provider };
    var router = core.providers.client.Router.init(
        core.providers.client.DynamicCfg.from(E2eRouteCtx, &ctx, E2eRouteCtx.lookup),
    );

    // groq is a registered provider but not the wired backend → NoBackend, and
    // the backend is never started (no fallback, no silent reroute).
    try std.testing.expectError(
        error.NoBackend,
        router.provider.start(.{ .model = "llama", .provider = "groq", .msgs = &.{} }),
    );
    // An unregistered provider fails the dispatch resolve before any lookup.
    try std.testing.expectError(
        error.UnknownProvider,
        router.provider.start(.{ .model = "x", .provider = "not-real", .msgs = &.{} }),
    );
    try std.testing.expectEqual(@as(usize, 0), backend.started);
}

const default_model = "gpt-5.5";
const default_provider = "codex";

fn resolveDefault(model: []const u8) []const u8 {
    return if (std.mem.eql(u8, model, "default")) default_model else model;
}

fn resolveDefaultProvider(provider: []const u8) []const u8 {
    return if (std.mem.eql(u8, provider, "default")) default_provider else provider;
}

fn modelCtxWindow(model: []const u8) u64 {
    const table = .{
        .{ "opus-4-6", 1000000 },
        .{ "opus-4-5", 200000 },
        .{ "opus-4", 200000 },
        .{ "sonnet-4-6", 200000 },
        .{ "sonnet-4-5", 200000 },
        .{ "sonnet-4", 200000 },
        .{ "haiku-4-5", 200000 },
        .{ "haiku-4", 200000 },
        .{ "claude-3-5", 200000 },
        .{ "claude-3.5", 200000 },
        .{ "claude-3-7", 200000 },
        .{ "claude-3.7", 200000 },
    };
    inline for (table) |entry| {
        if (std.mem.indexOf(u8, model, entry[0]) != null) return entry[1];
    }
    return 200000; // sensible default
}

fn isPathLike(raw: []const u8) bool {
    if (std.mem.endsWith(u8, raw, ".jsonl")) return true;
    if (std.mem.indexOfScalar(u8, raw, '/')) |_| return true;
    if (std.mem.indexOfScalar(u8, raw, '\\')) |_| return true;
    return false;
}

fn buildSystemPrompt(alloc: std.mem.Allocator, run_cmd: cli.Run, home: ?[]const u8) !?[]u8 {
    if (run_cmd.cfg.policy_lock.system_prompt and
        (run_cmd.system_prompt != null or run_cmd.append_system_prompt != null))
    {
        return error.PolicyLockedSystemPrompt;
    }
    if (run_cmd.cfg.policy_lock.context) {
        const paths = try core.context.discoverPaths(alloc, run_cmd.io, home);
        defer {
            for (paths) |p| alloc.free(p);
            alloc.free(paths);
        }
        if (paths.len > 0) return error.PolicyLockedContext;
    }
    if (run_cmd.system_prompt) |sp| {
        if (run_cmd.append_system_prompt) |ap| {
            return try std.fmt.allocPrint(alloc, "{s}\n\n{s}", .{ sp, ap });
        }
        return try alloc.dupe(u8, sp);
    }

    const ctx = try core.context.load(alloc, run_cmd.io, home);
    if (run_cmd.append_system_prompt) |ap| {
        if (ctx) |c| {
            defer alloc.free(c);
            return try std.fmt.allocPrint(alloc, "{s}\n\n{s}", .{ c, ap });
        }
        return try alloc.dupe(u8, ap);
    }
    return ctx;
}

const model_cycle = [_][]const u8{
    default_model,
    "claude-opus-4-8",
    "gemini-3.5-flash",
};

const provider_args = core.providers.auth.provider_names;
const tool_args = [_][]const u8{ "all", "none", "read", "write", "bash", "edit", "grep", "find", "ls", "agent", "ask", "skill" };
const bg_args = [_][]const u8{ "run", "list", "show", "stop" };
const bg_usage = "usage: /bg run <cmd>|list|show <id>|stop <id>\n";
const BgSub = enum {
    run,
    list,
    show,
    stop,
};
const bg_sub_map = std.StaticStringMap(BgSub).initComptime(.{
    .{ "run", .run },
    .{ "list", .list },
    .{ "show", .show },
    .{ "stop", .stop },
});
const set_model_alias_map = std.StaticStringMap(void).initComptime(.{
    .{
        "set_model",
        {},
    },
});

const arg_src_kind_map = std.StaticStringMap(enum {
    model,
    provider,
    tools,
    bg,
    auth_provider,
}).initComptime(.{
    .{ "model", .model },
    .{ "provider", .provider },
    .{ "tools", .tools },
    .{ "bg", .bg },
    .{ "login", .auth_provider },
    .{ "logout", .auth_provider },
});

// CLI/login name → canonical auth provider tag. Direct credential capture is
// disabled by policy, but command parsing and logout still need stable provider
// identity resolution.
const auth_provider_map = std.StaticStringMap(core.providers.auth.Provider).initComptime(.{
    .{ "anthropic", .anthropic },
    .{ "openai", .openai },
    .{ "google", .google },
    .{ "openrouter", .openrouter },
    .{ "mistral", .mistral },
    .{ "groq", .groq },
    .{ "deepseek", .deepseek },
});

fn parseAuthProvider(name: []const u8) ?core.providers.auth.Provider {
    return auth_provider_map.get(name);
}

const LoginInputKind = enum {
    api_key,
    oauth_start,
    oauth_complete,
};

fn classifyLoginInput(prov: core.providers.auth.Provider, key: []const u8) LoginInputKind {
    if (!core.providers.auth.oauthCapable(prov)) return .api_key;
    if (key.len == 0) return .oauth_start;
    if (core.providers.auth.looksLikeApiKey(prov, key)) return .api_key;
    return .oauth_complete;
}

fn hasLoggedInProvider(
    logged_in: []const core.providers.auth.Provider,
    provider: core.providers.auth.Provider,
) bool {
    for (logged_in) |p| if (p == provider) return true;
    return false;
}

fn chooseLogoutProvider(
    active_name: []const u8,
    logged_in: []const core.providers.auth.Provider,
) ?core.providers.auth.Provider {
    if (parseAuthProvider(active_name)) |active| {
        if (hasLoggedInProvider(logged_in, active)) return active;
    }
    if (logged_in.len == 1) return logged_in[0];
    return null;
}

/// Resolve arg completion source based on current editor text.
fn resolveArgSrc(text: []const u8, models: []const []const u8) ?[]const []const u8 {
    if (text.len == 0 or text[0] != '/') return null;
    const body = text[1..];
    const sp = std.mem.indexOfScalar(u8, body, ' ') orelse return null;
    const cmd = body[0..sp];
    const kind = arg_src_kind_map.get(cmd) orelse return null;
    return switch (kind) {
        .model => models,
        .provider, .auth_provider => &provider_args,
        .tools => &tool_args,
        .bg => &bg_args,
    };
}

fn cycleModel(alloc: std.mem.Allocator, cur: []const u8, model_owned: *?[]u8, cycle: []const []const u8) ![]const u8 {
    if (cycle.len == 0) return cur;
    var next_idx: usize = 0;
    for (cycle, 0..) |m, i| {
        if (std.mem.eql(u8, cur, m)) {
            next_idx = (i + 1) % cycle.len;
            break;
        }
    } else {
        next_idx = 0;
    }
    const new = try alloc.dupe(u8, cycle[next_idx]);
    if (model_owned.*) |old| alloc.free(old);
    model_owned.* = new;
    return new;
}

fn reverseCycleModel(alloc: std.mem.Allocator, cur: []const u8, model_owned: *?[]u8, cycle: []const []const u8) ![]const u8 {
    if (cycle.len == 0) return cur;
    var next_idx: usize = cycle.len - 1;
    for (cycle, 0..) |m, i| {
        if (std.mem.eql(u8, cur, m)) {
            next_idx = if (i == 0) cycle.len - 1 else i - 1;
            break;
        }
    }
    const new = try alloc.dupe(u8, cycle[next_idx]);
    if (model_owned.*) |old| alloc.free(old);
    model_owned.* = new;
    return new;
}

fn cycleThinking(cur: args_mod.ThinkingLevel) args_mod.ThinkingLevel {
    return switch (cur) {
        .adaptive => .off,
        .off => .minimal,
        .minimal => .low,
        .low => .medium,
        .medium => .high,
        .high => .xhigh,
        .xhigh => .adaptive,
    };
}

fn thinkingLabel(level: args_mod.ThinkingLevel) []const u8 {
    return @tagName(level);
}

fn thinkingBorderFg(level: args_mod.ThinkingLevel) @import("../modes/tui/frame.zig").Color {
    const t = tui_theme.get();
    return switch (level) {
        .off => t.thinking_off,
        .minimal => t.thinking_min,
        .low => t.thinking_low,
        .medium => t.thinking_med,
        .high => t.thinking_high,
        .xhigh => t.thinking_xhigh,
        .adaptive => t.thinking_med,
    };
}

fn showStartup(alloc: std.mem.Allocator, io: std.Io, ui: *tui_harness.Ui, is_resumed: bool, home: ?[]const u8) !void {
    const t = tui_theme.get();

    // Version banner (matching pi's "pi v0.52.12")
    const ver_line = " pz v" ++ cli.version ++ " (" ++ cli.git_hash ++ ")";
    try ui.tr.styledText(ver_line, .{ .fg = t.dim });

    // Hotkeys — key in dim, description in muted
    const keys = [_][2][]const u8{
        .{ "escape", "to interrupt" },
        .{ "ctrl+c", "to clear" },
        .{ "ctrl+c twice", "to exit" },
        .{ "ctrl+d", "to exit (empty)" },
        .{ "ctrl+z", "to undo" },
        .{ "up/down", "for input history" },
        .{ "ctrl+a/e", "to start/end of line" },
        .{ "ctrl+j", "to insert newline" },
        .{ "ctrl+k/u", "to delete to end/all" },
        .{ "ctrl+w", "to delete word" },
        .{ "alt+b/f", "to move by word" },
        .{ "shift+tab", "to cycle thinking level" },
        .{ "ctrl+p/shift+ctrl+p", "to cycle models" },
        .{ "ctrl+l", "to select model" },
        .{ "ctrl+o", "to expand tools" },
        .{ "ctrl+t", "to expand thinking" },
        .{ "ctrl+g", "for external editor" },
        .{ "/", "for commands" },
        .{ "!", "to run bash" },
        .{ "!!", "to run bash (no context)" },
        .{ "alt+enter", "to queue follow-up" },
        .{ "alt+up", "to restore queued messages" },
        .{ "ctrl+v", "to paste image" },
        .{ "shift+drag", "to select text" },
        .{ "drop files", "to attach" },
    };
    for (keys) |kv| {
        // key in dim, description in muted (matching pi)
        const line = try std.fmt.allocPrint(alloc, " \x1b[38;2;102;102;102m{s}\x1b[38;2;128;128;128m {s}\x1b[0m", .{ kv[0], kv[1] });
        defer alloc.free(line);
        try ui.tr.pushAnsiText(line);
    }

    // Context section
    const ctx_paths = try core.context.discoverPaths(alloc, io, home);
    defer {
        for (ctx_paths) |p| alloc.free(p);
        alloc.free(ctx_paths);
    }
    if (ctx_paths.len > 0) {
        try ui.tr.styledText("", .{}); // blank line
        try ui.tr.styledText("", .{}); // blank line (pi has 2)
        try ui.tr.styledText("[Context]", .{ .fg = t.md_heading });
        const h = home orelse "";
        for (ctx_paths) |p| {
            // Shorten home prefix to ~/; paths may contain non-UTF-8 bytes
            const display = if (h.len > 0 and std.mem.startsWith(u8, p, h))
                try std.fmt.allocPrint(alloc, "  ~{s}", .{p[h.len..]})
            else
                try std.fmt.allocPrint(alloc, "  {s}", .{p});
            defer alloc.free(display);
            try infoTextSafe(alloc, ui, display);
        }
    }

    // Skills section
    const skills = try discoverSkills(alloc, home);
    defer core_skill.freeSkills(alloc, skills);
    if (skills.len > 0) {
        try ui.tr.styledText("", .{}); // blank line
        try ui.tr.styledText("[Skills]", .{ .fg = t.md_heading });
        for (skills) |skill| {
            const display = if (skill.meta.description.len > 0)
                try std.fmt.allocPrint(alloc, "  {s} [{s}] - {s}", .{
                    skill.dir_name,
                    skillSourceName(skill.source),
                    skill.meta.description,
                })
            else
                try std.fmt.allocPrint(alloc, "  {s} [{s}]", .{
                    skill.dir_name,
                    skillSourceName(skill.source),
                });
            defer alloc.free(display);
            try infoTextSafe(alloc, ui, display);
        }
    }

    // What's New section (only on fresh sessions)
    if (!is_resumed) {
        var state = (try config.PzState.load(alloc, home)) orelse config.PzState{};
        defer state.deinit(alloc);

        const new_entries = changelog.entriesSince(state.last_hash);
        if (new_entries.len > 0) {
            const formatted = try changelog.formatRaw(alloc, new_entries, 10);
            defer alloc.free(formatted);
            try ui.tr.styledText("", .{}); // blank line
            try ui.tr.styledText("[What's New]", .{ .fg = t.md_heading });
            // Split and display each line; VCS text may contain non-UTF-8
            var off: usize = 0;
            while (off < formatted.len) {
                const eol = std.mem.indexOfScalarPos(u8, formatted, off, '\n') orelse formatted.len;
                try infoTextSafe(alloc, ui, formatted[off..eol]);
                off = eol + 1;
            }
        }

        // Update state with current git hash
        const new_state = config.PzState{ .last_hash = cli.build_id };
        try new_state.save(alloc, home);
    }

    // Trailing blank lines before prompt (matching pi's spacing)
    try ui.tr.styledText("", .{});
    try ui.tr.styledText("", .{});
}

fn discoverSkills(alloc: std.mem.Allocator, home: ?[]const u8) ![]core_skill.SkillInfo {
    const skills = try core_skill.discoverAndRead(alloc, home);
    std.mem.sort(core_skill.SkillInfo, skills, {}, struct {
        fn lt(_: void, a: core_skill.SkillInfo, b: core_skill.SkillInfo) bool {
            return std.mem.lessThan(u8, a.dir_name, b.dir_name);
        }
    }.lt);
    return skills;
}

fn skillSourceName(source: core_skill.Source) []const u8 {
    return switch (source) {
        .global => "global",
        .project => "project",
    };
}

fn infoTextSafe(alloc: std.mem.Allocator, ui: *tui_harness.Ui, text: []const u8) !void {
    ui.tr.infoText(text) catch |err| switch (err) {
        error.InvalidUtf8 => {
            const safe = try sanitizeUtf8LossyAlloc(alloc, text);
            defer alloc.free(safe);
            try ui.tr.infoText(safe);
        },
        else => return err,
    };
}

const sanitizeUtf8LossyAlloc = utf8.sanitizeLossyAlloc;
const ensureUtf8OrSanitize = utf8.Lossy.init;

fn showCost(_: std.mem.Allocator, ui: *tui_harness.Ui) !void {
    const u = ui.panels.usage;
    const mc = ui.panels.cost_micents;

    var cost_buf: [24]u8 = undefined;
    const cost_val = if (mc > 0)
        tui_panels.fmtCost(&cost_buf, mc) catch "?"
    else
        "0.000";

    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.print("Tokens  in: {d}  out: {d}  total: {d}", .{ u.in_tok, u.out_tok, u.tot_tok });
    if (u.cache_read > 0 or u.cache_write > 0)
        try w.print("\nCache   read: {d}  write: {d}", .{ u.cache_read, u.cache_write });
    try w.print("\nCost    ${s}", .{cost_val});
    try ui.tr.infoText(w.buffered());
}

const clip_paths = if (builtin.target.os.tag == .macos)
    &[_][]const u8{"/usr/bin/pbcopy"}
else
    &[_][]const u8{ "/usr/bin/xclip", "/usr/bin/xsel", "/usr/bin/wl-copy" };

fn copyLastResponse(alloc: std.mem.Allocator, ui: *tui_harness.Ui, pol: *const RuntimePolicy) !void {
    const text = ui.lastResponseText() orelse {
        try ui.tr.infoText("[nothing to copy]");
        return;
    };
    for (clip_paths) |cmd| {
        if (try pipeToCmd(alloc, cmd, text, pol)) {
            try ui.tr.infoText("[copied to clipboard]");
            return;
        }
    }
    try ui.tr.infoText("[copy failed: no clipboard tool found]");
}

fn pipeToCmd(alloc: std.mem.Allocator, cmd: []const u8, text: []const u8, pol: *const RuntimePolicy) !bool {
    _ = alloc;
    const base = std.fs.path.basename(cmd);
    if (!pol.allowsCmdKind(base, null, "clipboard")) return false;
    const argv = [_][]const u8{cmd};
    var child = std.process.spawn(defaultIo(), .{
        .argv = argv[0..],
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    if (child.stdin) |*stdin| {
        try stdin.writeStreamingAll(defaultIo(), text);
        stdin.close(defaultIo());
        child.stdin = null;
    }
    const term = child.wait(defaultIo()) catch return false;
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

const compact_threshold_pct: u32 = 80;

fn shouldRetryOverflow(
    alloc: std.mem.Allocator,
    live: *const LiveTurn,
    model: []const u8,
    retried: bool,
) bool {
    return shouldRetryOverflowState(alloc, live.last_model, live.last_stop, live.last_err, model, retried);
}

fn shouldRetryOverflowState(
    alloc: std.mem.Allocator,
    last_model: ?[]const u8,
    last_stop: ?core.providers.StopReason,
    last_err: ?[]const u8,
    model: []const u8,
    retried: bool,
) bool {
    if (retried) return false;
    if (last_model) |prev_model| {
        if (!std.mem.eql(u8, prev_model, model)) return false;
    } else return false;
    if (last_stop == .max_out) return true;
    if (last_err) |err_text| {
        return core.providers.types.isOverflowError(alloc, err_text);
    }
    return false;
}

const CompactRun = union(enum) {
    compacted,
    stopped: summary_types.SummaryMeta,
};

const AutoCompactOutcome = enum {
    skipped,
    compacted,
    stopped,
    failed,
};

const CompactFn = *const fn (
    ctx: ?*anyopaque,
    alloc: std.mem.Allocator,
    dir: std.Io.Dir,
    sid: []const u8,
    now: i64,
) anyerror!CompactRun;

fn compactNow(
    _: ?*anyopaque,
    alloc: std.mem.Allocator,
    dir: std.Io.Dir,
    sid: []const u8,
    now: i64,
) !CompactRun {
    _ = try core.session.compactSession(alloc, dir, sid, now);
    return .compacted;
}

fn formatCompactStopAlloc(alloc: std.mem.Allocator, meta: summary_types.SummaryMeta) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "[auto-compact stopped: summary input over budget bytes={d}/{d} tokens={d}/{d} kept={d} dropped={d}]",
        .{
            meta.input_bytes,
            meta.max_bytes,
            meta.input_tokens,
            meta.max_input_tokens,
            meta.kept_events,
            meta.dropped_events,
        },
    );
}

fn autoCompact(
    alloc: std.mem.Allocator,
    ui: *tui_harness.Ui,
    out: *std.Io.Writer,
    sid: []const u8,
    session_dir_path: ?[]const u8,
    no_session: bool,
    force: bool,
) !AutoCompactOutcome {
    return autoCompactWith(alloc, ui, out, sid, session_dir_path, no_session, force, null, compactNow);
}

fn autoCompactWith(
    alloc: std.mem.Allocator,
    ui: *tui_harness.Ui,
    out: *std.Io.Writer,
    sid: []const u8,
    session_dir_path: ?[]const u8,
    no_session: bool,
    force: bool,
    compact_ctx: ?*anyopaque,
    compact_fn: CompactFn,
) !AutoCompactOutcome {
    if (no_session or session_dir_path == null) return .skipped;
    if (!force) {
        if (ui.panels.ctx_limit == 0) return .skipped;
        if (!ui.panels.has_usage) return .skipped;
        const pct = ui.panels.cum_tok *| 100 / ui.panels.ctx_limit;
        if (pct < compact_threshold_pct) return .skipped;
    }

    try ui.tr.infoText("[compacting...]");
    try ui.draw(out);

    const dir = try openDirPath(session_dir_path.?, .{});
    defer dir.close(defaultIo());
    const now = core.time.milliTimestamp();
    const res = compact_fn(compact_ctx, alloc, dir, sid, now) catch |err| {
        const detail = try report.inlineMsg(alloc, err);
        defer alloc.free(detail);
        const msg = try std.fmt.allocPrint(alloc, "[auto-compact failed: {s}]", .{detail});
        defer alloc.free(msg);
        try ui.tr.infoText(msg);
        return .failed;
    };
    switch (res) {
        .compacted => {
            ui.panels.noteCompaction();
            try ui.tr.infoText("[session compacted]");
            return .compacted;
        },
        .stopped => |meta| {
            const msg = try formatCompactStopAlloc(alloc, meta);
            defer alloc.free(msg);
            try ui.tr.infoText(msg);
            return .stopped;
        },
    }
}

fn syncInputFooter(ui: *tui_harness.Ui, mode: tui_panels.InputMode, queued_len: usize) void {
    const max_u32 = std.math.maxInt(u32);
    const queued: u32 = if (queued_len > max_u32) max_u32 else @intCast(queued_len);
    ui.panels.setInputStatus(mode, queued);
}

const PendingKind = enum {
    steering,
    follow_up,
};

const PendingTurn = struct {
    kind: PendingKind,
    text: []u8,
};

const PendingQueue = struct {
    steering: std.ArrayListUnmanaged([]u8) = .empty,
    follow_up: std.ArrayListUnmanaged([]u8) = .empty,

    fn deinit(self: *PendingQueue, alloc: std.mem.Allocator) void {
        clearQueueSlice(alloc, &self.steering);
        clearQueueSlice(alloc, &self.follow_up);
        self.steering.deinit(alloc);
        self.follow_up.deinit(alloc);
    }

    fn total(self: *const PendingQueue) usize {
        return self.steering.items.len + self.follow_up.items.len;
    }

    fn pushSteering(self: *PendingQueue, alloc: std.mem.Allocator, text: []const u8) !void {
        try queueMessage(alloc, &self.steering, text);
    }

    fn pushFollowUp(self: *PendingQueue, alloc: std.mem.Allocator, text: []const u8) !void {
        try queueMessage(alloc, &self.follow_up, text);
    }

    fn popNext(self: *PendingQueue) ?PendingTurn {
        if (self.steering.items.len > 0) {
            return .{
                .kind = .steering,
                .text = self.steering.orderedRemove(0),
            };
        }
        if (self.follow_up.items.len > 0) {
            return .{
                .kind = .follow_up,
                .text = self.follow_up.orderedRemove(0),
            };
        }
        return null;
    }

    fn restoreToEditor(self: *PendingQueue, alloc: std.mem.Allocator, ui: *tui_harness.Ui) !usize {
        const queued_ct = self.total();
        if (queued_ct == 0) return 0;

        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(alloc);

        var first = true;
        for (self.steering.items) |msg| {
            if (!first) try out.appendSlice(alloc, "\n\n");
            first = false;
            try out.appendSlice(alloc, msg);
        }
        for (self.follow_up.items) |msg| {
            if (!first) try out.appendSlice(alloc, "\n\n");
            first = false;
            try out.appendSlice(alloc, msg);
        }
        const cur = ui.editorText();
        if (cur.len > 0) {
            if (!first) try out.appendSlice(alloc, "\n\n");
            try out.appendSlice(alloc, cur);
        }

        try ui.ed.setText(out.items);
        try ui.updatePreview();
        clearQueueSlice(alloc, &self.steering);
        clearQueueSlice(alloc, &self.follow_up);
        return queued_ct;
    }
};

fn queueMessage(
    alloc: std.mem.Allocator,
    queue: *std.ArrayListUnmanaged([]u8),
    text: []const u8,
) !void {
    if (text.len == 0) return;
    const queued = try alloc.dupe(u8, text);
    errdefer alloc.free(queued);
    try queue.append(alloc, queued);
}

fn queueFollowup(
    alloc: std.mem.Allocator,
    queue: *std.ArrayListUnmanaged([]u8),
    text: []const u8,
) !void {
    try queueMessage(alloc, queue, text);
}

fn clearQueueSlice(alloc: std.mem.Allocator, queue: *std.ArrayListUnmanaged([]u8)) void {
    for (queue.items) |item| alloc.free(item);
    queue.items.len = 0;
}

fn showLogoutOverlay(alloc: std.mem.Allocator, ui: *tui_harness.Ui, providers: []const core.providers.auth.Provider) !bool {
    if (providers.len == 0) return false;
    const names = try alloc.alloc([]u8, providers.len);
    for (names) |*n| n.len = 0;
    errdefer {
        for (names) |n| if (n.len > 0) alloc.free(n);
        alloc.free(names);
    }
    for (providers, 0..) |p, i| {
        names[i] = try alloc.dupe(u8, core.providers.auth.providerName(p));
    }
    ui.ov = tui_overlay.Overlay.initDyn(names, "Logout", .logout);
    return true;
}

fn showResumeOverlay(alloc: std.mem.Allocator, ui: *tui_harness.Ui, session_dir_path: ?[]const u8) !bool {
    const sdp = session_dir_path orelse return false;
    const rows = listSessionRows(alloc, sdp) catch return false;
    if (rows.len == 0) {
        alloc.free(rows);
        return false;
    }
    ui.ov = tui_overlay.Overlay.initSession(rows, "Resume Session");
    return true;
}

fn shouldQueueSubmit(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return false;
    if (trimmed[0] == '/') return false;
    return parseBashCmd(trimmed) == null;
}

fn showQueueOverlay(
    alloc: std.mem.Allocator,
    ui: *tui_harness.Ui,
    queue: []const []const u8,
) !bool {
    if (queue.len == 0) return false;

    const items = try alloc.alloc([]u8, queue.len);
    errdefer alloc.free(items);
    var filled: usize = 0;
    errdefer {
        for (items[0..filled]) |it| alloc.free(it);
    }

    for (queue, 0..) |msg, idx| {
        items[idx] = try queueItemLabel(alloc, idx, msg);
        filled = idx + 1;
    }

    var ov = tui_overlay.Overlay.initDyn(items, "Queued Messages", .queue);
    ov.hint = "Up/Down select, Enter edit, Esc close";
    ui.ov = ov;
    return true;
}

fn dequeueQueuedIntoEditor(
    alloc: std.mem.Allocator,
    ui: *tui_harness.Ui,
    queue: *std.ArrayListUnmanaged([]u8),
    idx: usize,
) !bool {
    if (idx >= queue.items.len) return false;
    const msg = queue.orderedRemove(idx);
    defer alloc.free(msg);
    try ui.ed.setText(msg);
    try ui.updatePreview();
    return true;
}

fn queueItemLabel(alloc: std.mem.Allocator, idx: usize, msg: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, msg, " \t\r\n");
    const source = if (trimmed.len > 0) trimmed else msg;
    var one_line = source;
    var has_more = false;
    if (std.mem.indexOfScalar(u8, source, '\n')) |nl| {
        one_line = source[0..nl];
        has_more = true;
    }
    const clip = utf8Prefix(one_line, 56);
    if (clip.truncated) has_more = true;
    const suffix = if (has_more) " ..." else "";
    if (clip.text.len == 0) {
        return std.fmt.allocPrint(alloc, "#{d} (empty)", .{idx + 1});
    }
    return std.fmt.allocPrint(alloc, "#{d} {s}{s}", .{ idx + 1, clip.text, suffix });
}

const Utf8Clip = struct {
    text: []const u8,
    truncated: bool,
};

fn utf8Prefix(text: []const u8, max_cp: usize) Utf8Clip {
    if (max_cp == 0 or text.len == 0) return .{ .text = text[0..0], .truncated = text.len > 0 };
    var i: usize = 0;
    var count: usize = 0;
    while (i < text.len and count < max_cp) {
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch break;
        if (i + n > text.len) break;
        _ = std.unicode.utf8Decode(text[i .. i + n]) catch break;
        i += n;
        count += 1;
    }
    return .{
        .text = text[0..i],
        .truncated = i < text.len,
    };
}

const BashCmd = struct {
    cmd: []const u8,
    include: bool, // true = !cmd (include in context), false = !!cmd (exclude)
};

fn noteSessionWriteErr(ui: *tui_harness.Ui, msg: []const u8) !void {
    const note = try std.fmt.allocPrint(ui.alloc, "[session write failed: {s}]", .{msg});
    defer ui.alloc.free(note);
    try ui.tr.infoText(note);
}

fn appendSessionOrNote(
    ui: *tui_harness.Ui,
    sid: []const u8,
    store: *core.session.SessionStore,
    ev: core.session.Event,
) !bool {
    store.append(sid, ev) catch |append_err| {
        try noteSessionWriteErr(ui, @errorName(append_err));
        return false;
    };
    return true;
}

fn parseBashCmd(text: []const u8) ?BashCmd {
    if (text.len < 2 or text[0] != '!') return null;
    if (text[1] == '!') {
        const cmd = std.mem.trim(u8, text[2..], " \t");
        if (cmd.len == 0) return null;
        return .{ .cmd = cmd, .include = false };
    }
    const cmd = std.mem.trim(u8, text[1..], " \t");
    if (cmd.len == 0) return null;
    return .{ .cmd = cmd, .include = true };
}

fn runBashMode(
    alloc: std.mem.Allocator,
    ui: *tui_harness.Ui,
    bcmd: BashCmd,
    sid: []const u8,
    store: *core.session.SessionStore,
    pol: *const RuntimePolicy,
) !void {
    if (!pol.allowsCmdKind("bash", "bash", null)) {
        try ui.tr.append(.{ .tool_call = .{
            .id = "bash",
            .name = "bash",
            .args = bcmd.cmd,
        } });
        try ui.tr.append(.{ .tool_result = .{
            .id = "bash",
            .output = "bash denied: policy",
            .is_err = true,
        } });
        return;
    }
    if (try core.tools.bash.deniesProtectedCmd(alloc, bcmd.cmd)) {
        try ui.tr.append(.{ .tool_call = .{
            .id = "bash",
            .name = "bash",
            .args = bcmd.cmd,
        } });
        try ui.tr.append(.{ .tool_result = .{
            .id = "bash",
            .output = "bash denied: protected path",
            .is_err = true,
        } });

        if (bcmd.include) {
            _ = try appendSessionOrNote(ui, sid, store, .{ .data = .{ .prompt = .{ .text = bcmd.cmd } } });
            _ = try appendSessionOrNote(ui, sid, store, .{ .data = .{ .tool_call = .{
                .id = "bash",
                .name = "bash",
                .args = bcmd.cmd,
            } } });
            _ = try appendSessionOrNote(ui, sid, store, .{ .data = .{ .tool_result = .{
                .id = "bash",
                .output = "bash denied: protected path",
                .is_err = true,
            } } });
        }
        return;
    }

    const result = std.process.run(alloc, defaultIo(), .{
        .argv = &.{ "/bin/bash", "-lc", bcmd.cmd },
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(256 * 1024),
    }) catch |err| {
        const detail = try report.inlineMsg(alloc, err);
        defer alloc.free(detail);
        const msg = try std.fmt.allocPrint(alloc, "bash error: {s}", .{detail});
        defer alloc.free(msg);
        try ui.tr.append(.{ .err = msg });
        return;
    };
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    const output = if (result.stdout.len > 0) result.stdout else result.stderr;
    const is_err = switch (result.term) {
        .exited => |code| code != 0,
        else => true,
    };

    // Show in transcript
    try ui.tr.append(.{ .tool_call = .{
        .id = "bash",
        .name = "bash",
        .args = bcmd.cmd,
    } });
    try ui.tr.append(.{ .tool_result = .{
        .id = "bash",
        .output = if (output.len > 0) output else "(no output)",
        .is_err = is_err,
    } });

    // Save to session if include mode
    if (bcmd.include) {
        _ = try appendSessionOrNote(ui, sid, store, .{ .data = .{ .prompt = .{ .text = bcmd.cmd } } });
        _ = try appendSessionOrNote(ui, sid, store, .{ .data = .{ .tool_call = .{
            .id = "bash",
            .name = "bash",
            .args = bcmd.cmd,
        } } });
        _ = try appendSessionOrNote(ui, sid, store, .{ .data = .{ .tool_result = .{
            .id = "bash",
            .output = if (output.len > 0) output else "(no output)",
            .is_err = is_err,
        } } });
    }
}

fn openExtEditor(alloc: std.mem.Allocator, current: []const u8) !?[]u8 {
    const raw_ed = getenv("EDITOR") orelse getenv("VISUAL") orelse "/usr/bin/vi";

    // Reject null bytes — could truncate the path at the C boundary.
    if (std.mem.indexOfScalar(u8, raw_ed, 0) != null) return error.EditorNotFound;

    // Reject relative paths — require absolute path or bare command name.
    // Relative paths with separators (./foo, ../bar) are rejected to
    // prevent path-traversal attacks via EDITOR.
    const ed = if (!std.fs.path.isAbsolute(raw_ed)) blk: {
        // Reject any relative path containing a separator
        if (std.mem.indexOfScalar(u8, raw_ed, '/') != null) return error.EditorNotFound;
        // Resolve bare command name against known safe dirs
        const safe_dirs = [_][]const u8{ "/usr/bin", "/usr/local/bin", "/opt/homebrew/bin" };
        var found: ?[]const u8 = null;
        for (safe_dirs) |dir| {
            const full = try std.fs.path.join(alloc, &.{ dir, raw_ed });
            std.Io.Dir.accessAbsolute(defaultIo(), full, .{}) catch {
                alloc.free(full);
                continue;
            };
            found = full;
            break;
        }
        break :blk found orelse return error.EditorNotFound;
    } else raw_ed;

    // Write current text to unique temp file
    var tmp_buf: [64]u8 = undefined;
    const ts: u64 = @truncate(@as(u128, @bitCast(core.time.nanoTimestamp())));
    const tmp = try std.fmt.bufPrint(&tmp_buf, "/tmp/pz-edit-{d}.txt", .{ts});
    defer std.Io.Dir.deleteFileAbsolute(defaultIo(), tmp) catch {}; // cleanup: propagation impossible
    {
        const f = try std.Io.Dir.createFileAbsolute(defaultIo(), tmp, .{});
        defer f.close(defaultIo());
        try f.writeStreamingAll(defaultIo(), current);
    }

    const argv = [_][]const u8{ ed, tmp };
    var child = try std.process.spawn(defaultIo(), .{
        .argv = argv[0..],
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    _ = try child.wait(defaultIo());

    // Read back
    const f = try std.Io.Dir.openFileAbsolute(defaultIo(), tmp, .{});
    defer f.close(defaultIo());
    var read_buf: [8192]u8 = undefined;
    var reader = f.readerStreaming(defaultIo(), &read_buf);
    const content = try reader.interface.allocRemaining(alloc, .limited(1024 * 1024));
    // Trim trailing newline
    var len = content.len;
    while (len > 0 and (content[len - 1] == '\n' or content[len - 1] == '\r')) len -= 1;
    if (len == 0) {
        alloc.free(content);
        return null;
    }
    if (len < content.len) {
        const trimmed = try alloc.dupe(u8, content[0..len]);
        alloc.free(content);
        return trimmed;
    }
    return content;
}

fn pasteImage(alloc: std.mem.Allocator, ui: *tui_harness.Ui, tmp_dir: []const u8, pol: *const RuntimePolicy) !void {
    if (!pol.allowsCmdKind("osascript", null, "clipboard")) {
        try ui.tr.infoText("[paste denied: policy]");
        return;
    }
    // macOS: check clipboard for image via osascript
    const argv = [_][]const u8{
        "/usr/bin/osascript", "-e",
        "try\nset theType to (clipboard info for «class PNGf»)\nreturn \"image\"\non error\nreturn \"none\"\nend try",
    };
    const result = std.process.run(alloc, defaultIo(), .{
        .argv = argv[0..],
        .stdout_limit = .limited(256),
        .stderr_limit = .limited(256),
    }) catch {
        try ui.tr.infoText("[paste: clipboard check failed]");
        return;
    };
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (!std.mem.eql(u8, trimmed, "image")) {
        try pasteText(alloc, ui, pol);
        return;
    }

    // Save clipboard image to unique temp file
    var tmp_buf: [128]u8 = undefined;
    const ts: u64 = @truncate(@as(u128, @bitCast(core.time.nanoTimestamp())));
    const tmp_path = try std.fmt.bufPrint(&tmp_buf, "{s}/pz-paste-{d}.png", .{ tmp_dir, ts });
    defer std.Io.Dir.deleteFileAbsolute(defaultIo(), tmp_path) catch {}; // cleanup: propagation impossible

    // Reject paths with chars that could break out of AppleScript string interpolation.
    if (std.mem.indexOfAny(u8, tmp_path, "\"\\") != null) {
        try ui.tr.infoText("[paste: unsafe temp path]");
        return;
    }

    const script = try std.fmt.allocPrint(alloc, "set imgData to the clipboard as «class PNGf»\nset fp to open for access POSIX file \"{s}\" with write permission\nwrite imgData to fp\nclose access fp", .{tmp_path});
    defer alloc.free(script);

    const save_argv = [_][]const u8{ "/usr/bin/osascript", "-e", script };
    const save_result = std.process.run(alloc, defaultIo(), .{
        .argv = save_argv[0..],
        .stdout_limit = .limited(256),
        .stderr_limit = .limited(256),
    }) catch {
        try ui.tr.infoText("[paste: save failed]");
        return;
    };
    defer alloc.free(save_result.stdout);
    defer alloc.free(save_result.stderr);

    ui.tr.imageBlock(tmp_path) catch |err| {
        const msg = try std.fmt.allocPrint(alloc, "[pasted image: {s}]", .{tmp_path});
        defer alloc.free(msg);
        ui.tr.infoText(msg) catch return err;
    };
}

fn pasteText(alloc: std.mem.Allocator, ui: *tui_harness.Ui, pol: *const RuntimePolicy) !void {
    if (!pol.allowsCmdKind("pbpaste", null, "clipboard")) {
        try ui.tr.infoText("[paste denied: policy]");
        return;
    }
    const argv = [_][]const u8{"/usr/bin/pbpaste"};
    const result = std.process.run(alloc, defaultIo(), .{
        .argv = argv[0..],
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(256 * 1024),
    }) catch {
        try ui.tr.infoText("[paste failed]");
        return;
    };
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    if (result.stdout.len > 0) {
        ui.ed.insertSlice(result.stdout) catch |err| {
            ui.tr.infoText("[paste: invalid UTF-8]") catch return err;
        };
    }
}

const TurnCtx = struct {
    alloc: std.mem.Allocator,
    provider: *core.providers.Provider,
    store: *core.session.SessionStore,
    pol: *const RuntimePolicy,
    tools_rt: *core.tools.builtin.Runtime,
    mode: *core.loop.ModeSink,
    max_turns: u16 = 0,
    cancel: ?*core.loop.CancelSrc = null,
    abort_slot: ?*core.providers.AbortSlot = null,
    cmd_cache: ?*core.loop.CmdCache = null,
    approval_bind: core.policy.ApprovalBind = .{ .version = core.policy.ver_current },
    approval_loc: ?core.loop.CmdCache.Loc = null,
    approver: ?*core.loop.Approver = null,
    audit_hooks: AuditHooks = .{},
    activity_sink: ?*activity.ActivitySink = null,
    skip_prompt_guard: bool = false,

    const TurnOpts = struct {
        sid: []const u8,
        prompt: []const u8,
        model: []const u8,
        provider_label: []const u8 = "",
        provider_opts: core.providers.Opts = .{},
        system_prompt: ?[]const u8 = null,
    };

    fn run(self: *const TurnCtx, opts: TurnOpts) !void {
        if (self.activity_sink) |sink| sink.emit(.{ .prompt = .{
            .session_id = opts.sid,
            .prompt_chars = opts.prompt.len,
        } });

        const prompt_hint = if (needsAskHint(opts.prompt))
            try std.fmt.allocPrint(
                self.alloc,
                "{s}\n\nUse the `ask` tool for clarifying questions (1-3 concise questions with options) before final planning output.",
                .{opts.prompt},
            )
        else
            null;
        defer if (prompt_hint) |p| self.alloc.free(p);

        var reg: PolicyToolRegistry = undefined;
        var tool_audit_seq: u64 = 1;
        const tool_audit = PolicyToolAudit{
            .alloc = self.alloc,
            .hooks = self.audit_hooks,
            .sid = opts.sid,
            .seq = &tool_audit_seq,
        };
        reg.init(self.pol, self.tools_rt.registry(), tool_audit);
        var tool_auth_impl = PolicyToolAuth{
            .alloc = self.alloc,
            .pol = self.pol,
            .sid = opts.sid,
            .audit_emitter = self.audit_hooks.audit_emitter,
            .now_ms = self.audit_hooks.now_ms,
            .seq = &tool_audit_seq,
        };

        var activity_mode: ActivityModeSink = undefined;
        const mode = if (self.activity_sink) |sink| blk: {
            activity_mode = .{
                .inner = self.mode,
                .activity_sink = sink,
                .sid = opts.sid,
            };
            break :blk &activity_mode.mode_sink;
        } else self.mode;

        _ = try core.loop.run(.{
            .alloc = self.alloc,
            .sid = opts.sid,
            .prompt = prompt_hint orelse opts.prompt,
            .model = opts.model,
            .provider_label = opts.provider_label,
            .provider = self.provider,
            .store = self.store,
            .reg = reg.registry(),
            .tool_auth = &tool_auth_impl.tool_auth,
            .mode = mode,
            .system_prompt = opts.system_prompt,
            .provider_opts = opts.provider_opts,
            .max_turns = self.max_turns,
            .cancel = self.cancel,
            .abort_slot = self.abort_slot,
            .cmd_cache = self.cmd_cache,
            .approval = if (self.approval_loc) |loc| .{
                .loc = loc,
                .policy = self.approval_bind,
            } else null,
            .approver = self.approver,
            .skip_prompt_guard = self.skip_prompt_guard,
        });
    }
};

fn needsAskHint(prompt: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(prompt, "ask me questions") != null or
        std.ascii.indexOfIgnoreCase(prompt, "ask questions") != null;
}

test "buildAskRows includes type-something-else and next navigation" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};

    const opts = [_]core.tools.Call.AskArgs.Option{
        .{ .label = "A" },
        .{ .label = "B", .description = "desc" },
    };
    const q: core.tools.Call.AskArgs.Question = .{
        .id = "scope",
        .question = "Pick scope",
        .options = opts[0..],
        .allow_other = true,
    };
    var rows = try buildAskRows(std.testing.allocator, q, .{}, true, false);
    defer rows.deinit(std.testing.allocator);

    const Snap = struct {
        row0: []const u8,
        row1: []const u8,
        row2: []const u8,
        row3: []const u8,
    };
    const snap = Snap{
        .row0 = rows.items[0],
        .row1 = rows.items[1],
        .row2 = rows.items[2],
        .row3 = rows.items[3],
    };
    try oh.snap(@src(),
        \\app.runtime.test.buildAskRows includes type-something-else and next navigation.Snap
        \\  .row0: []const u8
        \\    "[ ] A"
        \\  .row1: []const u8
        \\    "[ ] B - desc"
        \\  .row2: []const u8
        \\    "[ ] Type something else"
        \\  .row3: []const u8
        \\    "Next question"
    ).expectEqual(snap);
}

test "buildAskRows renders custom answer selection and submit controls" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};

    const opts = [_]core.tools.Call.AskArgs.Option{
        .{ .label = "A" },
        .{ .label = "B" },
    };
    const q: core.tools.Call.AskArgs.Question = .{
        .id = "scope",
        .question = "Pick scope",
        .options = opts[0..],
        .allow_other = true,
    };
    const custom = try std.testing.allocator.dupe(u8, "My custom answer");
    defer std.testing.allocator.free(custom);

    var rows = try buildAskRows(std.testing.allocator, q, .{
        .answer = custom,
        .index = 2,
    }, false, true);
    defer rows.deinit(std.testing.allocator);

    const Snap = struct {
        row0: []const u8,
        row1: []const u8,
        row2: []const u8,
        row3: []const u8,
        row4: []const u8,
    };
    const snap = Snap{
        .row0 = rows.items[0],
        .row1 = rows.items[1],
        .row2 = rows.items[2],
        .row3 = rows.items[3],
        .row4 = rows.items[4],
    };
    try oh.snap(@src(),
        \\app.runtime.test.buildAskRows renders custom answer selection and submit controls.Snap
        \\  .row0: []const u8
        \\    "[ ] A"
        \\  .row1: []const u8
        \\    "[ ] B"
        \\  .row2: []const u8
        \\    "[x] Type something else: My custom answer"
        \\  .row3: []const u8
        \\    "Previous question"
        \\  .row4: []const u8
        \\    "Submit answers"
    ).expectEqual(snap);
}

test "firstUnanswered returns first missing answer index" {
    const a0 = try std.testing.allocator.dupe(u8, "one");
    defer std.testing.allocator.free(a0);
    const a2 = try std.testing.allocator.dupe(u8, "three");
    defer std.testing.allocator.free(a2);

    const stored = [_]AskUiCtx.StoredAnswer{
        .{ .answer = a0, .index = 0 },
        .{},
        .{ .answer = a2, .index = 2 },
    };
    try std.testing.expectEqual(@as(?usize, 1), firstUnanswered(stored[0..]));
}

test "collectAskAnswers builds expected ask JSON payload" {
    const opts = [_]core.tools.Call.AskArgs.Option{
        .{ .label = "A" },
        .{ .label = "B" },
    };
    const qs = [_]core.tools.Call.AskArgs.Question{
        .{
            .id = "scope",
            .question = "Pick scope",
            .options = opts[0..],
            .allow_other = true,
        },
        .{
            .id = "detail",
            .question = "Add detail",
            .options = opts[0..],
            .allow_other = true,
        },
    };

    var stored = [_]AskUiCtx.StoredAnswer{
        .{},
        .{},
    };
    stored[0].answer = try std.testing.allocator.dupe(u8, "A");
    stored[0].index = 0;
    stored[1].answer = try std.testing.allocator.dupe(u8, "custom");
    stored[1].index = 2;
    defer {
        if (stored[0].answer) |a| std.testing.allocator.free(a);
        if (stored[1].answer) |a| std.testing.allocator.free(a);
    }

    const out_answers = try collectAskAnswers(std.testing.allocator, qs[0..], stored[0..]);
    defer std.testing.allocator.free(out_answers);
    const payload = try buildAskResult(std.testing.allocator, false, out_answers);
    defer std.testing.allocator.free(payload);

    try std.testing.expectEqualStrings(
        "{\"cancelled\":false,\"answers\":[{\"id\":\"scope\",\"answer\":\"A\",\"index\":0},{\"id\":\"detail\",\"answer\":\"custom\",\"index\":2}]}",
        payload,
    );
}

fn waitForAskTxn(live: *LiveTurn) !*LiveTurn.AskTxn {
    var ask_txn: ?*LiveTurn.AskTxn = null;
    var spins: usize = 0;
    while (ask_txn == null and spins < 1000) : (spins += 1) {
        ask_txn = live.takeAsk();
        if (ask_txn == null) try std.Io.sleep(defaultIo(), .fromNanoseconds(std.time.ns_per_ms), .awake);
    }
    return ask_txn orelse error.TestUnexpectedResult;
}

test "live turn ask bridge waits for main-thread answer" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};
    var live = try LiveTurn.init(std.testing.allocator);
    defer live.deinit();

    const opts = [_]core.tools.Call.AskArgs.Option{
        .{ .label = "A" },
    };
    const qs = [_]core.tools.Call.AskArgs.Question{
        .{
            .id = "scope",
            .question = "Pick scope",
            .options = opts[0..],
            .allow_other = true,
        },
    };

    const Ctx = struct {
        live: *LiveTurn,
        out: ?[]u8 = null,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            self.out = self.live.ask(.{ .questions = qs[0..] }) catch |err| {
                self.err = err;
                return;
            };
        }
    };

    var ctx = Ctx{ .live = &live };
    const thr = try std.Thread.spawn(.{}, Ctx.run, .{&ctx});
    const tx = try waitForAskTxn(&live);
    const q = tx.args.questions[0];
    const q_id = try std.testing.allocator.dupe(u8, q.id);
    defer std.testing.allocator.free(q_id);
    const q_text = try std.testing.allocator.dupe(u8, q.question);
    defer std.testing.allocator.free(q_text);
    const q_allow_other = q.allow_other;
    const q_opt = try std.testing.allocator.dupe(u8, q.options[0].label);
    defer std.testing.allocator.free(q_opt);

    const out = try std.testing.allocator.dupe(
        u8,
        "{\"cancelled\":false,\"answers\":[{\"id\":\"scope\",\"answer\":\"A\",\"index\":0}]}",
    );
    live.finishAsk(tx, out);
    thr.join();

    if (ctx.err) |err| return err;
    defer std.testing.allocator.free(ctx.out.?);
    const snap = try std.fmt.allocPrint(
        std.testing.allocator,
        "q0 id={s} text={s} allow_other={} opt0={s}\nout={s}",
        .{ q_id, q_text, q_allow_other, q_opt, ctx.out.? },
    );
    defer std.testing.allocator.free(snap);
    try oh.snap(@src(),
        \\[]u8
        \\  "q0 id=scope text=Pick scope allow_other=true opt0=A
        \\out={"cancelled":false,"answers":[{"id":"scope","answer":"A","index":0}]}"
    ).expectEqual(snap);
}

test "live turn ask handoff keeps editor input isolated and cannot deadlock" {
    var live = try LiveTurn.init(std.testing.allocator);
    defer live.deinit();

    const opts = [_]core.tools.Call.AskArgs.Option{
        .{ .label = "A" },
    };
    const qs = [_]core.tools.Call.AskArgs.Question{
        .{
            .id = "scope",
            .question = "Pick scope",
            .options = opts[0..],
            .allow_other = false,
        },
    };

    const Ctx = struct {
        live: *LiveTurn,
        out: ?[]u8 = null,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            self.out = self.live.ask(.{ .questions = qs[0..] }) catch |err| {
                self.err = err;
                return;
            };
        }
    };

    var ui = try tui_harness.Ui.init(std.testing.allocator, 80, 12, "m", "p");
    defer ui.deinit();
    try ui.ed.setText("draft");

    var out_buf: [16384]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);
    const pipe = try makePipe(false);
    defer closeFd(pipe[0]);
    defer closeFd(pipe[1]);
    var watcher = try InputWatcher.init(pipe[0]);
    defer watcher.deinit();
    var ask_ui_ctx = AskUiCtx{
        .alloc = std.testing.allocator,
        .ui = &ui,
        .out = &out_fbs,
        .pause = &watcher.pause_ctl,
    };
    try fdWriteAll(pipe[1], "\r\x1b[B\r");
    var reader = tui_input.Reader.init(watcher.fd);

    var ctx = Ctx{ .live = &live };
    const thr = try std.Thread.spawn(.{}, Ctx.run, .{&ctx});
    const tx = try waitForAskTxn(&live);

    live.finishAsk(tx, ask_ui_ctx.runOnMain(&reader, tx.args.view()));
    thr.join();

    if (ctx.err) |err| return err;
    defer std.testing.allocator.free(ctx.out.?);
    try std.testing.expectEqualStrings(
        "{\"cancelled\":false,\"answers\":[{\"id\":\"scope\",\"answer\":\"A\",\"index\":0}]}",
        ctx.out.?,
    );
    try std.testing.expectEqualStrings("draft", ui.ed.text());
    try std.testing.expect(!watcher.isPaused());
    try std.testing.expect(ui.ov == null);
}

test "live turn ask handoff frees custom other answers cleanly" {
    var live = try LiveTurn.init(std.testing.allocator);
    defer live.deinit();

    const opts = [_]core.tools.Call.AskArgs.Option{
        .{ .label = "A" },
    };
    const qs = [_]core.tools.Call.AskArgs.Question{
        .{
            .id = "scope",
            .question = "Pick scope",
            .options = opts[0..],
            .allow_other = true,
        },
    };

    const Ctx = struct {
        live: *LiveTurn,
        out: ?[]u8 = null,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            self.out = self.live.ask(.{ .questions = qs[0..] }) catch |err| {
                self.err = err;
                return;
            };
        }
    };

    var ui = try tui_harness.Ui.init(std.testing.allocator, 80, 12, "m", "p");
    defer ui.deinit();
    try ui.ed.setText("draft");

    var out_buf: [16384]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);
    const pipe = try makePipe(false);
    defer closeFd(pipe[0]);
    defer closeFd(pipe[1]);
    var watcher = try InputWatcher.init(pipe[0]);
    defer watcher.deinit();
    var ask_ui_ctx = AskUiCtx{
        .alloc = std.testing.allocator,
        .ui = &ui,
        .out = &out_fbs,
        .pause = &watcher.pause_ctl,
    };
    try fdWriteAll(pipe[1], "\x1b[B\rZ\r\x1b[B\r");
    var reader = tui_input.Reader.init(watcher.fd);

    var ctx = Ctx{ .live = &live };
    const thr = try std.Thread.spawn(.{}, Ctx.run, .{&ctx});
    const tx = try waitForAskTxn(&live);

    live.finishAsk(tx, ask_ui_ctx.runOnMain(&reader, tx.args.view()));
    thr.join();

    if (ctx.err) |err| return err;
    defer std.testing.allocator.free(ctx.out.?);
    try std.testing.expectEqualStrings(
        "{\"cancelled\":false,\"answers\":[{\"id\":\"scope\",\"answer\":\"Z\",\"index\":1}]}",
        ctx.out.?,
    );
    try std.testing.expectEqualStrings("draft", ui.ed.text());
    try std.testing.expect(!watcher.isPaused());
    try std.testing.expect(ui.ov == null);
}

test "ask ui cancel frees temporary state and overlay" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};
    var live = try LiveTurn.init(std.testing.allocator);
    defer live.deinit();

    const opts = [_]core.tools.Call.AskArgs.Option{
        .{ .label = "A" },
        .{ .label = "B" },
    };
    const qs = [_]core.tools.Call.AskArgs.Question{
        .{
            .id = "scope",
            .question = "Pick scope",
            .options = opts[0..],
            .allow_other = true,
        },
    };

    const Ctx = struct {
        live: *LiveTurn,
        out: ?[]u8 = null,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            self.out = self.live.ask(.{ .questions = qs[0..] }) catch |err| {
                self.err = err;
                return;
            };
        }
    };

    var ui = try tui_harness.Ui.init(std.testing.allocator, 80, 12, "m", "p");
    defer ui.deinit();
    try ui.ed.setText("draft");

    var out_buf: [16384]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);
    const pipe = try makePipe(false);
    defer closeFd(pipe[0]);
    defer closeFd(pipe[1]);
    var watcher = try InputWatcher.init(pipe[0]);
    defer watcher.deinit();
    var ask_ui_ctx = AskUiCtx{
        .alloc = std.testing.allocator,
        .ui = &ui,
        .out = &out_fbs,
        .pause = &watcher.pause_ctl,
    };
    try fdWriteAll(pipe[1], "\x03");
    var reader = tui_input.Reader.init(watcher.fd);

    var ctx = Ctx{ .live = &live };
    const thr = try std.Thread.spawn(.{}, Ctx.run, .{&ctx});
    const tx = try waitForAskTxn(&live);

    live.finishAsk(tx, ask_ui_ctx.runOnMain(&reader, tx.args.view()));
    thr.join();

    if (ctx.err) |err| return err;
    defer std.testing.allocator.free(ctx.out.?);

    try oh.snap(@src(),
        \\[]u8
        \\  "{"cancelled":true,"answers":[]}"
    ).expectEqual(ctx.out.?);
    try std.testing.expectEqualStrings("draft", ui.ed.text());
    try std.testing.expect(!watcher.isPaused());
    try std.testing.expect(ui.ov == null);
}

test "input watcher join wakes promptly while paused" {
    const in_pipe = try makePipe(false);
    defer closeFd(in_pipe[0]);
    defer closeFd(in_pipe[1]);

    var watcher = try InputWatcher.init(in_pipe[0]);
    defer watcher.deinit();
    try std.testing.expect(watcher.start());
    watcher.setPaused(true);

    const done_pipe = try makePipe(true);
    defer closeFd(done_pipe[0]);
    defer closeFd(done_pipe[1]);

    const Ctx = struct {
        watcher: *InputWatcher,
        fd: std.posix.fd_t,

        fn run(self: *@This()) void {
            self.watcher.join(null);
            fdWriteAll(self.fd, "\x01") catch {}; // cleanup: propagation impossible
        }
    };
    var ctx = Ctx{ .watcher = &watcher, .fd = done_pipe[1] };
    const thr = try std.Thread.spawn(.{}, Ctx.run, .{&ctx});
    defer thr.join();

    var fds = [1]std.posix.pollfd{.{
        .fd = done_pipe[0],
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = try std.posix.poll(&fds, 20);
    try std.testing.expectEqual(@as(usize, 1), ready);
}

test "parseBashCmd single bang" {
    const r = parseBashCmd("!ls -la").?;
    try std.testing.expectEqualStrings("ls -la", r.cmd);
    try std.testing.expect(r.include);
}

test "parseBashCmd double bang excludes" {
    const r = parseBashCmd("!!echo hi").?;
    try std.testing.expectEqualStrings("echo hi", r.cmd);
    try std.testing.expect(!r.include);
}

test "parseBashCmd empty cmd returns null" {
    try std.testing.expect(parseBashCmd("!") == null);
    try std.testing.expect(parseBashCmd("! ") == null);
    try std.testing.expect(parseBashCmd("!!") == null);
    try std.testing.expect(parseBashCmd("!! ") == null);
}

test "parseBashCmd no bang returns null" {
    try std.testing.expect(parseBashCmd("hello") == null);
    try std.testing.expect(parseBashCmd("/quit") == null);
}

test "shouldQueueSubmit excludes commands and includes prompts" {
    try std.testing.expect(!shouldQueueSubmit(""));
    try std.testing.expect(!shouldQueueSubmit("   \t\n"));
    try std.testing.expect(!shouldQueueSubmit("/help"));
    try std.testing.expect(!shouldQueueSubmit(" /help"));
    try std.testing.expect(!shouldQueueSubmit("!ls -la"));
    try std.testing.expect(!shouldQueueSubmit("!!echo hi"));
    try std.testing.expect(shouldQueueSubmit("explain this bug"));
}

test "pending queue pops steering before follow-up" {
    var pending = PendingQueue{};
    defer pending.deinit(std.testing.allocator);

    try pending.pushFollowUp(std.testing.allocator, "follow-1");
    try pending.pushSteering(std.testing.allocator, "steer-1");
    try pending.pushFollowUp(std.testing.allocator, "follow-2");

    const one = pending.popNext() orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(one.text);
    try std.testing.expect(one.kind == .steering);
    try std.testing.expectEqualStrings("steer-1", one.text);

    const two = pending.popNext() orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(two.text);
    try std.testing.expect(two.kind == .follow_up);
    try std.testing.expectEqualStrings("follow-1", two.text);

    const three = pending.popNext() orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(three.text);
    try std.testing.expect(three.kind == .follow_up);
    try std.testing.expectEqualStrings("follow-2", three.text);

    try std.testing.expect(pending.popNext() == null);
}

test "pending queue restore merges steering follow-up and editor text" {
    var ui = try tui_harness.Ui.init(std.testing.allocator, 80, 12, "m", "p");
    defer ui.deinit();

    var pending = PendingQueue{};
    defer pending.deinit(std.testing.allocator);

    try pending.pushSteering(std.testing.allocator, "steer one");
    try pending.pushSteering(std.testing.allocator, "steer two");
    try pending.pushFollowUp(std.testing.allocator, "follow one");
    try ui.ed.setText("existing draft");

    const restored = try pending.restoreToEditor(std.testing.allocator, &ui);
    try std.testing.expectEqual(@as(usize, 3), restored);
    try std.testing.expectEqualStrings("steer one\n\nsteer two\n\nfollow one\n\nexisting draft", ui.ed.text());
    try std.testing.expectEqual(@as(usize, 0), pending.total());
}

test "queueItemLabel snapshots preview formatting" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};

    const one = try queueItemLabel(std.testing.allocator, 0, "first line\nsecond line");
    defer std.testing.allocator.free(one);

    const two = try queueItemLabel(std.testing.allocator, 1, "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz");
    defer std.testing.allocator.free(two);

    const three = try queueItemLabel(std.testing.allocator, 2, "   ");
    defer std.testing.allocator.free(three);

    const Snap = struct {
        one: []const u8,
        two: []const u8,
        three: []const u8,
    };
    try oh.snap(@src(),
        \\app.runtime.test.queueItemLabel snapshots preview formatting.Snap
        \\  .one: []const u8
        \\    "#1 first line ..."
        \\  .two: []const u8
        \\    "#2 abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcd ..."
        \\  .three: []const u8
        \\    "#3    "
    ).expectEqual(Snap{
        .one = one,
        .two = two,
        .three = three,
    });
}

test "showQueueOverlay and dequeueQueuedIntoEditor edit selected message" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};
    var ui = try tui_harness.Ui.init(std.testing.allocator, 80, 12, "m", "p");
    defer ui.deinit();

    var queue: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (queue.items) |q| std.testing.allocator.free(q);
        queue.deinit(std.testing.allocator);
    }
    try queueFollowup(std.testing.allocator, &queue, "one");
    try queueFollowup(std.testing.allocator, &queue, "two");
    try queueFollowup(std.testing.allocator, &queue, "three");

    try std.testing.expect(try showQueueOverlay(std.testing.allocator, &ui, queue.items));
    try std.testing.expect(ui.ov != null);
    try std.testing.expect(ui.ov.?.kind == .queue);
    try std.testing.expect(ui.ov.?.dyn_items != null);
    try std.testing.expectEqual(@as(usize, 3), ui.ov.?.dyn_items.?.len);

    ui.ov.?.sel = 1;
    try std.testing.expect(try dequeueQueuedIntoEditor(std.testing.allocator, &ui, &queue, ui.ov.?.sel));
    const Snap = struct {
        ov_len: usize,
        editor: []const u8,
        q0: []const u8,
        q1: []const u8,
    };
    try oh.snap(@src(),
        \\app.runtime.test.showQueueOverlay and dequeueQueuedIntoEditor edit selected message.Snap
        \\  .ov_len: usize = 3
        \\  .editor: []const u8
        \\    "two"
        \\  .q0: []const u8
        \\    "one"
        \\  .q1: []const u8
        \\    "three"
    ).expectEqual(Snap{
        .ov_len = ui.ov.?.dyn_items.?.len,
        .editor = ui.ed.text(),
        .q0 = queue.items[0],
        .q1 = queue.items[1],
    });

    ui.ov.?.deinit(std.testing.allocator);
    ui.ov = null;
}

fn writeSessionEventsFile(tmp: std.testing.TmpDir, sub_path: []const u8, events: []const core.session.Event) !void {
    const file = try tmp.dir.createFile(std.testing.io, sub_path, .{});
    defer file.close(std.testing.io);
    for (events) |ev| {
        const raw = try core.session.encodeEventAlloc(std.testing.allocator, ev);
        defer std.testing.allocator.free(raw);
        try file.writeStreamingAll(std.testing.io, raw);
        try file.writeStreamingAll(std.testing.io, "\n");
    }
}

fn frameRowBoxAlloc(alloc: std.mem.Allocator, frm: *const tui_frame.Frame, y: usize) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);

    try out.append(alloc, '|');
    for (0..frm.w) |x| {
        const cell = try frm.cell(x, y);
        if (cell.cp == tui_frame.Frame.wide_pad) continue;
        if (cell.cp <= 0x7f) {
            try out.append(alloc, @intCast(cell.cp));
            continue;
        }
        var buf: [4]u8 = undefined;
        const n = try std.unicode.utf8Encode(cell.cp, &buf);
        try out.appendSlice(alloc, buf[0..n]);
    }
    try out.append(alloc, '|');
    return out.toOwnedSlice(alloc);
}

test "showResumeOverlay lists sessions and supports arrow navigation" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "sess");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "sess/200.jsonl",
        .data = "",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "sess/100.jsonl",
        .data = "",
    });

    const sess_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "sess");
    defer std.testing.allocator.free(sess_abs);

    var ui = try tui_harness.Ui.init(std.testing.allocator, 80, 12, "m", "p");
    defer ui.deinit();

    try std.testing.expect(try showResumeOverlay(std.testing.allocator, &ui, sess_abs));
    try std.testing.expect(ui.ov != null);
    try std.testing.expect(ui.ov.?.kind == .session);
    try std.testing.expect(ui.ov.?.session_rows != null);
    const rows = ui.ov.?.session_rows.?;
    const RowSnap = struct {
        sid: []const u8,
        title: []const u8,
        time: []const u8,
        tokens: []const u8,
    };
    const Snap = struct {
        title: []const u8,
        selected: []const u8,
        rows: [2]RowSnap,
    };
    try oh.snap(@src(),
        \\app.runtime.test.showResumeOverlay lists sessions and supports arrow navigation.Snap
        \\  .title: []const u8
        \\    "Resume Session"
        \\  .selected: []const u8
        \\    "100"
        \\  .rows: [2]app.runtime.test.showResumeOverlay lists sessions and supports arrow navigation.RowSnap
        \\    [0]: app.runtime.test.showResumeOverlay lists sessions and supports arrow navigation.RowSnap
        \\      .sid: []const u8
        \\        "100"
        \\      .title: []const u8
        \\        "100"
        \\      .time: []const u8
        \\        "now"
        \\      .tokens: []const u8
        \\        "0 tok"
        \\    [1]: app.runtime.test.showResumeOverlay lists sessions and supports arrow navigation.RowSnap
        \\      .sid: []const u8
        \\        "200"
        \\      .title: []const u8
        \\        "200"
        \\      .time: []const u8
        \\        "now"
        \\      .tokens: []const u8
        \\        "0 tok"
    ).expectEqual(Snap{
        .title = ui.ov.?.title,
        .selected = ui.ov.?.selected().?,
        .rows = .{
            .{ .sid = rows[0].sid, .title = rows[0].title, .time = rows[0].time, .tokens = rows[0].tokens },
            .{ .sid = rows[1].sid, .title = rows[1].title, .time = rows[1].time, .tokens = rows[1].tokens },
        },
    });

    ui.ov.?.down();
    try std.testing.expectEqualStrings("200", ui.ov.?.selected().?);
    ui.ov.?.down();
    try std.testing.expectEqualStrings("100", ui.ov.?.selected().?);
    ui.ov.?.up();
    try std.testing.expectEqualStrings("200", ui.ov.?.selected().?);

    ui.ov.?.deinit(std.testing.allocator);
    ui.ov = null;
}

test "showResumeOverlay fixed-width snapshot aligns age and token columns" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "sess");

    const now = core.time.milliTimestamp();
    const long_events = [_]core.session.Event{
        .{
            .at_ms = now - (2 * 60 * 60 * std.time.ms_per_s),
            .data = .{ .prompt = .{ .text = "A very long session title that should ellipsize before the right-aligned columns" } },
        },
        .{
            .at_ms = now - (2 * 60 * 60 * std.time.ms_per_s),
            .data = .{ .usage = .{ .tot_tok = 1345 } },
        },
    };
    try writeSessionEventsFile(tmp, "sess/100.jsonl", &long_events);

    const short_events = [_]core.session.Event{
        .{
            .at_ms = now - (45 * 60 * std.time.ms_per_s),
            .data = .{ .prompt = .{ .text = "Short title" } },
        },
        .{
            .at_ms = now - (45 * 60 * std.time.ms_per_s),
            .data = .{ .usage = .{ .tot_tok = 46 } },
        },
    };
    try writeSessionEventsFile(tmp, "sess/200.jsonl", &short_events);

    const sess_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "sess");
    defer std.testing.allocator.free(sess_abs);

    var ui = try tui_harness.Ui.init(std.testing.allocator, 48, 8, "m", "p");
    defer ui.deinit();
    try std.testing.expect(try showResumeOverlay(std.testing.allocator, &ui, sess_abs));

    var frm = try tui_frame.Frame.init(std.testing.allocator, 48, 8);
    defer frm.deinit(std.testing.allocator);
    try ui.ov.?.render(&frm);

    const row2 = try frameRowBoxAlloc(std.testing.allocator, &frm, 2);
    defer std.testing.allocator.free(row2);
    const row3 = try frameRowBoxAlloc(std.testing.allocator, &frm, 3);
    defer std.testing.allocator.free(row3);
    const row4 = try frameRowBoxAlloc(std.testing.allocator, &frm, 4);
    defer std.testing.allocator.free(row4);
    const row5 = try frameRowBoxAlloc(std.testing.allocator, &frm, 5);
    defer std.testing.allocator.free(row5);

    const Snap = struct {
        row2: []const u8,
        row3: []const u8,
        row4: []const u8,
        row5: []const u8,
    };
    try oh.snap(@src(),
        \\app.runtime.test.showResumeOverlay fixed-width snapshot aligns age and token columns.Snap
        \\  .row2: []const u8
        \\    "|┌────────────────Resume Session────────────────┐|"
        \\  .row3: []const u8
        \\    "|│ > A very long session titl...   2h  1.3k tok │|"
        \\  .row4: []const u8
        \\    "|│   Short title                  45m    46 tok │|"
        \\  .row5: []const u8
        \\    "|└──────────────────────────────────────────────┘|"
    ).expectEqual(Snap{
        .row2 = row2,
        .row3 = row3,
        .row4 = row4,
        .row5 = row5,
    });
}

test "showResumeOverlay returns false when no sessions exist" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "sess");
    const sess_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "sess");
    defer std.testing.allocator.free(sess_abs);

    var ui = try tui_harness.Ui.init(std.testing.allocator, 80, 12, "m", "p");
    defer ui.deinit();

    try std.testing.expect(!(try showResumeOverlay(std.testing.allocator, &ui, sess_abs)));
    try std.testing.expect(ui.ov == null);
}

test "restoreSessionIntoUi replays session history and resets stale ui state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "sess");

    const file = try tmp.dir.createFile(std.testing.io, "sess/100.jsonl", .{});
    defer file.close(std.testing.io);
    const events = [_]core.session.Event{
        .{
            .at_ms = 1,
            .data = .{ .prompt = .{ .text = "old prompt" } },
        },
        .{
            .at_ms = 2,
            .data = .{ .text = .{ .text = "old answer" } },
        },
        .{
            .at_ms = 3,
            .data = .{ .tool_call = .{ .id = "call-1", .name = "read", .args = "{\"path\":\"a.txt\"}" } },
        },
        .{
            .at_ms = 4,
            .data = .{ .tool_result = .{ .id = "call-1", .output = "ok", .is_err = false } },
        },
        .{
            .at_ms = 5,
            .data = .{ .usage = .{ .in_tok = 12, .out_tok = 34, .tot_tok = 46, .cache_read = 1, .cache_write = 2 } },
        },
        .{
            .at_ms = 6,
            .data = .{ .stop = .{ .reason = .done } },
        },
    };
    for (events) |ev| {
        const raw = try core.session.encodeEventAlloc(std.testing.allocator, ev);
        defer std.testing.allocator.free(raw);
        try file.writeStreamingAll(std.testing.io, raw);
        try file.writeStreamingAll(std.testing.io, "\n");
    }

    const sess_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "sess");
    defer std.testing.allocator.free(sess_abs);

    var ui = try tui_harness.Ui.init(std.testing.allocator, 80, 12, "m", "p");
    defer ui.deinit();

    try ui.tr.infoText("stale");
    try ui.onProvider(.{ .tool_call = .{ .id = "stale-1", .name = "ls", .args = "{}" } });
    ui.panels.cum_tok = 999;
    ui.panels.has_usage = true;
    ui.panels.run_state = .failed;

    try restoreSessionIntoUi(std.testing.allocator, &ui, sess_abs, false, "100");

    var saw_stale = false;
    var saw_prompt = false;
    var saw_answer = false;
    for (ui.tr.blocks.items) |blk| {
        if (std.mem.eql(u8, blk.buf.items, "stale")) saw_stale = true;
        if (std.mem.eql(u8, blk.buf.items, "old prompt")) saw_prompt = true;
        if (std.mem.eql(u8, blk.buf.items, "old answer")) saw_answer = true;
    }
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};
    const row = ui.panels.tool(0);
    const snap = try std.fmt.allocPrint(
        std.testing.allocator,
        "stale={} prompt={} answer={} usage={} tok={} state={s} count={} row={s}|{s}|{s}",
        .{
            saw_stale,
            saw_prompt,
            saw_answer,
            ui.panels.has_usage,
            ui.panels.cum_tok,
            @tagName(ui.panels.state()),
            ui.panels.count(),
            row.id,
            row.name,
            @tagName(row.state),
        },
    );
    defer std.testing.allocator.free(snap);
    try oh.snap(@src(),
        \\[]u8
        \\  "stale=false prompt=true answer=true usage=true tok=46 state=idle count=1 row=call-1|read|ok"
    ).expectEqual(snap);
}

test "restoreSessionIntoUi ignores empty blocks when rendering bottom row" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "sess");

    const file = try tmp.dir.createFile(std.testing.io, "sess/100.jsonl", .{});
    defer file.close(std.testing.io);
    const events = [_]core.session.Event{
        .{
            .at_ms = 1,
            .data = .{ .text = .{ .text = "" } },
        },
        .{
            .at_ms = 2,
            .data = .{ .tool_call = .{ .id = "call-1", .name = "bash", .args = "{\"cmd\":\"printf ok\"}" } },
        },
        .{
            .at_ms = 3,
            .data = .{ .tool_result = .{ .id = "call-1", .output = "", .is_err = false } },
        },
        .{
            .at_ms = 4,
            .data = .{ .text = .{ .text = "tail line" } },
        },
    };
    for (events) |ev| {
        const raw = try core.session.encodeEventAlloc(std.testing.allocator, ev);
        defer std.testing.allocator.free(raw);
        try file.writeStreamingAll(std.testing.io, raw);
        try file.writeStreamingAll(std.testing.io, "\n");
    }

    const sess_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "sess");
    defer std.testing.allocator.free(sess_abs);

    var ui = try tui_harness.Ui.init(std.testing.allocator, 24, 4, "m", "p");
    defer ui.deinit();

    try restoreSessionIntoUi(std.testing.allocator, &ui, sess_abs, false, "100");

    var frm = try tui_frame.Frame.init(std.testing.allocator, 24, 1);
    defer frm.deinit(std.testing.allocator);
    try ui.tr.render(&frm, .{ .x = 0, .y = 0, .w = 24, .h = 1 });

    var raw: [24]u8 = undefined;
    var x: usize = 0;
    while (x < frm.w) : (x += 1) {
        const c = try frm.cell(x, 0);
        raw[x] = if (c.cp <= 0x7f) @intCast(c.cp) else '?';
    }
    try std.testing.expect(std.mem.indexOf(u8, raw[0..], "tail line") != null);
}

test "runtime tui non-tty /resume restores session without running provider turn" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sess");
    const file = try tmp.dir.createFile(std.testing.io, "sess/100.jsonl", .{});
    defer file.close(std.testing.io);
    const events = [_]core.session.Event{
        .{
            .at_ms = 1,
            .data = .{ .prompt = .{ .text = "old prompt" } },
        },
        .{
            .at_ms = 2,
            .data = .{ .text = .{ .text = "old answer" } },
        },
        .{
            .at_ms = 3,
            .data = .{ .stop = .{ .reason = .done } },
        },
    };
    for (events) |ev| {
        const raw = try core.session.encodeEventAlloc(std.testing.allocator, ev);
        defer std.testing.allocator.free(raw);
        try file.writeStreamingAll(std.testing.io, raw);
        try file.writeStreamingAll(std.testing.io, "\n");
    }

    const sess_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "sess");
    defer std.testing.allocator.free(sess_abs);

    var cfg = cli.Run{
        .mode = .tui,
        .prompt = null,
        .cfg = .{
            .mode = .tui,
            .model = try std.testing.allocator.dupe(u8, "m"),
            .provider = try std.testing.allocator.dupe(u8, "p"),
            .session_dir = try std.testing.allocator.dupe(u8, sess_abs),
            .provider_cmd = try std.testing.allocator.dupe(u8, "cat >/dev/null; printf 'text:MODEL-RAN\\nstop:done\\n'"),
        },
    };
    defer cfg.cfg.deinit(std.testing.allocator);

    var in_fbs: std.Io.Reader = .fixed("/resume 100\n");
    var out_buf: [65536]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const sid = try execWithIo(
        std.testing.allocator,
        cfg,
        &in_fbs,
        &out_fbs,
    );
    defer std.testing.allocator.free(sid);
    try std.testing.expectEqualStrings("100", sid);

    const written = out_fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "resumed session 100") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "MODEL-RAN") == null);

    var session_dir = try std.Io.Dir.openDirAbsolute(std.testing.io, sess_abs, .{});
    defer session_dir.close(std.testing.io);
    var rdr = try core.session.ReplayReader.init(std.testing.allocator, session_dir, "100", .{});
    defer rdr.deinit();

    var prompt_ct: usize = 0;
    var saw_resume_prompt = false;
    while (try rdr.next()) |ev| {
        switch (ev.data) {
            .prompt => |p| {
                prompt_ct += 1;
                if (std.mem.eql(u8, p.text, "/resume 100")) saw_resume_prompt = true;
            },
            else => {}, // test only inspects .prompt events
        }
    }
    try std.testing.expectEqual(@as(usize, 1), prompt_ct);
    try std.testing.expect(!saw_resume_prompt);
}

test "syncInputFooter tracks mode and clamps queue size" {
    var ui = try tui_harness.Ui.init(std.testing.allocator, 60, 10, "m", "p");
    defer ui.deinit();

    syncInputFooter(&ui, .queue, 12);
    try std.testing.expect(ui.panels.input_mode == .queue);
    try std.testing.expectEqual(@as(u32, 12), ui.panels.queued_msgs);

    syncInputFooter(&ui, .steering, @as(usize, std.math.maxInt(u32)) + 10);
    try std.testing.expect(ui.panels.input_mode == .steering);
    try std.testing.expectEqual(std.math.maxInt(u32), ui.panels.queued_msgs);
}

test "needsAskHint detects ask-question prompts" {
    try std.testing.expect(needsAskHint("ask me questions before planning"));
    try std.testing.expect(needsAskHint("Please ASK QUESTIONS first."));
}

test "needsAskHint ignores regular prompts" {
    try std.testing.expect(!needsAskHint("build a parser for this input"));
    try std.testing.expect(!needsAskHint("summarize the codebase"));
}

test "sanitizeUtf8LossyAlloc preserves valid utf8" {
    const in = "upgrade ok ✓";
    const out = try sanitizeUtf8LossyAlloc(std.testing.allocator, in);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(in, out);
}

test "sanitizeUtf8LossyAlloc replaces invalid bytes" {
    const bad = [_]u8{ 'o', 0xff, 'k', 0xc3 };
    const out = try sanitizeUtf8LossyAlloc(std.testing.allocator, bad[0..]);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("o?k?", out);
}

test "sanitizeUtf8LossyAlloc replaces incomplete multibyte suffix per-byte" {
    const bad = [_]u8{ 'a', 0xe2, 0x82 };
    const out = try sanitizeUtf8LossyAlloc(std.testing.allocator, bad[0..]);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("a??", out);
}

test "sanitizeUtf8LossyAlloc property: output is valid utf8" {
    const pbt = @import("../core/prop_test.zig");
    try pbt.expectSanValid(sanitizeUtf8LossyAlloc, 64, .{ .iterations = 200 });
}

test "sanitizeUtf8LossyAlloc property: valid utf8 is preserved" {
    const pbt = @import("../core/prop_test.zig");
    try pbt.expectSanPreserves(sanitizeUtf8LossyAlloc, 24, .{ .iterations = 200 });
}

test "infoTextSafe accepts invalid utf8 command output" {
    var ui = try tui_harness.Ui.init(std.testing.allocator, 80, 12, "m", "p");
    defer ui.deinit();

    const bad = [_]u8{ 'u', 0xff, 'p' };
    try infoTextSafe(std.testing.allocator, &ui, bad[0..]);
    try std.testing.expectEqual(@as(usize, 1), ui.tr.count());
}

test "sanitized cwd/branch render in footer without InvalidUtf8" {
    const alloc = std.testing.allocator;

    // Non-UTF-8 cwd and branch — would crash renderFooter without sanitization.
    const bad_cwd = "/tmp/\xff/proj";
    const bad_branch = "feat/\xff";
    const bad_model = "gpt\xff";

    const safe_cwd = try ensureUtf8OrSanitize(alloc, bad_cwd);
    defer if (safe_cwd.owned) |o| alloc.free(o);
    const safe_branch = try ensureUtf8OrSanitize(alloc, bad_branch);
    defer if (safe_branch.owned) |o| alloc.free(o);
    const safe_model = try ensureUtf8OrSanitize(alloc, bad_model);
    defer if (safe_model.owned) |o| alloc.free(o);

    // Sanitized text must be valid UTF-8.
    _ = try std.unicode.Utf8View.init(safe_cwd.text);
    _ = try std.unicode.Utf8View.init(safe_branch.text);
    _ = try std.unicode.Utf8View.init(safe_model.text);

    // Must render without error.
    var ui = try tui_harness.Ui.initFull(alloc, 80, 12, safe_model.text, "p", safe_cwd.text, safe_branch.text, null);
    defer ui.deinit();

    var frm = try tui_frame.Frame.init(alloc, 80, 2);
    defer frm.deinit(alloc);
    try ui.panels.renderFooter(&frm, .{ .x = 0, .y = 0, .w = 80, .h = 2 });
}

fn eofReader() *std.Io.Reader {
    return std.Io.Reader.ending;
}

fn runtimeTestPolicyKeyPair() !core.signing.KeyPair {
    const seed = try core.signing.Seed.parseHex("8052030376d47112be7f73ed7a019293dd12ad910b654455798b4667d73de166");
    return core.signing.KeyPair.fromSeed(seed);
}

fn noopPolicy() RuntimePolicy {
    return .{
        .alloc = std.testing.allocator,
        .resolved = .{
            .doc = .{ .rules = &.{} },
            .hash_hex = [_]u8{'0'} ** 64,
            .has_files = false,
            .locked = false,
        },
    };
}

fn writeRuntimePolicy(dir: std.Io.Dir, doc: core.policy.Doc) !void {
    try dir.createDirPath(std.testing.io, ".pz");
    const kp = try runtimeTestPolicyKeyPair();
    const raw = try core.policy.encodeSignedDoc(std.testing.allocator, doc, kp);
    defer std.testing.allocator.free(raw);
    try dir.writeFile(std.testing.io, .{ .sub_path = config.policy_rel_path, .data = raw });
}

const AuditRows = struct {
    emitter: core.audit.Emitter = .{ .vt = &core.audit.Emitter.Bind(@This(), emitAudit).vt },
    rows: std.ArrayList([]u8) = .empty,

    fn deinit(self: *AuditRows, alloc: std.mem.Allocator) void {
        for (self.rows.items) |row| alloc.free(row);
        self.rows.deinit(alloc);
    }

    fn emitAudit(self: *AuditRows, alloc: std.mem.Allocator, ent: core.audit.Entry) !void {
        const raw = try core.audit.encodeAlloc(alloc, ent);
        errdefer alloc.free(raw);
        try self.rows.append(alloc, raw);
    }
};

const ActivityRows = struct {
    sink: activity.ActivitySink = undefined,
    rows: std.ArrayList(Row) = .empty,

    const Row = struct {
        kind: std.meta.Tag(activity.Event),
        session_id: []u8,
        prompt_chars: ?usize = null,
        tool_name: ?[]u8 = null,
    };

    fn bind(self: *ActivityRows) void {
        self.sink = .{ .ctx = self, .emit_fn = emit };
    }

    fn deinit(self: *ActivityRows, alloc: std.mem.Allocator) void {
        for (self.rows.items) |row| {
            alloc.free(row.session_id);
            if (row.tool_name) |tool_name| alloc.free(tool_name);
        }
        self.rows.deinit(alloc);
    }

    fn emit(ctx: *anyopaque, event: activity.Event) void {
        const self: *ActivityRows = @ptrCast(@alignCast(ctx));
        const alloc = std.testing.allocator;
        const row: Row = switch (event) {
            .session_start => |payload| .{
                .kind = .session_start,
                .session_id = alloc.dupe(u8, payload.session_id) catch @panic("activity test allocation failed"),
            },
            .prompt => |payload| .{
                .kind = .prompt,
                .session_id = alloc.dupe(u8, payload.session_id) catch @panic("activity test allocation failed"),
                .prompt_chars = payload.prompt_chars,
            },
            .activity => |payload| .{
                .kind = .activity,
                .session_id = alloc.dupe(u8, payload.session_id) catch @panic("activity test allocation failed"),
                .tool_name = alloc.dupe(u8, payload.tool_name) catch @panic("activity test allocation failed"),
            },
            .stop => |payload| .{
                .kind = .stop,
                .session_id = alloc.dupe(u8, payload.session_id) catch @panic("activity test allocation failed"),
            },
        };
        self.rows.append(alloc, row) catch @panic("activity test allocation failed");
    }
};

const AuditAttrSnap = struct {
    key: []const u8,
    vis: core.audit.Vis,
    ty: []const u8,
};

const AuditEntrySnap = struct {
    sid: []const u8,
    seq: u64,
    kind: core.audit.EventKind,
    severity: core.audit.Severity,
    outcome: core.audit.Outcome,
    res_kind: ?core.audit.ResourceKind = null,
    res_name: ?[]const u8 = null,
    op: ?[]const u8 = null,
    msg: ?[]const u8 = null,
    data_name: ?[]const u8 = null,
    call_id: ?[]const u8 = null,
    auth_mech: ?[]const u8 = null,
    attrs: []const AuditAttrSnap = &.{},
};

fn auditTraceSnap(alloc: std.mem.Allocator, rows: []const []const u8) ![]AuditEntrySnap {
    const out = try alloc.alloc(AuditEntrySnap, rows.len);
    for (rows, 0..) |row, i| {
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, row, .{});
        const root = parsed.value;
        if (root != .object) return error.UnexpectedToken;

        const kind_txt = jsonStr(root.object, "kind") orelse return error.UnexpectedToken;
        const sev_txt = jsonStr(root.object, "sev") orelse return error.UnexpectedToken;
        const out_txt = jsonStr(root.object, "out") orelse return error.UnexpectedToken;
        const kind = std.meta.stringToEnum(core.audit.EventKind, kind_txt) orelse return error.UnexpectedToken;
        const sev = std.meta.stringToEnum(core.audit.Severity, sev_txt) orelse return error.UnexpectedToken;
        const out_tag = std.meta.stringToEnum(core.audit.Outcome, out_txt) orelse return error.UnexpectedToken;

        const attrs_val = root.object.get("attrs") orelse return error.UnexpectedToken;
        if (attrs_val != .array) return error.UnexpectedToken;
        const attrs = try alloc.alloc(AuditAttrSnap, attrs_val.array.items.len);
        for (attrs_val.array.items, 0..) |attr, j| {
            if (attr != .object) return error.UnexpectedToken;
            attrs[j] = .{
                .key = jsonStr(attr.object, "key") orelse return error.UnexpectedToken,
                .vis = std.meta.stringToEnum(core.audit.Vis, jsonStr(attr.object, "vis") orelse return error.UnexpectedToken) orelse return error.UnexpectedToken,
                .ty = jsonStr(attr.object, "ty") orelse return error.UnexpectedToken,
            };
        }

        const res_obj = jsonObj(root.object, "res");
        const msg_obj = jsonObj(root.object, "msg");
        const data_obj = jsonObj(root.object, "data") orelse return error.UnexpectedToken;
        out[i] = .{
            .sid = jsonStr(root.object, "sid") orelse return error.UnexpectedToken,
            .seq = jsonU64(root.object, "seq") orelse return error.UnexpectedToken,
            .kind = kind,
            .severity = sev,
            .outcome = out_tag,
            .res_kind = if (res_obj) |obj| std.meta.stringToEnum(core.audit.ResourceKind, jsonStr(obj, "kind") orelse return error.UnexpectedToken) else null,
            .res_name = if (res_obj) |obj| jsonVisText(obj, "name") else null,
            .op = if (res_obj) |obj| jsonStr(obj, "op") else null,
            .msg = if (msg_obj) |obj| jsonVisText(obj, null) else null,
            .data_name = switch (kind) {
                .tool, .forward => jsonVisText(data_obj, "name"),
                else => null,
            },
            .call_id = switch (kind) {
                .tool => jsonStr(data_obj, "call_id"),
                else => null,
            },
            .auth_mech = switch (kind) {
                .auth => jsonStr(data_obj, "mech"),
                else => null,
            },
            .attrs = attrs,
        };
    }
    return out;
}

fn jsonObj(obj: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const v = obj.get(key) orelse return null;
    return if (v == .object) v.object else null;
}

fn jsonStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn jsonU64(obj: std.json.ObjectMap, key: []const u8) ?u64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |n| @intCast(n),
        else => null,
    };
}

fn jsonVisText(obj: std.json.ObjectMap, key: ?[]const u8) ?[]const u8 {
    const txt = if (key) |k| blk: {
        const v = obj.get(k) orelse return null;
        if (v != .object) return null;
        break :blk v.object;
    } else obj;
    const text = jsonStr(txt, "text") orelse return null;
    const vis_txt = jsonStr(txt, "vis") orelse return null;
    const vis = std.meta.stringToEnum(core.audit.Vis, vis_txt) orelse return null;
    return switch (vis) {
        .@"pub" => text,
        .mask, .hash, .secret => "[mask]",
    };
}

test "runtime print mode skips session persistence by default" {
    // P29c: headless modes (print/json) use NullStore when session == .auto.
    // No session file should be created on disk.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sess");
    const sess_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "sess");
    defer std.testing.allocator.free(sess_abs);

    var cfg = cli.Run{
        .mode = .print,
        .prompt = "ping",
        .cfg = .{
            .mode = .print,
            .model = try std.testing.allocator.dupe(u8, "m"),
            .provider = try std.testing.allocator.dupe(u8, "p"),
            .session_dir = try std.testing.allocator.dupe(u8, sess_abs),
            .provider_cmd = try std.testing.allocator.dupe(u8, "cat >/dev/null; printf 'text:pong\\nstop:done\\n'"),
        },
    };
    defer cfg.cfg.deinit(std.testing.allocator);

    var out_buf: [1024]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const sid = try execWithIo(std.testing.allocator, cfg, eofReader(), &out_fbs);
    defer std.testing.allocator.free(sid);

    // Output still works
    try std.testing.expectEqualStrings("pong\n", out_fbs.buffered());

    // No session file should exist -- NullStore discards writes
    var sess_dir = try std.Io.Dir.openDirAbsolute(std.testing.io, sess_abs, .{ .iterate = true });
    defer sess_dir.close(std.testing.io);
    var it = sess_dir.iterate();
    try std.testing.expect((try it.next(std.testing.io)) == null);
}

test "runtime executes tool calls through loop registry in print mode" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sess");
    const sess_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "sess");
    defer std.testing.allocator.free(sess_abs);

    const provider_cmd =
        "req=$(cat); " ++
        "if printf '%s' \"$req\" | grep -q '\"tool_result\"'; then " ++
        "printf 'text:done\\nstop:done\\n'; " ++
        "else " ++
        "printf 'tool_call:call-1|bash|{\"cmd\":\"printf hi\"}\\nstop:tool\\n'; " ++
        "fi";

    var cfg = cli.Run{
        .mode = .print,
        .prompt = "ship",
        .verbose = true,
        .cfg = .{
            .mode = .print,
            .model = try std.testing.allocator.dupe(u8, "m"),
            .provider = try std.testing.allocator.dupe(u8, "p"),
            .session_dir = try std.testing.allocator.dupe(u8, sess_abs),
            .provider_cmd = try std.testing.allocator.dupe(u8, provider_cmd),
        },
    };
    defer cfg.cfg.deinit(std.testing.allocator);

    var out_buf: [4096]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const sid = try execWithIo(std.testing.allocator, cfg, eofReader(), &out_fbs);
    defer std.testing.allocator.free(sid);

    const written = out_fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "done") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "stop reason=done") != null);
}

test "runtime emits ordered privacy-minimized activity lifecycle" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sess");
    const sess_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "sess");
    defer std.testing.allocator.free(sess_abs);

    const prompt = "deploy sk-live-key";
    const provider_cmd = try std.fmt.allocPrint(
        std.testing.allocator,
        "cat >/dev/null; if [ -e '{s}/tool-seen' ]; then " ++
            "printf 'text:done\\nstop:done\\n'; else touch '{s}/tool-seen'; " ++
            "printf 'tool_call:call-1|bash|{{\"cmd\":\"printf super-secret-tool-body\"}}\\nstop:tool\\n'; fi",
        .{ sess_abs, sess_abs },
    );
    defer std.testing.allocator.free(provider_cmd);

    var cfg = cli.Run{
        .mode = .print,
        .prompt = prompt,
        .verbose = true,
        .cfg = .{
            .mode = .print,
            .model = try std.testing.allocator.dupe(u8, "m"),
            .provider = try std.testing.allocator.dupe(u8, "p"),
            .session_dir = try std.testing.allocator.dupe(u8, sess_abs),
            .provider_cmd = try std.testing.allocator.dupe(u8, provider_cmd),
        },
    };
    defer cfg.cfg.deinit(std.testing.allocator);

    var out_buf: [4096]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);
    var rows = ActivityRows{};
    rows.bind();
    defer rows.deinit(std.testing.allocator);

    const sid = try execWithIoActivityHooks(
        std.testing.allocator,
        cfg,
        eofReader(),
        &out_fbs,
        .{ .sink = &rows.sink },
    );
    defer std.testing.allocator.free(sid);

    var trace: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer trace.deinit();
    var sid_match = true;
    for (rows.rows.items) |row| {
        sid_match = sid_match and std.mem.eql(u8, sid, row.session_id);
        switch (row.kind) {
            .session_start => try trace.writer.writeAll("session_start\n"),
            .prompt => try trace.writer.print("prompt chars={}\n", .{row.prompt_chars.?}),
            .activity => try trace.writer.print("activity tool={s}\n", .{row.tool_name.?}),
            .stop => try trace.writer.writeAll("stop\n"),
        }
    }
    const raw = trace.written();
    try std.testing.expectEqualStrings(
        "session_start\nprompt chars=18\nactivity tool=bash\nstop\n",
        raw,
    );
    try std.testing.expect(sid_match);
    try std.testing.expect(std.mem.indexOf(u8, raw, prompt) == null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "super-secret-tool-body") == null);
    try oh.snap(@src(),
        \\[]u8
        \\  "session_start
        \\prompt chars=18
        \\activity tool=bash
        \\stop
        \\"
    ).expectEqual(raw);
}

test "runtime activity emits stop when a turn fails after session start" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sess");
    const sess_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "sess");
    defer std.testing.allocator.free(sess_abs);

    var cfg = cli.Run{
        .mode = .print,
        .prompt = null,
        .cfg = .{
            .mode = .print,
            .model = try std.testing.allocator.dupe(u8, "m"),
            .provider = try std.testing.allocator.dupe(u8, "p"),
            .session_dir = try std.testing.allocator.dupe(u8, sess_abs),
            .provider_cmd = try std.testing.allocator.dupe(u8, "cat >/dev/null"),
        },
    };
    defer cfg.cfg.deinit(std.testing.allocator);

    var rows = ActivityRows{};
    rows.bind();
    defer rows.deinit(std.testing.allocator);
    try std.testing.expectError(error.EmptyPrompt, execWithIoActivityHooks(
        std.testing.allocator,
        cfg,
        eofReader(),
        null,
        .{ .sink = &rows.sink },
    ));
    try std.testing.expectEqual(@as(usize, 2), rows.rows.items.len);
    try std.testing.expectEqual(std.meta.Tag(activity.Event).session_start, rows.rows.items[0].kind);
    try std.testing.expectEqual(std.meta.Tag(activity.Event).stop, rows.rows.items[1].kind);
    try std.testing.expectEqualStrings(rows.rows.items[0].session_id, rows.rows.items[1].session_id);
}

test "runtime blocks tool dispatch under verified policy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sess");
    try writeRuntimePolicy(tmp.dir, .{
        .rules = &.{
            .{ .pattern = "runtime/tool/bash", .effect = .deny, .tool = "bash" },
            .{ .pattern = "*", .effect = .allow },
        },
    });

    var root = try tmp.dir.openDir(std.testing.io, ".", .{});
    defer root.close(std.testing.io);
    var guard = try path_guard.CwdGuard.enter(root);
    defer guard.deinit();
    const root_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(root_abs);
    var pol = try RuntimePolicy.load(std.testing.allocator, defaultIo(), null);
    defer pol.deinit();
    const sess_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "sess");
    defer std.testing.allocator.free(sess_abs);
    const provider_cmd =
        "req=$(cat); " ++
        "if printf '%s' \"$req\" | grep -q '\"tool_result\"'; then " ++
        "printf 'text:done\\nstop:done\\n'; " ++
        "else " ++
        "printf 'tool_call:call-1|bash|{\"cmd\":\"printf hi\"}\\nstop:tool\\n'; " ++
        "fi";

    var cfg = cli.Run{
        .mode = .print,
        .prompt = "ship",
        .verbose = true,
        .cfg = .{
            .mode = .print,
            .model = try std.testing.allocator.dupe(u8, "m"),
            .provider = try std.testing.allocator.dupe(u8, "p"),
            .session_dir = try std.testing.allocator.dupe(u8, sess_abs),
            .provider_cmd = try std.testing.allocator.dupe(u8, provider_cmd),
        },
    };
    defer cfg.cfg.deinit(std.testing.allocator);

    var out_buf: [4096]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const sid = try execWithIo(std.testing.allocator, cfg, eofReader(), &out_fbs);
    defer std.testing.allocator.free(sid);

    const written = out_fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "tool_result id=\"call-1\" is_err=true out=\"blocked by policy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "stop reason=done") != null);

    // P29c: headless print mode uses NullStore by default -- no session
    // replay to verify. Policy enforcement is validated via output above.
}

fn verifyDeniedBashAuditSyslog(transport: core.syslog.Transport) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sess");
    try writeRuntimePolicy(tmp.dir, .{
        .rules = &.{
            .{ .pattern = "runtime/tool/bash", .effect = .deny, .tool = "bash" },
            .{ .pattern = "*", .effect = .allow },
        },
    });

    var root = try tmp.dir.openDir(std.testing.io, ".", .{});
    defer root.close(std.testing.io);
    var guard = try path_guard.CwdGuard.enter(root);
    defer guard.deinit();
    const sess_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "sess");
    defer std.testing.allocator.free(sess_abs);
    const provider_cmd =
        "req=$(cat); " ++
        "if printf '%s' \"$req\" | grep -q '\"tool_result\"'; then " ++
        "printf 'text:done\\nstop:done\\n'; " ++
        "else " ++
        "printf 'tool_call:call-1|bash|{\"cmd\":\"rm -rf /tmp/bash-secret/.env\"}\\nstop:tool\\n'; " ++
        "fi";

    var cfg = cli.Run{
        .mode = .print,
        .prompt = "ship",
        .verbose = true,
        .cfg = .{
            .mode = .print,
            .model = try std.testing.allocator.dupe(u8, "m"),
            .provider = try std.testing.allocator.dupe(u8, "p"),
            .session_dir = try std.testing.allocator.dupe(u8, sess_abs),
            .provider_cmd = try std.testing.allocator.dupe(u8, provider_cmd),
        },
    };
    defer cfg.cfg.deinit(std.testing.allocator);

    var out_buf: [4096]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);
    var rows = AuditRows{};
    defer rows.deinit(std.testing.allocator);

    const sid = try execWithIoHooks(
        std.testing.allocator,
        cfg,
        eofReader(),
        &out_fbs,
        .{
            .audit_emitter = &rows.emitter,
            .now_ms = struct {
                fn f() i64 {
                    return 141;
                }
            }.f,
        },
    );
    defer std.testing.allocator.free(sid);

    const written = out_fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "tool_result id=\"call-1\" is_err=true out=\"blocked by policy\"") != null);
    try std.testing.expect(rows.rows.items.len != 0);

    switch (transport) {
        .udp => {
            var collector = try syslog_mock.UdpCollector.init();
            defer collector.deinit();
            const t = try collector.spawnCount(rows.rows.items.len);
            // Join exactly once, before collector.deinit closes the socket: an
            // early `try` failure below must not leave the collector thread
            // receiving on a closed fd (BADF). The bool guard prevents a
            // double-join on the success path.
            var joined = false;
            defer if (!joined) t.join();

            var sender = try core.syslog.Sender.init(std.testing.allocator, .{
                .io = std.testing.io,
                .transport = .udp,
                .host = "127.0.0.1",
                .port = collector.port(),
                .allow_private = true,
            });
            defer sender.deinit();

            try audit_e2e.shipAuditRows(std.testing.allocator, &sender, rows.rows.items);
            t.join();
            joined = true;
            try audit_e2e.verifyRoundTrip(&collector, rows.rows.items);
        },
        .tcp, .tls => {
            var collector = try syslog_mock.TcpCollector.init();
            defer collector.deinit();
            const t = try collector.spawnCount(rows.rows.items.len);
            // Join exactly once, before collector.deinit closes the socket: an
            // early `try` failure below must not leave the collector thread
            // accepting/receiving on a closed fd (BADF). The bool guard
            // prevents a double-join on the success path.
            var joined = false;
            defer if (!joined) t.join();

            var sender = try core.syslog.Sender.init(std.testing.allocator, .{
                .io = std.testing.io,
                .transport = .tcp,
                .host = "127.0.0.1",
                .port = collector.port(),
                .allow_private = true,
            });
            defer sender.deinit();

            try audit_e2e.shipAuditRows(std.testing.allocator, &sender, rows.rows.items);
            t.join();
            joined = true;
            try audit_e2e.verifyRoundTrip(&collector, rows.rows.items);
        },
    }
}

test "runtime denied bash audit ships through udp syslog" {
    try verifyDeniedBashAuditSyslog(.udp);
}

test "runtime denied bash audit ships through tcp syslog" {
    try verifyDeniedBashAuditSyslog(.tcp);
}

test "AuditShipper buffers events during disconnect and flushes on reconnect" {
    // Verifies the runtime's AuditShipper struct wires SyslogShipper correctly:
    // events are buffered during collector outage and flushed in order on reconnect.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Use a failing connector to simulate collector outage.
    const FailConnCtx = struct {
        connector: core.audit.Connector = .{ .vt = &core.audit.Connector.Bind(@This(), doConnect).vt },
        fn doConnect(_: *@This()) anyerror!*core.audit.Connection {
            return error.ConnectionRefused;
        }
    };
    var fail_conn = FailConnCtx{};

    var shipper: AuditShipper = undefined;
    shipper.alloc = std.testing.allocator;
    shipper.now_ms = struct {
        fn f() i64 {
            return 42;
        }
    }.f;
    shipper.sender_conn = undefined;
    shipper.shipper = try core.audit.SyslogShipper.init(std.testing.allocator, .{}, .{
        .connector = &fail_conn.connector,
        .buf_cap = 8,
        .overflow = .drop_oldest,
        .io = std.testing.io,
        .spool_dir = tmp.dir,
    });
    defer shipper.deinit();

    // Send an event — connection will fail, event is buffered
    const entry = core.audit.Entry{
        .ts_ms = 42,
        .sid = "test-sid",
        .seq = 1,
        .actor = .{ .kind = .sys },
        .data = .{ .sess = .{ .op = .start, .tty = false } },
    };
    const result = try shipper.shipper.send(entry, 42);
    try std.testing.expectEqual(core.audit.SendState.buffered, result.state);
    try std.testing.expectEqual(@as(usize, 1), result.queued);

    // Verify spool file was written
    var count: usize = 0;
    var it = tmp.dir.iterate();
    while (try it.next(std.testing.io)) |ent| {
        if (std.mem.endsWith(u8, ent.name, ".spool")) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "AuditShipper fail_closed overflow rejects when ring full" {
    const FailConnCtx2 = struct {
        connector: core.audit.Connector = .{ .vt = &core.audit.Connector.Bind(@This(), doConnect).vt },
        fn doConnect(_: *@This()) anyerror!*core.audit.Connection {
            return error.ConnectionRefused;
        }
    };
    var fail_conn2 = FailConnCtx2{};

    var shipper: AuditShipper = undefined;
    shipper.alloc = std.testing.allocator;
    shipper.now_ms = struct {
        fn f() i64 {
            return 0;
        }
    }.f;
    shipper.sender_conn = undefined;
    shipper.shipper = try core.audit.SyslogShipper.init(std.testing.allocator, .{}, .{
        .connector = &fail_conn2.connector,
        .buf_cap = 2,
        .overflow = .fail_closed,
    });
    defer shipper.deinit();

    const entry = core.audit.Entry{
        .ts_ms = 1,
        .sid = "test-sid",
        .seq = 1,
        .actor = .{ .kind = .sys },
        .data = .{ .sess = .{ .op = .start, .tty = false } },
    };
    // Fill the ring
    _ = try shipper.shipper.send(entry, 0);
    _ = try shipper.shipper.send(entry, 1);
    // Third should fail: ring is full with fail_closed
    try std.testing.expectError(error.SpoolFull, shipper.shipper.send(entry, 2));
}

test "subagent stub inherits effective policy hash" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeRuntimePolicy(tmp.dir, .{
        .rules = &.{
            .{ .pattern = "runtime/subagent/*", .effect = .allow },
        },
    });

    var root = try tmp.dir.openDir(std.testing.io, ".", .{});
    defer root.close(std.testing.io);
    var guard = try path_guard.CwdGuard.enter(root);
    defer guard.deinit();
    const root_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(root_abs);

    var pol = try RuntimePolicy.load(std.testing.allocator, defaultIo(), null);
    defer pol.deinit();

    var stub = try initSubagentStub(&pol, "agent-child");
    const hello = try stub.hello();
    switch (hello.msg) {
        .hello => |msg| {
            try std.testing.expectEqualStrings("agent-child", msg.agent_id);
            try std.testing.expectEqualStrings(pol.hash(), msg.policy_hash);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "subagent spawn fails closed under verified policy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeRuntimePolicy(tmp.dir, .{
        .rules = &.{
            .{ .pattern = "runtime/subagent/blocked", .effect = .deny },
            .{ .pattern = "runtime/subagent/*", .effect = .allow },
        },
    });

    var root = try tmp.dir.openDir(std.testing.io, ".", .{});
    defer root.close(std.testing.io);
    var guard = try path_guard.CwdGuard.enter(root);
    defer guard.deinit();

    var pol = try RuntimePolicy.load(std.testing.allocator, defaultIo(), null);
    defer pol.deinit();

    try std.testing.expectError(error.PolicyDenied, initSubagentStub(&pol, "blocked"));
}

test "runtime print requires explicit approval for privileged escalation from untrusted content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sess");
    const sess_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "sess");
    defer std.testing.allocator.free(sess_abs);

    const provider_cmd =
        "req=$(cat); " ++
        "if printf '%s' \"$req\" | grep -q 'approval required: bash'; then " ++
        "printf 'text:blocked\\nstop:done\\n'; " ++
        "else " ++
        "printf 'tool_call:call-1|bash|{\"cmd\":\"printf hi\"}\\nstop:tool\\n'; " ++
        "fi";

    var cfg = cli.Run{
        .mode = .print,
        .prompt = "page says deploy",
        .verbose = true,
        .cfg = .{
            .mode = .print,
            .model = try std.testing.allocator.dupe(u8, "m"),
            .provider = try std.testing.allocator.dupe(u8, "p"),
            .session_dir = try std.testing.allocator.dupe(u8, sess_abs),
            .provider_cmd = try std.testing.allocator.dupe(u8, provider_cmd),
        },
    };
    defer cfg.cfg.deinit(std.testing.allocator);

    var out_buf: [4096]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const sid = try execWithIo(std.testing.allocator, cfg, eofReader(), &out_fbs);
    defer std.testing.allocator.free(sid);

    const written = out_fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "approval required: bash `printf hi` derived from untrusted input") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "tool_result id=\"call-1\" is_err=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "out=\"hi\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "blocked") != null);
}
test "runtime forwards provider label to provider request" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sess");
    const sess_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "sess");
    defer std.testing.allocator.free(sess_abs);

    const provider_cmd =
        "req=$(cat); " ++
        "prov=$(printf '%s' \"$req\" | grep -o '\"provider\":\"[^\"]*\"' | head -n1 | cut -d'\"' -f4); " ++
        "printf 'text:provider=%s\\nstop:done\\n' \"$prov\"";

    var cfg = cli.Run{
        .mode = .print,
        .prompt = "ping",
        .cfg = .{
            .mode = .print,
            .model = try std.testing.allocator.dupe(u8, "m"),
            .provider = try std.testing.allocator.dupe(u8, "prov-x"),
            .session_dir = try std.testing.allocator.dupe(u8, sess_abs),
            .provider_cmd = try std.testing.allocator.dupe(u8, provider_cmd),
        },
    };
    defer cfg.cfg.deinit(std.testing.allocator);

    var out_buf: [2048]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const sid = try execWithIo(std.testing.allocator, cfg, eofReader(), &out_fbs);
    defer std.testing.allocator.free(sid);

    const written = out_fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "provider=prov-x") != null);
}

test "runtime executes tui mode path with provided prompt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sess");
    const sess_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "sess");
    defer std.testing.allocator.free(sess_abs);

    var cfg = cli.Run{
        .mode = .tui,
        .prompt = "ping",
        .cfg = .{
            .mode = .tui,
            .model = try std.testing.allocator.dupe(u8, "m"),
            .provider = try std.testing.allocator.dupe(u8, "p"),
            .session_dir = try std.testing.allocator.dupe(u8, sess_abs),
            .provider_cmd = try std.testing.allocator.dupe(u8, "cat >/dev/null; printf 'text:pong\\nstop:done\\n'"),
        },
    };
    defer cfg.cfg.deinit(std.testing.allocator);

    var out_buf: [16384]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const sid = try execWithIo(std.testing.allocator, cfg, eofReader(), &out_fbs);
    defer std.testing.allocator.free(sid);

    const written = out_fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\x1b[2J") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "pong") != null);

    var session_dir = try std.Io.Dir.openDirAbsolute(std.testing.io, sess_abs, .{});
    defer session_dir.close(std.testing.io);

    var rdr = try core.session.ReplayReader.init(std.testing.allocator, session_dir, sid, .{});
    defer rdr.deinit();

    const ev0 = (try rdr.next()) orelse return error.TestUnexpectedResult;
    switch (ev0.data) {
        .prompt => |out| try std.testing.expectEqualStrings("ping", out.text),
        else => return error.TestUnexpectedResult,
    }
}

test "runtime tui overflow retries once with injected live stdin" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sess");
    const sess_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "sess");
    defer std.testing.allocator.free(sess_abs);

    var root = try tmp.dir.openDir(std.testing.io, ".", .{});
    defer root.close(std.testing.io);
    var guard = try path_guard.CwdGuard.enter(root);
    defer guard.deinit();

    var cfg = cli.Run{
        .mode = .tui,
        .prompt = null,
        .cfg = .{
            .mode = .tui,
            .model = try std.testing.allocator.dupe(u8, "m"),
            .provider = try std.testing.allocator.dupe(u8, "p"),
            .session_dir = try std.testing.allocator.dupe(u8, sess_abs),
        },
    };
    defer cfg.cfg.deinit(std.testing.allocator);

    const stdin_pipe = try makePipe(false);
    defer closeFd(stdin_pipe[0]);
    defer closeFd(stdin_pipe[1]);

    const RetryStream = struct {
        stream: core.providers.Stream = .{ .vt = &core.providers.Stream.Bind(@This(), @This().next, @This().deinit).vt },
        alloc: std.mem.Allocator,
        evs: []const core.providers.Event,
        idx: usize = 0,

        fn next(self: *@This()) !?core.providers.Event {
            if (self.idx >= self.evs.len) return null;
            const ev = self.evs[self.idx];
            self.idx += 1;
            return ev;
        }

        fn deinit(self: *@This()) void {
            self.alloc.destroy(self);
        }
    };

    const RetryProvider = struct {
        provider: core.providers.Provider = .{ .vt = &core.providers.Provider.Bind(@This(), @This().start).vt },
        alloc: std.mem.Allocator,
        starts: u8 = 0,
        const first = [_]core.providers.Event{
            .{
                .stop = .{ .reason = .max_out },
            },
        };
        const second = [_]core.providers.Event{
            .{ .text = "retry-ok" },
            .{
                .stop = .{ .reason = .done },
            },
        };

        fn start(self: *@This(), _: core.providers.Request) !*core.providers.Stream {
            self.starts += 1;
            const s = try self.alloc.create(RetryStream);
            s.* = .{
                .alloc = self.alloc,
                .evs = if (self.starts == 1) &first else &second,
            };
            return &s.stream;
        }
    };
    var provider_impl = RetryProvider{ .alloc = std.testing.allocator };

    var pol = try RuntimePolicy.load(std.testing.allocator, defaultIo(), null);
    defer pol.deinit();
    var tools_rt = core.tools.builtin.Runtime.init(.{
        .alloc = std.testing.allocator,
        .tool_mask = core.tools.builtin.mask_all,
    });
    const dir = try tmp.dir.openDir(std.testing.io, "sess", .{ .iterate = true });
    var fs_store = try core.session.fs_store.Store.init(.{
        .alloc = std.testing.allocator,
        .dir = dir,
        .flush = .{
            .always = {},
        },
        .replay = .{},
    });
    defer fs_store.deinit();
    var sid = try std.testing.allocator.dupe(u8, "s1");
    defer std.testing.allocator.free(sid);

    var out_buf: [32768]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    try runTui(
        std.testing.allocator,
        cfg,
        &sid,
        &provider_impl.provider,
        &fs_store.session_store,
        &pol,
        &tools_rt,
        eofReader(),
        &out_fbs,
        "sess",
        false,
        null,
        false,
        .{},
        .{
            .stdin_fd = stdin_pipe[0],
            .live = true,
            .raw_mode = false,
            .stop_after_completions = 1,
            .submit_text = "ping",
        },
        null,
        null,
        null,
    );

    var session_dir = try std.Io.Dir.openDirAbsolute(std.testing.io, sess_abs, .{});
    defer session_dir.close(std.testing.io);
    var rdr = try core.session.ReplayReader.init(std.testing.allocator, session_dir, sid, .{});
    defer rdr.deinit();

    var events = std.ArrayList(u8).empty;
    defer events.deinit(std.testing.allocator);
    while (try rdr.next()) |ev| {
        switch (ev.data) {
            .prompt => |p| try events.print(std.testing.allocator, "prompt:{s}\n", .{p.text}),
            .text => |t| try events.print(std.testing.allocator, "text:{s}\n", .{t.text}),
            else => {}, // test only inspects .prompt and .text events
        }
    }
    const plain_out = try tui_transcript.stripAnsi(std.testing.allocator, out_fbs.buffered());
    defer std.testing.allocator.free(plain_out);

    const Snap = struct {
        retry_ct: u8,
        saw_notice: bool,
        saw_retry_text: bool,
        events: []const u8,
    };
    try oh.snap(@src(),
        \\app.runtime.test.runtime tui overflow retries once with injected live stdin.Snap
        \\  .retry_ct: u8 = 2
        \\  .saw_notice: bool = true
        \\  .saw_retry_text: bool = true
        \\  .events: []const u8
        \\    "prompt:ping
        \\prompt:ping
        \\text:retry-ok
        \\"
    ).expectEqual(Snap{
        .retry_ct = provider_impl.starts,
        .saw_notice = std.mem.indexOf(u8, plain_out, "overflow detected:") != null and
            std.mem.indexOf(u8, plain_out, "retrying") != null,
        .saw_retry_text = std.mem.indexOf(u8, events.items, "text:retry-ok\n") != null,
        .events = events.items,
    });
}

test "runtime tui reports error when no provider available" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sess");
    const sess_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "sess");
    defer std.testing.allocator.free(sess_abs);

    var cfg = cli.Run{
        .mode = .tui,
        .prompt = "ping",
        .cfg = .{
            .mode = .tui,
            .model = try std.testing.allocator.dupe(u8, "m"),
            .provider = try std.testing.allocator.dupe(u8, "p"),
            .session_dir = try std.testing.allocator.dupe(u8, sess_abs),
            .provider_cmd = null,
        },
    };
    defer cfg.cfg.deinit(std.testing.allocator);

    var out_buf: [16384]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const sid = try execWithIo(std.testing.allocator, cfg, eofReader(), &out_fbs);
    defer std.testing.allocator.free(sid);

    const written = out_fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "provider unavailable") != null);
}

test "runtime no-config does not read or migrate legacy auth" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "sess");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.pi/agent/auth.json",
        .data =
        \\{
        \\  "anthropic": {
        \\    "type": "api_key",
        \\    "key": "sk-legacy"
        \\  }
        \\}
        ,
    });
    const home_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "home");
    defer std.testing.allocator.free(home_abs);
    const sess_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "sess");
    defer std.testing.allocator.free(sess_abs);

    var cfg = cli.Run{
        .mode = .tui,
        .prompt = "ping",
        .home = home_abs,
        .no_session = true,
        .no_config = true,
        .cfg = .{
            .mode = .tui,
            .model = try std.testing.allocator.dupe(u8, "m"),
            .provider = try std.testing.allocator.dupe(u8, "anthropic"),
            .session_dir = try std.testing.allocator.dupe(u8, sess_abs),
            .provider_cmd = null,
        },
    };
    defer cfg.cfg.deinit(std.testing.allocator);

    var out_buf: [16384]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const sid = try execWithIo(std.testing.allocator, cfg, eofReader(), &out_fbs);
    defer std.testing.allocator.free(sid);

    const written = out_fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "direct provider runtimes are disabled by policy") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "PZ_PROVIDER_CMD") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "ANTHROPIC_API_KEY") == null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "home/.pz/auth.json", .{}));
}

test "runtime print reports unsupported native provider without provider_cmd" {
    // A provider label that is NOT in the registry (no native client, no dynamic
    // arm) reports the "native provider unavailable" message and stops. After
    // MP7, only a genuinely unregistered name (e.g. "cohere") hits this path —
    // the OpenAI-compatible providers now construct the dynamic arm instead.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sess");
    const sess_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "sess");
    defer std.testing.allocator.free(sess_abs);

    var cfg = cli.Run{
        .mode = .print,
        .prompt = "ping",
        .cfg = .{
            .mode = .print,
            .model = try std.testing.allocator.dupe(u8, "m"),
            .provider = try std.testing.allocator.dupe(u8, "cohere"),
            .session_dir = try std.testing.allocator.dupe(u8, sess_abs),
            .provider_cmd = null,
        },
    };
    defer cfg.cfg.deinit(std.testing.allocator);

    var out_buf: [4096]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    try std.testing.expectError(
        error.ProviderStopped,
        execWithIo(std.testing.allocator, cfg, eofReader(), &out_fbs),
    );

    const written = out_fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "native provider unavailable") != null);
}

test "runtime print disables direct dynamic providers without provider_cmd" {
    // A registered OpenAI-compatible provider is still known, but direct runtime
    // construction is disabled unless the caller supplies an explicit approved
    // provider command adapter.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sess");
    const sess_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "sess");
    defer std.testing.allocator.free(sess_abs);

    var cfg = cli.Run{
        .mode = .print,
        .prompt = "ping",
        .no_config = true,
        .cfg = .{
            .mode = .print,
            .model = try std.testing.allocator.dupe(u8, "m"),
            .provider = try std.testing.allocator.dupe(u8, "deepseek"),
            .session_dir = try std.testing.allocator.dupe(u8, sess_abs),
            .provider_cmd = null,
        },
    };
    defer cfg.cfg.deinit(std.testing.allocator);

    var out_buf: [4096]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    try std.testing.expectError(
        error.ProviderStopped,
        execWithIo(std.testing.allocator, cfg, eofReader(), &out_fbs),
    );

    const written = out_fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "direct provider runtimes are disabled by policy") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "PZ_PROVIDER_CMD") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "deepseek credentials missing") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "native provider unavailable") == null);
}

test "runtime tui consumes multiple prompts from input stream" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sess");
    const sess_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "sess");
    defer std.testing.allocator.free(sess_abs);

    const provider_cmd =
        "req=$(cat); " ++
        "users=$(printf '%s' \"$req\" | grep -o '\"role\":\"user\"' | wc -l | tr -d '[:space:]'); " ++
        "printf 'text:u%s\\nstop:done\\n' \"$users\"";

    var cfg = cli.Run{
        .mode = .tui,
        .prompt = null,
        .cfg = .{
            .mode = .tui,
            .model = try std.testing.allocator.dupe(u8, "m"),
            .provider = try std.testing.allocator.dupe(u8, "p"),
            .session_dir = try std.testing.allocator.dupe(u8, sess_abs),
            .provider_cmd = try std.testing.allocator.dupe(u8, provider_cmd),
        },
    };
    defer cfg.cfg.deinit(std.testing.allocator);

    var in_fbs: std.Io.Reader = .fixed("first\nsecond\n");
    var out_buf: [32768]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const sid = try execWithIo(
        std.testing.allocator,
        cfg,
        &in_fbs,
        &out_fbs,
    );
    defer std.testing.allocator.free(sid);

    const written = out_fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "u1") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "u2") != null);

    var session_dir = try std.Io.Dir.openDirAbsolute(std.testing.io, sess_abs, .{});
    defer session_dir.close(std.testing.io);
    var rdr = try core.session.ReplayReader.init(std.testing.allocator, session_dir, sid, .{});
    defer rdr.deinit();

    var prompt_ct: usize = 0;
    while (try rdr.next()) |ev| {
        switch (ev.data) {
            .prompt => |p| {
                if (prompt_ct == 0) try std.testing.expectEqualStrings("first", p.text);
                if (prompt_ct == 1) try std.testing.expectEqualStrings("second", p.text);
                prompt_ct += 1;
            },
            else => {}, // test only inspects .prompt events
        }
    }
    try std.testing.expectEqual(@as(usize, 2), prompt_ct);
}

test "runtime tui rejects blank-only stdin input" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sess");
    const sess_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "sess");
    defer std.testing.allocator.free(sess_abs);

    var cfg = cli.Run{
        .mode = .tui,
        .prompt = null,
        .cfg = .{
            .mode = .tui,
            .model = try std.testing.allocator.dupe(u8, "m"),
            .provider = try std.testing.allocator.dupe(u8, "p"),
            .session_dir = try std.testing.allocator.dupe(u8, sess_abs),
            .provider_cmd = try std.testing.allocator.dupe(u8, "cat >/dev/null; printf 'text:noop\\nstop:done\\n'"),
        },
    };
    defer cfg.cfg.deinit(std.testing.allocator);

    var in_fbs: std.Io.Reader = .fixed("\n\r\n\n");
    var out_buf: [16384]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    try std.testing.expectError(
        error.EmptyPrompt,
        execWithIo(
            std.testing.allocator,
            cfg,
            &in_fbs,
            &out_fbs,
        ),
    );
}

fn expectLatestSessionReused(session_sel: anytype) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sess");
    const sess_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "sess");
    defer std.testing.allocator.free(sess_abs);

    {
        const old_file = try tmp.dir.createFile(std.testing.io, "sess/100.jsonl", .{});
        defer old_file.close(std.testing.io);
        const old_ev = try core.session.encodeEventAlloc(std.testing.allocator, .{
            .at_ms = 1,
            .data = .{
                .prompt = .{ .text = "old-100" },
            },
        });
        defer std.testing.allocator.free(old_ev);
        try old_file.writeStreamingAll(std.testing.io, old_ev);
        try old_file.writeStreamingAll(std.testing.io, "\n");
    }
    {
        const old_file = try tmp.dir.createFile(std.testing.io, "sess/200.jsonl", .{});
        defer old_file.close(std.testing.io);
        const old_ev = try core.session.encodeEventAlloc(std.testing.allocator, .{
            .at_ms = 1,
            .data = .{
                .prompt = .{ .text = "old-200" },
            },
        });
        defer std.testing.allocator.free(old_ev);
        try old_file.writeStreamingAll(std.testing.io, old_ev);
        try old_file.writeStreamingAll(std.testing.io, "\n");
    }

    var cfg = cli.Run{
        .mode = .print,
        .prompt = "new-turn",
        .session = session_sel,
        .cfg = .{
            .mode = .print,
            .model = try std.testing.allocator.dupe(u8, "m"),
            .provider = try std.testing.allocator.dupe(u8, "p"),
            .session_dir = try std.testing.allocator.dupe(u8, sess_abs),
            .provider_cmd = try std.testing.allocator.dupe(u8, "cat >/dev/null; printf 'text:ok\\nstop:done\\n'"),
        },
    };
    defer cfg.cfg.deinit(std.testing.allocator);

    var out_buf: [1024]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const sid = try execWithIo(std.testing.allocator, cfg, eofReader(), &out_fbs);
    defer std.testing.allocator.free(sid);
    try std.testing.expectEqualStrings("200", sid);

    var dir = try std.Io.Dir.openDirAbsolute(std.testing.io, sess_abs, .{});
    defer dir.close(std.testing.io);
    var rdr = try core.session.ReplayReader.init(std.testing.allocator, dir, "200", .{});
    defer rdr.deinit();

    const ev0 = (try rdr.next()) orelse return error.TestUnexpectedResult;
    switch (ev0.data) {
        .prompt => |p| try std.testing.expectEqualStrings("old-200", p.text),
        else => return error.TestUnexpectedResult,
    }
    var saw_new = false;
    while (try rdr.next()) |ev| {
        switch (ev.data) {
            .prompt => |p| {
                if (std.mem.eql(u8, p.text, "new-turn")) saw_new = true;
            },
            else => {}, // test only inspects .prompt events
        }
    }
    try std.testing.expect(saw_new);
}

test "runtime continue reuses latest session id and appends new turn" {
    try expectLatestSessionReused(.cont);
}

test "runtime resume (-r) reuses latest session id and appends new turn" {
    try expectLatestSessionReused(.resm);
}

test "runtime explicit session path resumes that session id" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sess");
    const sess_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "sess");
    defer std.testing.allocator.free(sess_abs);

    {
        const old_file = try tmp.dir.createFile(std.testing.io, "sess/sid-1.jsonl", .{});
        defer old_file.close(std.testing.io);
        const old_ev = try core.session.encodeEventAlloc(std.testing.allocator, .{
            .at_ms = 1,
            .data = .{
                .prompt = .{ .text = "old" },
            },
        });
        defer std.testing.allocator.free(old_ev);
        try old_file.writeStreamingAll(std.testing.io, old_ev);
        try old_file.writeStreamingAll(std.testing.io, "\n");
    }

    const sid_path = try testRealPathAlloc(std.testing.allocator, tmp.dir, "sess/sid-1.jsonl");
    defer std.testing.allocator.free(sid_path);

    var cfg = cli.Run{
        .mode = .print,
        .prompt = "new",
        .session = .{ .explicit = sid_path },
        .cfg = .{
            .mode = .print,
            .model = try std.testing.allocator.dupe(u8, "m"),
            .provider = try std.testing.allocator.dupe(u8, "p"),
            .session_dir = try std.testing.allocator.dupe(u8, sess_abs),
            .provider_cmd = try std.testing.allocator.dupe(u8, "cat >/dev/null; printf 'text:ok\\nstop:done\\n'"),
        },
    };
    defer cfg.cfg.deinit(std.testing.allocator);

    var out_buf: [1024]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);
    const sid = try execWithIo(std.testing.allocator, cfg, eofReader(), &out_fbs);
    defer std.testing.allocator.free(sid);
    try std.testing.expectEqualStrings("sid-1", sid);
}

test "runtime no session mode does not persist jsonl files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sess");
    const sess_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "sess");
    defer std.testing.allocator.free(sess_abs);

    var cfg = cli.Run{
        .mode = .print,
        .prompt = "ping",
        .no_session = true,
        .cfg = .{
            .mode = .print,
            .model = try std.testing.allocator.dupe(u8, "m"),
            .provider = try std.testing.allocator.dupe(u8, "p"),
            .session_dir = try std.testing.allocator.dupe(u8, sess_abs),
            .provider_cmd = try std.testing.allocator.dupe(u8, "cat >/dev/null; printf 'text:pong\\nstop:done\\n'"),
        },
    };
    defer cfg.cfg.deinit(std.testing.allocator);

    var out_buf: [1024]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const sid = try execWithIo(std.testing.allocator, cfg, eofReader(), &out_fbs);
    defer std.testing.allocator.free(sid);

    var sess_dir = try std.Io.Dir.openDirAbsolute(std.testing.io, sess_abs, .{ .iterate = true });
    defer sess_dir.close(std.testing.io);
    var it = sess_dir.iterate();
    try std.testing.expect((try it.next(std.testing.io)) == null);
}

test "runtime tool mask filters builtins used by loop registry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sess");
    const sess_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "sess");
    defer std.testing.allocator.free(sess_abs);

    const provider_cmd =
        "req=$(cat); " ++
        "if printf '%s' \"$req\" | grep -q '\"tool_result\"'; then " ++
        "printf 'text:done\\nstop:done\\n'; " ++
        "else " ++
        "printf 'tool_call:call-1|bash|{\"cmd\":\"printf hi\"}\\nstop:tool\\n'; " ++
        "fi";

    var cfg = cli.Run{
        .mode = .print,
        .prompt = "ship",
        .tool_mask = core.tools.builtin.mask_read,
        .verbose = true,
        .cfg = .{
            .mode = .print,
            .model = try std.testing.allocator.dupe(u8, "m"),
            .provider = try std.testing.allocator.dupe(u8, "p"),
            .session_dir = try std.testing.allocator.dupe(u8, sess_abs),
            .provider_cmd = try std.testing.allocator.dupe(u8, provider_cmd),
        },
    };
    defer cfg.cfg.deinit(std.testing.allocator);

    var out_buf: [1024]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const sid = try execWithIo(
        std.testing.allocator,
        cfg,
        null,
        &out_fbs,
    );
    defer std.testing.allocator.free(sid);

    const written = out_fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "tool_result id=\"call-1\" is_err=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "tool-not-found:bash") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "stop reason=done") != null);
}

test "runtime json mode emits JSON lines for loop events" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sess");
    const sess_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "sess");
    defer std.testing.allocator.free(sess_abs);

    var cfg = cli.Run{
        .mode = .json,
        .prompt = "ping",
        .cfg = .{
            .mode = .json,
            .model = try std.testing.allocator.dupe(u8, "m"),
            .provider = try std.testing.allocator.dupe(u8, "p"),
            .session_dir = try std.testing.allocator.dupe(u8, sess_abs),
            .provider_cmd = try std.testing.allocator.dupe(u8, "cat >/dev/null; printf 'text:pong\\nstop:done\\n'"),
        },
    };
    defer cfg.cfg.deinit(std.testing.allocator);

    var out_buf: [16384]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const sid = try execWithIo(std.testing.allocator, cfg, eofReader(), &out_fbs);
    defer std.testing.allocator.free(sid);

    const written = out_fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"type\":\"session\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"type\":\"provider\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "pong") != null);
}

test "runtime print mode uses configured model and provider" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sess");
    const sess_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "sess");
    defer std.testing.allocator.free(sess_abs);

    const provider_cmd =
        "req=$(cat); " ++
        "model=$(printf '%s' \"$req\" | grep -o '\"model\":\"[^\"]*\"' | head -n1 | cut -d'\"' -f4); " ++
        "prov=$(printf '%s' \"$req\" | grep -o '\"provider\":\"[^\"]*\"' | head -n1 | cut -d'\"' -f4); " ++
        "printf 'text:model=%s provider=%s\\nstop:done\\n' \"$model\" \"$prov\"";

    var cfg = cli.Run{
        .mode = .print,
        .prompt = "ping",
        .cfg = .{
            .mode = .print,
            .model = try std.testing.allocator.dupe(u8, "cfg-model"),
            .provider = try std.testing.allocator.dupe(u8, "cfg-provider"),
            .session_dir = try std.testing.allocator.dupe(u8, sess_abs),
            .provider_cmd = try std.testing.allocator.dupe(u8, provider_cmd),
        },
    };
    defer cfg.cfg.deinit(std.testing.allocator);

    var out_buf: [2048]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const sid = try execWithIo(std.testing.allocator, cfg, eofReader(), &out_fbs);
    defer std.testing.allocator.free(sid);

    const written = out_fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "model=cfg-model provider=cfg-provider") != null);
}

test "runtime json mode uses configured model and stdin prompts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sess");
    const sess_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "sess");
    defer std.testing.allocator.free(sess_abs);

    const provider_cmd =
        "req=$(cat); " ++
        "model=$(printf '%s' \"$req\" | grep -o '\"model\":\"[^\"]*\"' | head -n1 | cut -d'\"' -f4); " ++
        "prov=$(printf '%s' \"$req\" | grep -o '\"provider\":\"[^\"]*\"' | head -n1 | cut -d'\"' -f4); " ++
        "printf 'text:model=%s provider=%s\\nstop:done\\n' \"$model\" \"$prov\"";

    var cfg = cli.Run{
        .mode = .json,
        .prompt = null,
        .cfg = .{
            .mode = .json,
            .model = try std.testing.allocator.dupe(u8, "cfg-json-model"),
            .provider = try std.testing.allocator.dupe(u8, "cfg-json-provider"),
            .session_dir = try std.testing.allocator.dupe(u8, sess_abs),
            .provider_cmd = try std.testing.allocator.dupe(u8, provider_cmd),
        },
    };
    defer cfg.cfg.deinit(std.testing.allocator);

    var in_fbs: std.Io.Reader = .fixed("from-stdin\n");
    var out_buf: [4096]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const sid = try execWithIo(
        std.testing.allocator,
        cfg,
        &in_fbs,
        &out_fbs,
    );
    defer std.testing.allocator.free(sid);

    const written = out_fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "model=cfg-json-model provider=cfg-json-provider") != null);
}

test "runtime json mode errors on empty stdin when no prompt is supplied" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sess");
    const sess_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "sess");
    defer std.testing.allocator.free(sess_abs);

    var cfg = cli.Run{
        .mode = .json,
        .prompt = null,
        .cfg = .{
            .mode = .json,
            .model = try std.testing.allocator.dupe(u8, "m"),
            .provider = try std.testing.allocator.dupe(u8, "p"),
            .session_dir = try std.testing.allocator.dupe(u8, sess_abs),
            .provider_cmd = try std.testing.allocator.dupe(u8, "cat >/dev/null; printf 'text:noop\\nstop:done\\n'"),
        },
    };
    defer cfg.cfg.deinit(std.testing.allocator);

    var out_buf: [1024]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    try std.testing.expectError(
        error.EmptyPrompt,
        execWithIo(
            std.testing.allocator,
            cfg,
            eofReader(),
            &out_fbs,
        ),
    );
}

test "execWithIo cleans orphan compact temp files on startup" {
    // Use --continue to opt into durable session, which opens sess dir
    // and cleans orphan temp files.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sess");
    {
        var f = try tmp.dir.createFile(std.testing.io, "sess/orphan.jsonl.compact.tmp", .{});
        f.close(std.testing.io);
    }
    // Need a real session file for --continue to latch onto
    {
        const sf = try tmp.dir.createFile(std.testing.io, "sess/100.jsonl", .{});
        defer sf.close(std.testing.io);
        const ev = try core.session.encodeEventAlloc(std.testing.allocator, .{
            .at_ms = 1,
            .data = .{ .prompt = .{ .text = "old" } },
        });
        defer std.testing.allocator.free(ev);
        try sf.writeStreamingAll(std.testing.io, ev);
        try sf.writeStreamingAll(std.testing.io, "\n");
    }
    const sess_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "sess");
    defer std.testing.allocator.free(sess_abs);

    var cfg = cli.Run{
        .mode = .print,
        .prompt = "ping",
        .session = .cont,
        .cfg = .{
            .mode = .print,
            .model = try std.testing.allocator.dupe(u8, "m"),
            .provider = try std.testing.allocator.dupe(u8, "p"),
            .session_dir = try std.testing.allocator.dupe(u8, sess_abs),
            .provider_cmd = try std.testing.allocator.dupe(u8, "cat >/dev/null; printf 'text:pong\\nstop:done\\n'"),
        },
    };
    defer cfg.cfg.deinit(std.testing.allocator);

    var out_buf: [2048]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);
    const sid = try execWithIo(std.testing.allocator, cfg, eofReader(), &out_fbs);
    defer std.testing.allocator.free(sid);

    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "sess/orphan.jsonl.compact.tmp", .{}));
}

test "PrintSink surfaces session write errors non-fatally" {
    var out_buf: [512]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);
    var sink = PrintSink.init(std.testing.allocator, &out_fbs);
    defer sink.deinit();

    try sink.push(.{ .provider = .{ .text = "hello" } });
    try sink.push(.{ .session_write_err = "DiskFull" });
    try std.testing.expect(std.mem.indexOf(u8, out_fbs.buffered(), "hello\n[session write failed: DiskFull]") != null);
}

test "TuiSink surfaces session write errors in transcript" {
    var ui = try tui_harness.Ui.init(std.testing.allocator, 60, 10, "m", "p");
    defer ui.deinit();

    var out_buf: [4096]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);
    var sink = TuiSink{
        .ui = &ui,
        .out = &out_fbs,
    };

    try sink.push(.{ .session_write_err = "DiskFull" });

    var found = false;
    for (ui.tr.blocks.items) |blk| {
        if (std.mem.indexOf(u8, blk.buf.items, "session write failed: DiskFull") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "runBashMode include write failure is non-fatal for denied bash" {
    const StoreImpl = struct {
        session_store: core.session.SessionStore = .{ .vt = &core.session.SessionStore.Bind(@This(), @This().append, @This().replay, @This().deinit).vt },
        fn append(_: *@This(), _: []const u8, _: core.session.Event) !void {
            return error.DiskFull;
        }
        fn replay(_: *@This(), _: []const u8) !*core.session.Reader {
            return error.Unexpected;
        }
        fn deinit(_: *@This()) void {}
    };

    var store_impl = StoreImpl{};

    var ui = try tui_harness.Ui.init(std.testing.allocator, 80, 12, "m", "p");
    defer ui.deinit();

    const noop_pol = noopPolicy();
    try runBashMode(std.testing.allocator, &ui, .{
        .cmd = "cat ~/.pz/settings.json",
        .include = true,
    }, "sid-1", &store_impl.session_store, &noop_pol);

    var saw_deny = false;
    var saw_write_err = false;
    for (ui.tr.blocks.items) |blk| {
        if (std.mem.indexOf(u8, blk.buf.items, "bash denied: protected path") != null) saw_deny = true;
        if (std.mem.indexOf(u8, blk.buf.items, "session write failed: DiskFull") != null) saw_write_err = true;
    }
    try std.testing.expect(saw_deny);
    try std.testing.expect(saw_write_err);
}

test "runBashMode include write failure is non-fatal for bash output" {
    const StoreImpl = struct {
        session_store: core.session.SessionStore = .{ .vt = &core.session.SessionStore.Bind(@This(), @This().append, @This().replay, @This().deinit).vt },
        fn append(_: *@This(), _: []const u8, _: core.session.Event) !void {
            return error.DiskFull;
        }
        fn replay(_: *@This(), _: []const u8) !*core.session.Reader {
            return error.Unexpected;
        }
        fn deinit(_: *@This()) void {}
    };

    var store_impl = StoreImpl{};

    var ui = try tui_harness.Ui.init(std.testing.allocator, 80, 12, "m", "p");
    defer ui.deinit();

    const noop_pol = noopPolicy();
    try runBashMode(std.testing.allocator, &ui, .{
        .cmd = "printf ok",
        .include = true,
    }, "sid-1", &store_impl.session_store, &noop_pol);

    var saw_ok = false;
    var saw_write_err = false;
    for (ui.tr.blocks.items) |blk| {
        if (std.mem.indexOf(u8, blk.buf.items, "ok") != null) saw_ok = true;
        if (std.mem.indexOf(u8, blk.buf.items, "session write failed: DiskFull") != null) saw_write_err = true;
    }
    try std.testing.expect(saw_ok);
    try std.testing.expect(saw_write_err);
}

test "runtime rpc mode handles session model prompt and quit commands" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sess");
    const sess_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "sess");
    defer std.testing.allocator.free(sess_abs);

    var cfg = cli.Run{
        .mode = .rpc,
        .prompt = null,
        .cfg = .{
            .mode = .rpc,
            .model = try std.testing.allocator.dupe(u8, "m"),
            .provider = try std.testing.allocator.dupe(u8, "p"),
            .session_dir = try std.testing.allocator.dupe(u8, sess_abs),
            .provider_cmd = try std.testing.allocator.dupe(u8, "cat >/dev/null; printf 'text:pong\\nstop:done\\n'"),
        },
    };
    defer cfg.cfg.deinit(std.testing.allocator);

    var in_fbs: std.Io.Reader = .fixed(
        "{\"cmd\":\"session\"}\n" ++
            "{\"cmd\":\"tools\",\"arg\":\"read,write\"}\n" ++
            "{\"cmd\":\"model\",\"arg\":\"m2\"}\n" ++
            "{\"cmd\":\"provider\",\"arg\":\"p2\"}\n" ++
            "{\"cmd\":\"prompt\",\"text\":\"ping\"}\n" ++
            "{\"cmd\":\"session\"}\n" ++
            "{\"cmd\":\"quit\"}\n",
    );
    var out_buf: [32768]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const sid = try execWithIo(
        std.testing.allocator,
        cfg,
        &in_fbs,
        &out_fbs,
    );
    defer std.testing.allocator.free(sid);

    const written = out_fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"type\":\"rpc_session\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"session_file\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"session_lines\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"cmd\":\"tools\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"tools\":\"read,write\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"cmd\":\"model\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"cmd\":\"provider\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"provider\":\"p2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"cmd\":\"prompt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"cmd\":\"quit\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"type\":\"provider\"") != null);
}

test "runtime tui slash commands execute without prompt turns" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sess");
    const sess_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "sess");
    defer std.testing.allocator.free(sess_abs);

    var cfg = cli.Run{
        .mode = .tui,
        .prompt = null,
        .cfg = .{
            .mode = .tui,
            .model = try std.testing.allocator.dupe(u8, "m"),
            .provider = try std.testing.allocator.dupe(u8, "p"),
            .session_dir = try std.testing.allocator.dupe(u8, sess_abs),
            .provider_cmd = try std.testing.allocator.dupe(u8, "cat >/dev/null; printf 'text:noop\\nstop:done\\n'"),
        },
    };
    defer cfg.cfg.deinit(std.testing.allocator);

    var in_fbs: std.Io.Reader = .fixed("/help\n/session\n/provider p2\n/tools read\n/settings\n/new\n/quit\n");
    var out_buf: [32768]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const sid = try execWithIo(
        std.testing.allocator,
        cfg,
        &in_fbs,
        &out_fbs,
    );
    defer std.testing.allocator.free(sid);

    const written = out_fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "/help") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "/session") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "/model") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "/tools") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "provider set to p2") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "tools set to read") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "File:") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "ID:") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Messages") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "new session") != null);
}

test "discoverSkills returns skill metadata with source" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, ".pz/skills/release");
    var skill = try tmp.dir.createFile(std.testing.io, ".pz/skills/release/SKILL.md", .{});
    defer skill.close(std.testing.io);
    try skill.writeStreamingAll(std.testing.io,
        \\---
        \\name: release
        \\description: release pz
        \\user_invocable: true
        \\---
        \\Body
        \\
    );

    var root = try tmp.dir.openDir(std.testing.io, ".", .{});
    defer root.close(std.testing.io);
    var guard = try path_guard.CwdGuard.enter(root);
    defer guard.deinit();
    var pol = try RuntimePolicy.load(std.testing.allocator, defaultIo(), null);
    defer pol.deinit();

    const skills = try discoverSkills(std.testing.allocator, null);
    defer core_skill.freeSkills(std.testing.allocator, skills);

    const info = core_skill.findByDirName(skills, "release") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("release pz", info.meta.description);
    try std.testing.expectEqual(core_skill.Source.project, info.source);
}

test "handleSlashCommand falls through for user-invocable skills" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, ".pz/skills/release");
    var skill = try tmp.dir.createFile(std.testing.io, ".pz/skills/release/SKILL.md", .{});
    defer skill.close(std.testing.io);
    try skill.writeStreamingAll(std.testing.io,
        \\---
        \\name: release
        \\description: release pz
        \\user_invocable: true
        \\---
        \\Body
        \\
    );

    var root = try tmp.dir.openDir(std.testing.io, ".", .{});
    defer root.close(std.testing.io);
    var guard = try path_guard.CwdGuard.enter(root);
    defer guard.deinit();
    var pol = try RuntimePolicy.load(std.testing.allocator, defaultIo(), null);
    defer pol.deinit();

    var sid = try std.testing.allocator.dupe(u8, "sid");
    defer std.testing.allocator.free(sid);
    var model: []const u8 = "m";
    var provider: []const u8 = "p";
    var model_owned: ?[]u8 = null;
    defer if (model_owned) |buf| std.testing.allocator.free(buf);
    var provider_owned: ?[]u8 = null;
    defer if (provider_owned) |buf| std.testing.allocator.free(buf);
    var tools_rt = core.tools.builtin.Runtime.init(.{ .alloc = std.testing.allocator });
    defer tools_rt.deinit();
    var bg_mgr = try bg.Manager.init(std.testing.allocator);
    defer bg_mgr.deinit();
    var ctl_audit = RuntimeCtlAudit{ .hooks = .{} };
    var out_buf: [256]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const got = try handleSlashCommand(
        std.testing.allocator,
        "/release",
        &sid,
        &model,
        &model_owned,
        &provider,
        &provider_owned,
        &pol,
        &tools_rt,
        &bg_mgr,
        null,
        true,
        null,
        &out_fbs,
        .{},
        &ctl_audit,
        null,
    );

    try std.testing.expectEqual(CmdRes.unhandled, got);
    try std.testing.expectEqual(@as(usize, 0), out_fbs.buffered().len);
}

test "handleSlashCommand blocks non-user-invocable skills" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, ".pz/skills/release");
    var skill = try tmp.dir.createFile(std.testing.io, ".pz/skills/release/SKILL.md", .{});
    defer skill.close(std.testing.io);
    try skill.writeStreamingAll(std.testing.io,
        \\---
        \\name: release
        \\description: release pz
        \\user_invocable: false
        \\---
        \\Body
        \\
    );

    var root = try tmp.dir.openDir(std.testing.io, ".", .{});
    defer root.close(std.testing.io);
    var guard = try path_guard.CwdGuard.enter(root);
    defer guard.deinit();
    var pol = try RuntimePolicy.load(std.testing.allocator, defaultIo(), null);
    defer pol.deinit();

    var sid = try std.testing.allocator.dupe(u8, "sid");
    defer std.testing.allocator.free(sid);
    var model: []const u8 = "m";
    var provider: []const u8 = "p";
    var model_owned: ?[]u8 = null;
    defer if (model_owned) |buf| std.testing.allocator.free(buf);
    var provider_owned: ?[]u8 = null;
    defer if (provider_owned) |buf| std.testing.allocator.free(buf);
    var tools_rt = core.tools.builtin.Runtime.init(.{ .alloc = std.testing.allocator });
    defer tools_rt.deinit();
    var bg_mgr = try bg.Manager.init(std.testing.allocator);
    defer bg_mgr.deinit();
    var ctl_audit = RuntimeCtlAudit{ .hooks = .{} };
    var out_buf: [256]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const got = try handleSlashCommand(
        std.testing.allocator,
        "/release",
        &sid,
        &model,
        &model_owned,
        &provider,
        &provider_owned,
        &pol,
        &tools_rt,
        &bg_mgr,
        null,
        true,
        null,
        &out_fbs,
        .{},
        &ctl_audit,
        null,
    );

    try std.testing.expectEqual(CmdRes.handled, got);
    try std.testing.expect(std.mem.indexOf(u8, out_fbs.buffered(), "skill blocked: /release") != null);
}

test "TurnCtx.run binds approval context for destructive tools" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root = try tmp.dir.openDir(std.testing.io, ".", .{});
    defer root.close(std.testing.io);
    var guard = try path_guard.CwdGuard.enter(root);
    defer guard.deinit();
    var pol = try RuntimePolicy.load(std.testing.allocator, defaultIo(), null);
    defer pol.deinit();

    const cwd = try testRealPathAlloc(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(cwd);

    const steps = [_]provider_mock.Step{
        .{
            .ev = .{ .tool_call = .{
                .id = "call-write",
                .name = "write",
                .args = "{\"path\":\"out.txt\",\"text\":\"hello\"}",
            } },
        },
        .{
            .ev = .{ .stop = .{ .reason = .done } },
        },
    };
    var scripted = try provider_mock.ScriptedProvider.init(steps[0..]);
    defer scripted.deinit();

    const ReaderImpl = struct {
        reader: core.session.Reader = .{ .vt = &core.session.Reader.Bind(@This(), @This().next, @This().deinit).vt },
        fn next(_: *@This()) !?core.session.Event {
            return null;
        }

        fn deinit(_: *@This()) void {}
    };

    const StoreImpl = struct {
        session_store: core.session.SessionStore = .{ .vt = &core.session.SessionStore.Bind(@This(), @This().append, @This().replay, @This().deinit).vt },
        rdr: ReaderImpl = .{},

        fn append(_: *@This(), _: []const u8, _: core.session.Event) !void {}

        fn replay(self: *@This(), _: []const u8) !*core.session.Reader {
            return &self.rdr.reader;
        }

        fn deinit(_: *@This()) void {}
    };

    const ModeImpl = struct {
        mode_sink: core.loop.ModeSink = .{ .vt = &core.loop.ModeSink.Bind(@This(), @This().push).vt },
        fn push(_: *@This(), _: core.loop.ModeEv) !void {}
    };

    const ApproverImpl = struct {
        approver: core.loop.Approver = .{ .vt = &core.loop.Approver.Bind(@This(), @This().check).vt },
        cached: bool = true,
        sid: []const u8 = "",
        cwd: []const u8 = "",
        policy_hash: []const u8 = "",

        fn check(self: *@This(), key: core.loop.CmdCache.Key, cached: bool) !void {
            self.cached = cached;
            self.sid = switch (key.life) {
                .session => |sid| sid,
                .expires_at_ms => return error.TestUnexpectedResult,
            };
            self.cwd = switch (key.loc) {
                .cwd => |loc| loc,
                .repo_root => return error.TestUnexpectedResult,
            };
            self.policy_hash = switch (key.policy) {
                .hash => |hash| hash,
                .version => return error.TestUnexpectedResult,
            };
        }
    };

    var store_impl = StoreImpl{};
    var mode_impl = ModeImpl{};
    var tools_rt = core.tools.builtin.Runtime.init(.{ .alloc = std.testing.allocator });
    defer tools_rt.deinit();
    var cmd_cache = core.loop.CmdCache.init(std.testing.allocator);
    defer cmd_cache.deinit();
    try cmd_cache.add(.{
        .tool = .write,
        .cmd = "{\"path\":\"out.txt\",\"text\":\"hello\"}",
        .loc = .{ .cwd = cwd },
        .policy = .{ .hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" },
        .life = .{ .session = "sid-rt" },
    });
    var approver_impl = ApproverImpl{};

    const tctx = TurnCtx{
        .alloc = std.testing.allocator,
        .provider = &scripted.provider,
        .store = &store_impl.session_store,
        .pol = &pol,
        .tools_rt = &tools_rt,
        .mode = &mode_impl.mode_sink,
        .max_turns = 1,
        .cmd_cache = &cmd_cache,
        .approval_bind = .{ .hash = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" },
        .approval_loc = .{ .cwd = cwd },
        .approver = &approver_impl.approver,
    };

    try tctx.run(.{
        .sid = "sid-rt",
        .prompt = "test",
        .model = "m",
    });
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};
    const snap = try std.fmt.allocPrint(
        std.testing.allocator,
        "cached={} sid={s} cwd_match={} policy_hash={s}",
        .{
            approver_impl.cached,
            approver_impl.sid,
            std.mem.eql(u8, cwd, approver_impl.cwd),
            approver_impl.policy_hash,
        },
    );
    defer std.testing.allocator.free(snap);
    try oh.snap(@src(),
        \\[]u8
        \\  "cached=false sid=sid-rt cwd_match=true policy_hash=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    ).expectEqual(snap);
}

test "handleSlashCommand blocks builtins under verified policy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeRuntimePolicy(tmp.dir, .{
        .rules = &.{
            .{ .pattern = "runtime/cmd/share", .effect = .deny },
            .{ .pattern = "runtime/cmd/*", .effect = .allow },
        },
    });

    var root = try tmp.dir.openDir(std.testing.io, ".", .{});
    defer root.close(std.testing.io);
    var guard = try path_guard.CwdGuard.enter(root);
    defer guard.deinit();

    var pol = try RuntimePolicy.load(std.testing.allocator, defaultIo(), null);
    defer pol.deinit();

    var sid = try std.testing.allocator.dupe(u8, "sid");
    defer std.testing.allocator.free(sid);
    var model: []const u8 = "m";
    var provider: []const u8 = "p";
    var model_owned: ?[]u8 = null;
    defer if (model_owned) |buf| std.testing.allocator.free(buf);
    var provider_owned: ?[]u8 = null;
    defer if (provider_owned) |buf| std.testing.allocator.free(buf);
    var tools_rt = core.tools.builtin.Runtime.init(.{ .alloc = std.testing.allocator });
    defer tools_rt.deinit();
    var bg_mgr = try bg.Manager.init(std.testing.allocator);
    defer bg_mgr.deinit();
    var ctl_audit = RuntimeCtlAudit{ .hooks = .{} };
    var out_buf: [256]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const got = try handleSlashCommand(
        std.testing.allocator,
        "/share",
        &sid,
        &model,
        &model_owned,
        &provider,
        &provider_owned,
        &pol,
        &tools_rt,
        &bg_mgr,
        null,
        true,
        null,
        &out_fbs,
        .{},
        &ctl_audit,
        null,
    );

    try std.testing.expectEqual(CmdRes.handled, got);
    try std.testing.expect(std.mem.indexOf(u8, out_fbs.buffered(), "blocked by policy: /share") != null);
}

test "handleSlashCommand export share and upgrade emit audited redacted records" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sess");
    const events = [_]core.session.Event{
        .{
            .at_ms = 1,
            .data = .{ .prompt = .{ .text = "authorization: bearer sk-live-secret" } },
        },
        .{
            .at_ms = 2,
            .data = .{ .text = .{ .text = "<script>alert(1)</script>" } },
        },
        .{
            .at_ms = 3,
            .data = .{ .stop = .{ .reason = .done } },
        },
    };
    try writeSessionEventsFile(tmp, "sess/100.jsonl", &events);

    var root = try tmp.dir.openDir(std.testing.io, ".", .{});
    defer root.close(std.testing.io);
    var guard = try path_guard.CwdGuard.enter(root);
    defer guard.deinit();

    var pol = try RuntimePolicy.load(std.testing.allocator, defaultIo(), null);
    defer pol.deinit();

    const root_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(root_abs);
    const sess_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "sess");
    defer std.testing.allocator.free(sess_abs);

    var sid = try std.testing.allocator.dupe(u8, "100");
    defer std.testing.allocator.free(sid);
    var model: []const u8 = "m";
    var provider: []const u8 = "p";
    var model_owned: ?[]u8 = null;
    defer if (model_owned) |buf| std.testing.allocator.free(buf);
    var provider_owned: ?[]u8 = null;
    defer if (provider_owned) |buf| std.testing.allocator.free(buf);
    var tools_rt = core.tools.builtin.Runtime.init(.{ .alloc = std.testing.allocator });
    defer tools_rt.deinit();
    var bg_mgr = try bg.Manager.init(std.testing.allocator);
    defer bg_mgr.deinit();
    var rows = AuditRows{};
    defer rows.deinit(std.testing.allocator);
    var ctl_audit = RuntimeCtlAudit{ .hooks = .{
        .audit_emitter = &rows.emitter,
        .now_ms = struct {
            fn f() i64 {
                return 999;
            }
        }.f,
        .share_gist = struct {
            fn ok(alloc: std.mem.Allocator, _: std.Io, _: []const u8, _: *const RuntimePolicy) ![]u8 {
                return try alloc.dupe(u8, "https://gist.github.test/private/secret-url");
            }
        }.ok,
        .run_upgrade = struct {
            fn ok(alloc: std.mem.Allocator, _: update_mod.AuditHooks) !update_mod.Outcome {
                return .{
                    .ok = true,
                    .msg = try alloc.dupe(u8, "already up to date\n"),
                };
            }
        }.ok,
    } };
    var out_buf: [1024]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    _ = try handleSlashCommand(
        std.testing.allocator,
        "/export team.md",
        &sid,
        &model,
        &model_owned,
        &provider,
        &provider_owned,
        &pol,
        &tools_rt,
        &bg_mgr,
        sess_abs,
        false,
        null,
        &out_fbs,
        ctl_audit.hooks,
        &ctl_audit,
        null,
    );

    ctl_audit.hooks.share_gist = struct {
        fn fail(_: std.mem.Allocator, _: std.Io, _: []const u8, _: *const RuntimePolicy) ![]u8 {
            return error.GistFailed;
        }
    }.fail;

    _ = try handleSlashCommand(
        std.testing.allocator,
        "/share",
        &sid,
        &model,
        &model_owned,
        &provider,
        &provider_owned,
        &pol,
        &tools_rt,
        &bg_mgr,
        sess_abs,
        false,
        null,
        &out_fbs,
        ctl_audit.hooks,
        &ctl_audit,
        null,
    );

    _ = try handleSlashCommand(
        std.testing.allocator,
        "/upgrade",
        &sid,
        &model,
        &model_owned,
        &provider,
        &provider_owned,
        &pol,
        &tools_rt,
        &bg_mgr,
        sess_abs,
        false,
        null,
        &out_fbs,
        ctl_audit.hooks,
        &ctl_audit,
        null,
    );

    ctl_audit.hooks.run_upgrade = struct {
        fn fail(alloc: std.mem.Allocator, _: update_mod.AuditHooks) !update_mod.Outcome {
            return .{
                .ok = false,
                .msg = try alloc.dupe(u8, "upgrade blocked by policy\n"),
            };
        }
    }.fail;

    _ = try handleSlashCommand(
        std.testing.allocator,
        "/upgrade",
        &sid,
        &model,
        &model_owned,
        &provider,
        &provider_owned,
        &pol,
        &tools_rt,
        &bg_mgr,
        sess_abs,
        false,
        null,
        &out_fbs,
        ctl_audit.hooks,
        &ctl_audit,
        null,
    );

    const joined = try std.mem.join(std.testing.allocator, "\n", rows.rows.items);
    defer std.testing.allocator.free(joined);
    const export_abs = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "team.md" });
    defer std.testing.allocator.free(export_abs);
    const share_abs = try std.fs.path.join(std.testing.allocator, &.{ sess_abs, "100.md" });
    defer std.testing.allocator.free(share_abs);
    const rkey_100 = core.audit.RedactKey.fromSid("100");
    const rkey_rt = core.audit.RedactKey.fromSid("runtime");
    const export_tag_100 = try core.audit.redactKeyedAlloc(std.testing.allocator, export_abs, .mask, rkey_100);
    defer std.testing.allocator.free(export_tag_100);
    const export_tag_rt = try core.audit.redactKeyedAlloc(std.testing.allocator, export_abs, .mask, rkey_rt);
    defer std.testing.allocator.free(export_tag_rt);
    const share_tag_100 = try core.audit.redactKeyedAlloc(std.testing.allocator, share_abs, .mask, rkey_100);
    defer std.testing.allocator.free(share_tag_100);
    const n1 = try std.mem.replaceOwned(u8, std.testing.allocator, joined, export_tag_100, "[mask:EXPORT_PATH]");
    defer std.testing.allocator.free(n1);
    const n2 = try std.mem.replaceOwned(u8, std.testing.allocator, n1, export_tag_rt, "[mask:EXPORT_PATH]");
    defer std.testing.allocator.free(n2);
    const norm = try std.mem.replaceOwned(u8, std.testing.allocator, n2, share_tag_100, "[mask:SHARE_PATH]");
    defer std.testing.allocator.free(norm);
    try oh.snap(@src(),
        \\[]u8
        \\  "{"v":1,"ts_ms":999,"sid":"runtime","seq":1,"kind":"tool","sev":"info","out":"ok","actor":{"kind":"sys"},"res":{"kind":"file","name":{"text":"session-export","vis":"pub"},"op":"export"},"msg":{"text":"runtime control start","vis":"pub"},"data":{"name":{"text":"runtime","vis":"pub"},"call_id":"export","argv":{"text":"[mask:a69ccd97609ac644]","vis":"mask"}},"attrs":[]}
        \\{"v":1,"ts_ms":999,"sid":"100","seq":1,"kind":"ctrl","sev":"info","out":"ok","actor":{"kind":"sys"},"res":{"kind":"file","name":{"text":"[mask:EXPORT_PATH]","vis":"mask"},"op":"write"},"msg":{"text":"export start","vis":"pub"},"data":{"op":"export","target":{"text":"100","vis":"pub"},"detail":{"text":"[mask:EXPORT_PATH]","vis":"mask"}},"attrs":[]}
        \\{"v":1,"ts_ms":999,"sid":"100","seq":2,"kind":"ctrl","sev":"info","out":"ok","actor":{"kind":"sys"},"res":{"kind":"file","name":{"text":"[mask:EXPORT_PATH]","vis":"mask"},"op":"write"},"msg":{"text":"export complete","vis":"pub"},"data":{"op":"export","target":{"text":"100","vis":"pub"},"detail":{"text":"[mask:EXPORT_PATH]","vis":"mask"}},"attrs":[]}
        \\{"v":1,"ts_ms":999,"sid":"runtime","seq":2,"kind":"tool","sev":"notice","out":"ok","actor":{"kind":"sys"},"res":{"kind":"file","name":{"text":"session-export","vis":"pub"},"op":"export"},"msg":{"text":"runtime control success","vis":"pub"},"data":{"name":{"text":"runtime","vis":"pub"},"call_id":"export","argv":{"text":"[mask:a69ccd97609ac644]","vis":"mask"}},"attrs":[{"key":"path","vis":"mask","ty":"str","val":"[mask:EXPORT_PATH]"}]}
        \\{"v":1,"ts_ms":999,"sid":"runtime","seq":3,"kind":"tool","sev":"info","out":"ok","actor":{"kind":"sys"},"res":{"kind":"net","name":{"text":"gist","vis":"pub"},"op":"share"},"msg":{"text":"runtime control start","vis":"pub"},"data":{"name":{"text":"runtime","vis":"pub"},"call_id":"share"},"attrs":[]}
        \\{"v":1,"ts_ms":999,"sid":"100","seq":1,"kind":"ctrl","sev":"info","out":"ok","actor":{"kind":"sys"},"res":{"kind":"file","name":{"text":"[mask:SHARE_PATH]","vis":"mask"},"op":"write"},"msg":{"text":"export start","vis":"pub"},"data":{"op":"export","target":{"text":"100","vis":"pub"},"detail":{"text":"[mask:SHARE_PATH]","vis":"mask"}},"attrs":[]}
        \\{"v":1,"ts_ms":999,"sid":"100","seq":2,"kind":"ctrl","sev":"info","out":"ok","actor":{"kind":"sys"},"res":{"kind":"file","name":{"text":"[mask:SHARE_PATH]","vis":"mask"},"op":"write"},"msg":{"text":"export complete","vis":"pub"},"data":{"op":"export","target":{"text":"100","vis":"pub"},"detail":{"text":"[mask:SHARE_PATH]","vis":"mask"}},"attrs":[]}
        \\{"v":1,"ts_ms":999,"sid":"runtime","seq":4,"kind":"tool","sev":"err","out":"fail","actor":{"kind":"sys"},"res":{"kind":"net","name":{"text":"gist","vis":"pub"},"op":"share"},"msg":{"text":"[mask:c85c93dae75e2c92]","vis":"mask"},"data":{"name":{"text":"runtime","vis":"pub"},"call_id":"share"},"attrs":[]}
        \\{"v":1,"ts_ms":999,"sid":"runtime","seq":5,"kind":"tool","sev":"info","out":"ok","actor":{"kind":"sys"},"res":{"kind":"cmd","name":{"text":"upgrade","vis":"pub"},"op":"upgrade"},"msg":{"text":"runtime control start","vis":"pub"},"data":{"name":{"text":"runtime","vis":"pub"},"call_id":"upgrade"},"attrs":[]}
        \\{"v":1,"ts_ms":999,"sid":"runtime","seq":6,"kind":"tool","sev":"notice","out":"ok","actor":{"kind":"sys"},"res":{"kind":"cmd","name":{"text":"upgrade","vis":"pub"},"op":"upgrade"},"msg":{"text":"runtime control success","vis":"pub"},"data":{"name":{"text":"runtime","vis":"pub"},"call_id":"upgrade"},"attrs":[]}
        \\{"v":1,"ts_ms":999,"sid":"runtime","seq":7,"kind":"tool","sev":"info","out":"ok","actor":{"kind":"sys"},"res":{"kind":"cmd","name":{"text":"upgrade","vis":"pub"},"op":"upgrade"},"msg":{"text":"runtime control start","vis":"pub"},"data":{"name":{"text":"runtime","vis":"pub"},"call_id":"upgrade"},"attrs":[]}
        \\{"v":1,"ts_ms":999,"sid":"runtime","seq":8,"kind":"tool","sev":"err","out":"fail","actor":{"kind":"sys"},"res":{"kind":"cmd","name":{"text":"upgrade","vis":"pub"},"op":"upgrade"},"msg":{"text":"[mask:72a5bdd8c44d96df]","vis":"mask"},"data":{"name":{"text":"runtime","vis":"pub"},"call_id":"upgrade"},"attrs":[]}"
    ).expectEqual(norm);
}

test "runtime tui bg command starts and lists background jobs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sess");
    const sess_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "sess");
    defer std.testing.allocator.free(sess_abs);

    var cfg = cli.Run{
        .mode = .tui,
        .prompt = null,
        .cfg = .{
            .mode = .tui,
            .model = try std.testing.allocator.dupe(u8, "m"),
            .provider = try std.testing.allocator.dupe(u8, "p"),
            .session_dir = try std.testing.allocator.dupe(u8, sess_abs),
            .provider_cmd = try std.testing.allocator.dupe(u8, "cat >/dev/null; printf 'text:noop\\nstop:done\\n'"),
        },
    };
    defer cfg.cfg.deinit(std.testing.allocator);

    var in_fbs: std.Io.Reader = .fixed("/bg run sleep 1\n/bg list\n/quit\n");
    var out_buf: [32768]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const sid = try execWithIo(
        std.testing.allocator,
        cfg,
        &in_fbs,
        &out_fbs,
    );
    defer std.testing.allocator.free(sid);

    const written = out_fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "bg started id=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "id pid state code log cmd") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "bg L1 R1 D0") != null);
}

test "runtime snapshot for slash + bg flow" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "sess");
    const sess_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "sess");
    defer std.testing.allocator.free(sess_abs);

    var cfg = cli.Run{
        .mode = .tui,
        .prompt = null,
        .cfg = .{
            .mode = .tui,
            .model = try std.testing.allocator.dupe(u8, "m"),
            .provider = try std.testing.allocator.dupe(u8, "p"),
            .session_dir = try std.testing.allocator.dupe(u8, sess_abs),
            .provider_cmd = try std.testing.allocator.dupe(u8, "cat >/dev/null; printf 'text:noop\\nstop:done\\n'"),
        },
    };
    defer cfg.cfg.deinit(std.testing.allocator);

    var in_fbs: std.Io.Reader = .fixed("/help\n/tools all\n/bg run sleep 1\n/bg list\n/quit\n");
    var out_buf: [32768]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const sid = try execWithIo(
        std.testing.allocator,
        cfg,
        &in_fbs,
        &out_fbs,
    );
    defer std.testing.allocator.free(sid);

    const written = out_fbs.buffered();
    const Snap = struct {
        has_help: bool,
        has_tools_set: bool,
        has_bg_started: bool,
        has_bg_list_header: bool,
        has_bg_footer: bool,
    };
    try oh.snap(@src(),
        \\app.runtime.test.runtime snapshot for slash + bg flow.Snap
        \\  .has_help: bool = true
        \\  .has_tools_set: bool = true
        \\  .has_bg_started: bool = true
        \\  .has_bg_list_header: bool = true
        \\  .has_bg_footer: bool = true
    ).expectEqual(Snap{
        .has_help = std.mem.indexOf(u8, written, "/help") != null,
        .has_tools_set = std.mem.indexOf(u8, written, "tools set to read,write,bash,edit,grep,find,ls,agent,ask,skill") != null,
        .has_bg_started = std.mem.indexOf(u8, written, "bg started id=1") != null,
        .has_bg_list_header = std.mem.indexOf(u8, written, "id pid state code log cmd") != null,
        .has_bg_footer = std.mem.indexOf(u8, written, "bg L1 R1 D0") != null,
    });
}

test "runtime rpc accepts type envelope aliases and echoes ids" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sess");
    const sess_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "sess");
    defer std.testing.allocator.free(sess_abs);

    var cfg = cli.Run{
        .mode = .rpc,
        .prompt = null,
        .cfg = .{
            .mode = .rpc,
            .model = try std.testing.allocator.dupe(u8, "m"),
            .provider = try std.testing.allocator.dupe(u8, "p"),
            .session_dir = try std.testing.allocator.dupe(u8, sess_abs),
            .provider_cmd = try std.testing.allocator.dupe(u8, "cat >/dev/null; printf 'text:pong\\nstop:done\\n'"),
        },
    };
    defer cfg.cfg.deinit(std.testing.allocator);

    var in_fbs: std.Io.Reader = .fixed(
        "{\"id\":\"1\",\"type\":\"get_state\"}\n" ++
            "{\"id\":\"2\",\"type\":\"set_model\",\"provider\":\"p2\",\"model_id\":\"m2\"}\n" ++
            "{\"id\":\"3\",\"type\":\"get_commands\"}\n" ++
            "{\"id\":\"4\",\"type\":\"new_session\"}\n" ++
            "{\"id\":\"5\",\"type\":\"quit\"}\n",
    );
    var out_buf: [32768]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const sid = try execWithIo(
        std.testing.allocator,
        cfg,
        &in_fbs,
        &out_fbs,
    );
    defer std.testing.allocator.free(sid);

    const written = out_fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"id\":\"1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"id\":\"2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"id\":\"3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"id\":\"4\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"id\":\"5\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"cmd\":\"set_model\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"provider\":\"p2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"type\":\"rpc_commands\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"cmd\":\"new_session\"") != null);
}

test "runtime rpc bg command starts lists and stops jobs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sess");
    const sess_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "sess");
    defer std.testing.allocator.free(sess_abs);

    var cfg = cli.Run{
        .mode = .rpc,
        .prompt = null,
        .cfg = .{
            .mode = .rpc,
            .model = try std.testing.allocator.dupe(u8, "m"),
            .provider = try std.testing.allocator.dupe(u8, "p"),
            .session_dir = try std.testing.allocator.dupe(u8, sess_abs),
            .provider_cmd = try std.testing.allocator.dupe(u8, "cat >/dev/null; printf 'text:noop\\nstop:done\\n'"),
        },
    };
    defer cfg.cfg.deinit(std.testing.allocator);

    var in_fbs: std.Io.Reader = .fixed(
        "{\"id\":\"1\",\"cmd\":\"bg\",\"arg\":\"run sleep 1\"}\n" ++
            "{\"id\":\"2\",\"cmd\":\"bg\",\"arg\":\"list\"}\n" ++
            "{\"id\":\"3\",\"cmd\":\"bg\",\"arg\":\"stop 1\"}\n" ++
            "{\"id\":\"4\",\"cmd\":\"quit\"}\n",
    );
    var out_buf: [32768]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const sid = try execWithIo(
        std.testing.allocator,
        cfg,
        &in_fbs,
        &out_fbs,
    );
    defer std.testing.allocator.free(sid);

    const written = out_fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"type\":\"rpc_bg\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "bg started id=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "id pid state code log cmd") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, written, "bg stop sent id=1") != null or
            std.mem.indexOf(u8, written, "bg already done id=1") != null,
    );
}

test "runtime rpc auth commands reject direct login and audit logout records" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sess");
    try tmp.dir.createDirPath(std.testing.io, "home");
    {
        var bad = try tmp.dir.createFile(std.testing.io, "home-bad", .{});
        bad.close(std.testing.io);
    }
    const sess_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "sess");
    defer std.testing.allocator.free(sess_abs);
    const home_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "home");
    defer std.testing.allocator.free(home_abs);
    const bad_home_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "home-bad");
    defer std.testing.allocator.free(bad_home_abs);

    var cfg = cli.Run{
        .mode = .rpc,
        .prompt = null,
        .cfg = .{
            .mode = .rpc,
            .model = try std.testing.allocator.dupe(u8, "m"),
            .provider = try std.testing.allocator.dupe(u8, "openai"),
            .session_dir = try std.testing.allocator.dupe(u8, sess_abs),
            .provider_cmd = try std.testing.allocator.dupe(u8, "cat >/dev/null; printf 'text:noop\\nstop:done\\n'"),
        },
    };
    defer cfg.cfg.deinit(std.testing.allocator);

    var in_fbs: std.Io.Reader = .fixed(
        "{\"id\":\"1\",\"cmd\":\"login\",\"provider\":\"openai\",\"arg\":\"sk-openai-secret\"}\n" ++
            "{\"id\":\"2\",\"cmd\":\"logout\",\"provider\":\"openai\"}\n" ++
            "{\"id\":\"3\",\"cmd\":\"quit\"}\n",
    );
    var out_buf: [32768]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);
    var rows = AuditRows{};
    defer rows.deinit(std.testing.allocator);

    const sid = try execWithIoHooks(
        std.testing.allocator,
        cfg,
        &in_fbs,
        &out_fbs,
        .{
            .audit_emitter = &rows.emitter,
            .now_ms = struct {
                fn f() i64 {
                    return 321;
                }
            }.f,
            .auth_home = home_abs,
        },
    );
    defer std.testing.allocator.free(sid);

    const written = out_fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"type\":\"rpc_auth\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "direct provider login disabled by policy") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "PZ_PROVIDER_CMD") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "API key saved for openai") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "logged out of openai") != null);

    var fail_cfg = cli.Run{
        .mode = .rpc,
        .prompt = null,
        .cfg = .{
            .mode = .rpc,
            .model = try std.testing.allocator.dupe(u8, "m"),
            .provider = try std.testing.allocator.dupe(u8, "openai"),
            .session_dir = try std.testing.allocator.dupe(u8, sess_abs),
            .provider_cmd = try std.testing.allocator.dupe(u8, "cat >/dev/null; printf 'text:noop\\nstop:done\\n'"),
        },
    };
    defer fail_cfg.cfg.deinit(std.testing.allocator);

    var fail_in_fbs: std.Io.Reader = .fixed(
        "{\"id\":\"4\",\"cmd\":\"login\",\"provider\":\"openai\",\"arg\":\"sk-openai-secret\"}\n" ++
            "{\"id\":\"5\",\"cmd\":\"quit\"}\n",
    );
    var fail_out_buf: [32768]u8 = undefined;
    var fail_out_fbs: std.Io.Writer = .fixed(&fail_out_buf);

    const fail_sid = try execWithIoHooks(
        std.testing.allocator,
        fail_cfg,
        &fail_in_fbs,
        &fail_out_fbs,
        .{
            .audit_emitter = &rows.emitter,
            .now_ms = struct {
                fn f() i64 {
                    return 321;
                }
            }.f,
            .auth_home = bad_home_abs,
        },
    );
    defer std.testing.allocator.free(fail_sid);

    const fail_written = fail_out_fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, fail_written, "\"type\":\"rpc_auth\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fail_written, "direct provider login disabled by policy") != null);
    try std.testing.expect(std.mem.indexOf(u8, fail_written, "\"type\":\"rpc_error\"") == null);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const trace = try auditTraceSnap(arena.allocator(), rows.rows.items);
    var saw_save_api_key = false;
    var saw_logout = false;
    for (trace) |entry| {
        if (entry.op) |op| {
            if (std.mem.eql(u8, op, "save_api_key")) saw_save_api_key = true;
            if (std.mem.eql(u8, op, "logout")) saw_logout = true;
        }
    }
    try std.testing.expect(!saw_save_api_key);
    try std.testing.expect(saw_logout);
}

test "runtime rpc bg commands emit audited redacted control records" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sess");
    const sess_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "sess");
    defer std.testing.allocator.free(sess_abs);

    var cfg = cli.Run{
        .mode = .rpc,
        .prompt = null,
        .cfg = .{
            .mode = .rpc,
            .model = try std.testing.allocator.dupe(u8, "m"),
            .provider = try std.testing.allocator.dupe(u8, "p"),
            .session_dir = try std.testing.allocator.dupe(u8, sess_abs),
            .provider_cmd = try std.testing.allocator.dupe(u8, "cat >/dev/null; printf 'text:noop\\nstop:done\\n'"),
        },
    };
    defer cfg.cfg.deinit(std.testing.allocator);

    var in_fbs: std.Io.Reader = .fixed(
        "{\"id\":\"1\",\"cmd\":\"bg\",\"arg\":\"run printf done\"}\n" ++
            "{\"id\":\"2\",\"cmd\":\"bg\",\"arg\":\"list\"}\n" ++
            "{\"id\":\"3\",\"cmd\":\"bg\",\"arg\":\"stop 42\"}\n" ++
            "{\"id\":\"4\",\"cmd\":\"quit\"}\n",
    );
    var out_buf: [32768]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);
    var rows = AuditRows{};
    defer rows.deinit(std.testing.allocator);

    const sid = try execWithIoHooks(
        std.testing.allocator,
        cfg,
        &in_fbs,
        &out_fbs,
        .{
            .audit_emitter = &rows.emitter,
            .now_ms = struct {
                fn f() i64 {
                    return 654;
                }
            }.f,
        },
    );
    defer std.testing.allocator.free(sid);

    const written = out_fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"type\":\"rpc_bg\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "bg started id=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "bg not found id=42") != null);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const trace = try auditTraceSnap(arena.allocator(), rows.rows.items);
    try oh.snap(@src(),
        \\[]app.runtime.AuditEntrySnap
        \\  [0]: app.runtime.AuditEntrySnap
        \\    .sid: []const u8
        \\      "bg"
        \\    .seq: u64 = 1
        \\    .kind: core.audit.EventKind
        \\      .tool
        \\    .severity: core.audit.Severity
        \\      .info
        \\    .outcome: core.audit.Outcome
        \\      .ok
        \\    .res_kind: ?core.audit.ResourceKind
        \\      .cmd
        \\    .res_name: ?[]const u8
        \\      "bg"
        \\    .op: ?[]const u8
        \\      "drain"
        \\    .msg: ?[]const u8
        \\      "bg control start"
        \\    .data_name: ?[]const u8
        \\      "bg"
        \\    .call_id: ?[]const u8
        \\      "drain"
        \\    .auth_mech: ?[]const u8
        \\      null
        \\    .attrs: []const app.runtime.AuditAttrSnap
        \\      (empty)
        \\  [1]: app.runtime.AuditEntrySnap
        \\    .sid: []const u8
        \\      "bg"
        \\    .seq: u64 = 2
        \\    .kind: core.audit.EventKind
        \\      .tool
        \\    .severity: core.audit.Severity
        \\      .info
        \\    .outcome: core.audit.Outcome
        \\      .ok
        \\    .res_kind: ?core.audit.ResourceKind
        \\      .cmd
        \\    .res_name: ?[]const u8
        \\      "bg"
        \\    .op: ?[]const u8
        \\      "drain"
        \\    .msg: ?[]const u8
        \\      "bg control success"
        \\    .data_name: ?[]const u8
        \\      "bg"
        \\    .call_id: ?[]const u8
        \\      "drain"
        \\    .auth_mech: ?[]const u8
        \\      null
        \\    .attrs: []const app.runtime.AuditAttrSnap
        \\      [0]: app.runtime.AuditAttrSnap
        \\        .key: []const u8
        \\          "count"
        \\        .vis: core.audit.Vis
        \\          .pub
        \\        .ty: []const u8
        \\          "uint"
        \\  [2]: app.runtime.AuditEntrySnap
        \\    .sid: []const u8
        \\      "bg"
        \\    .seq: u64 = 3
        \\    .kind: core.audit.EventKind
        \\      .tool
        \\    .severity: core.audit.Severity
        \\      .info
        \\    .outcome: core.audit.Outcome
        \\      .ok
        \\    .res_kind: ?core.audit.ResourceKind
        \\      .cmd
        \\    .res_name: ?[]const u8
        \\      "bg"
        \\    .op: ?[]const u8
        \\      "start"
        \\    .msg: ?[]const u8
        \\      "bg control start"
        \\    .data_name: ?[]const u8
        \\      "bg"
        \\    .call_id: ?[]const u8
        \\      "start"
        \\    .auth_mech: ?[]const u8
        \\      null
        \\    .attrs: []const app.runtime.AuditAttrSnap
        \\      [0]: app.runtime.AuditAttrSnap
        \\        .key: []const u8
        \\          "cwd"
        \\        .vis: core.audit.Vis
        \\          .mask
        \\        .ty: []const u8
        \\          "str"
        \\  [3]: app.runtime.AuditEntrySnap
        \\    .sid: []const u8
        \\      "bg"
        \\    .seq: u64 = 4
        \\    .kind: core.audit.EventKind
        \\      .tool
        \\    .severity: core.audit.Severity
        \\      .info
        \\    .outcome: core.audit.Outcome
        \\      .ok
        \\    .res_kind: ?core.audit.ResourceKind
        \\      .cmd
        \\    .res_name: ?[]const u8
        \\      "bg"
        \\    .op: ?[]const u8
        \\      "start"
        \\    .msg: ?[]const u8
        \\      "bg control success"
        \\    .data_name: ?[]const u8
        \\      "bg"
        \\    .call_id: ?[]const u8
        \\      "start"
        \\    .auth_mech: ?[]const u8
        \\      null
        \\    .attrs: []const app.runtime.AuditAttrSnap
        \\      [0]: app.runtime.AuditAttrSnap
        \\        .key: []const u8
        \\          "job_id"
        \\        .vis: core.audit.Vis
        \\          .pub
        \\        .ty: []const u8
        \\          "uint"
        \\      [1]: app.runtime.AuditAttrSnap
        \\        .key: []const u8
        \\          "pid"
        \\        .vis: core.audit.Vis
        \\          .pub
        \\        .ty: []const u8
        \\          "uint"
        \\      [2]: app.runtime.AuditAttrSnap
        \\        .key: []const u8
        \\          "cwd"
        \\        .vis: core.audit.Vis
        \\          .mask
        \\        .ty: []const u8
        \\          "str"
        \\      [3]: app.runtime.AuditAttrSnap
        \\        .key: []const u8
        \\          "log_path"
        \\        .vis: core.audit.Vis
        \\          .mask
        \\        .ty: []const u8
        \\          "str"
        \\  [4]: app.runtime.AuditEntrySnap
        \\    .sid: []const u8
        \\      "bg"
        \\    .seq: u64 = 5
        \\    .kind: core.audit.EventKind
        \\      .tool
        \\    .severity: core.audit.Severity
        \\      .info
        \\    .outcome: core.audit.Outcome
        \\      .ok
        \\    .res_kind: ?core.audit.ResourceKind
        \\      .cmd
        \\    .res_name: ?[]const u8
        \\      "bg"
        \\    .op: ?[]const u8
        \\      "drain"
        \\    .msg: ?[]const u8
        \\      "bg control start"
        \\    .data_name: ?[]const u8
        \\      "bg"
        \\    .call_id: ?[]const u8
        \\      "drain"
        \\    .auth_mech: ?[]const u8
        \\      null
        \\    .attrs: []const app.runtime.AuditAttrSnap
        \\      (empty)
        \\  [5]: app.runtime.AuditEntrySnap
        \\    .sid: []const u8
        \\      "bg"
        \\    .seq: u64 = 6
        \\    .kind: core.audit.EventKind
        \\      .tool
        \\    .severity: core.audit.Severity
        \\      .info
        \\    .outcome: core.audit.Outcome
        \\      .ok
        \\    .res_kind: ?core.audit.ResourceKind
        \\      .cmd
        \\    .res_name: ?[]const u8
        \\      "bg"
        \\    .op: ?[]const u8
        \\      "drain"
        \\    .msg: ?[]const u8
        \\      "bg control success"
        \\    .data_name: ?[]const u8
        \\      "bg"
        \\    .call_id: ?[]const u8
        \\      "drain"
        \\    .auth_mech: ?[]const u8
        \\      null
        \\    .attrs: []const app.runtime.AuditAttrSnap
        \\      [0]: app.runtime.AuditAttrSnap
        \\        .key: []const u8
        \\          "count"
        \\        .vis: core.audit.Vis
        \\          .pub
        \\        .ty: []const u8
        \\          "uint"
        \\  [6]: app.runtime.AuditEntrySnap
        \\    .sid: []const u8
        \\      "bg"
        \\    .seq: u64 = 7
        \\    .kind: core.audit.EventKind
        \\      .tool
        \\    .severity: core.audit.Severity
        \\      .info
        \\    .outcome: core.audit.Outcome
        \\      .ok
        \\    .res_kind: ?core.audit.ResourceKind
        \\      .cmd
        \\    .res_name: ?[]const u8
        \\      "bg"
        \\    .op: ?[]const u8
        \\      "list"
        \\    .msg: ?[]const u8
        \\      "bg control start"
        \\    .data_name: ?[]const u8
        \\      "bg"
        \\    .call_id: ?[]const u8
        \\      "list"
        \\    .auth_mech: ?[]const u8
        \\      null
        \\    .attrs: []const app.runtime.AuditAttrSnap
        \\      (empty)
        \\  [7]: app.runtime.AuditEntrySnap
        \\    .sid: []const u8
        \\      "bg"
        \\    .seq: u64 = 8
        \\    .kind: core.audit.EventKind
        \\      .tool
        \\    .severity: core.audit.Severity
        \\      .info
        \\    .outcome: core.audit.Outcome
        \\      .ok
        \\    .res_kind: ?core.audit.ResourceKind
        \\      .cmd
        \\    .res_name: ?[]const u8
        \\      "bg"
        \\    .op: ?[]const u8
        \\      "list"
        \\    .msg: ?[]const u8
        \\      "bg control success"
        \\    .data_name: ?[]const u8
        \\      "bg"
        \\    .call_id: ?[]const u8
        \\      "list"
        \\    .auth_mech: ?[]const u8
        \\      null
        \\    .attrs: []const app.runtime.AuditAttrSnap
        \\      [0]: app.runtime.AuditAttrSnap
        \\        .key: []const u8
        \\          "count"
        \\        .vis: core.audit.Vis
        \\          .pub
        \\        .ty: []const u8
        \\          "uint"
        \\  [8]: app.runtime.AuditEntrySnap
        \\    .sid: []const u8
        \\      "bg"
        \\    .seq: u64 = 9
        \\    .kind: core.audit.EventKind
        \\      .tool
        \\    .severity: core.audit.Severity
        \\      .info
        \\    .outcome: core.audit.Outcome
        \\      .ok
        \\    .res_kind: ?core.audit.ResourceKind
        \\      .cmd
        \\    .res_name: ?[]const u8
        \\      "bg"
        \\    .op: ?[]const u8
        \\      "drain"
        \\    .msg: ?[]const u8
        \\      "bg control start"
        \\    .data_name: ?[]const u8
        \\      "bg"
        \\    .call_id: ?[]const u8
        \\      "drain"
        \\    .auth_mech: ?[]const u8
        \\      null
        \\    .attrs: []const app.runtime.AuditAttrSnap
        \\      (empty)
        \\  [9]: app.runtime.AuditEntrySnap
        \\    .sid: []const u8
        \\      "bg"
        \\    .seq: u64 = 10
        \\    .kind: core.audit.EventKind
        \\      .tool
        \\    .severity: core.audit.Severity
        \\      .info
        \\    .outcome: core.audit.Outcome
        \\      .ok
        \\    .res_kind: ?core.audit.ResourceKind
        \\      .cmd
        \\    .res_name: ?[]const u8
        \\      "bg"
        \\    .op: ?[]const u8
        \\      "drain"
        \\    .msg: ?[]const u8
        \\      "bg control success"
        \\    .data_name: ?[]const u8
        \\      "bg"
        \\    .call_id: ?[]const u8
        \\      "drain"
        \\    .auth_mech: ?[]const u8
        \\      null
        \\    .attrs: []const app.runtime.AuditAttrSnap
        \\      [0]: app.runtime.AuditAttrSnap
        \\        .key: []const u8
        \\          "count"
        \\        .vis: core.audit.Vis
        \\          .pub
        \\        .ty: []const u8
        \\          "uint"
        \\  [10]: app.runtime.AuditEntrySnap
        \\    .sid: []const u8
        \\      "bg"
        \\    .seq: u64 = 11
        \\    .kind: core.audit.EventKind
        \\      .tool
        \\    .severity: core.audit.Severity
        \\      .info
        \\    .outcome: core.audit.Outcome
        \\      .ok
        \\    .res_kind: ?core.audit.ResourceKind
        \\      .cmd
        \\    .res_name: ?[]const u8
        \\      "bg"
        \\    .op: ?[]const u8
        \\      "stop"
        \\    .msg: ?[]const u8
        \\      "bg control start"
        \\    .data_name: ?[]const u8
        \\      "bg"
        \\    .call_id: ?[]const u8
        \\      "stop"
        \\    .auth_mech: ?[]const u8
        \\      null
        \\    .attrs: []const app.runtime.AuditAttrSnap
        \\      [0]: app.runtime.AuditAttrSnap
        \\        .key: []const u8
        \\          "job_id"
        \\        .vis: core.audit.Vis
        \\          .pub
        \\        .ty: []const u8
        \\          "uint"
        \\  [11]: app.runtime.AuditEntrySnap
        \\    .sid: []const u8
        \\      "bg"
        \\    .seq: u64 = 12
        \\    .kind: core.audit.EventKind
        \\      .tool
        \\    .severity: core.audit.Severity
        \\      .err
        \\    .outcome: core.audit.Outcome
        \\      .fail
        \\    .res_kind: ?core.audit.ResourceKind
        \\      .cmd
        \\    .res_name: ?[]const u8
        \\      "bg"
        \\    .op: ?[]const u8
        \\      "stop"
        \\    .msg: ?[]const u8
        \\      "bg not found"
        \\    .data_name: ?[]const u8
        \\      "bg"
        \\    .call_id: ?[]const u8
        \\      "stop"
        \\    .auth_mech: ?[]const u8
        \\      null
        \\    .attrs: []const app.runtime.AuditAttrSnap
        \\      [0]: app.runtime.AuditAttrSnap
        \\        .key: []const u8
        \\          "job_id"
        \\        .vis: core.audit.Vis
        \\          .pub
        \\        .ty: []const u8
        \\          "uint"
        \\      [1]: app.runtime.AuditAttrSnap
        \\        .key: []const u8
        \\          "status"
        \\        .vis: core.audit.Vis
        \\          .pub
        \\        .ty: []const u8
        \\          "str"
        \\  [12]: app.runtime.AuditEntrySnap
        \\    .sid: []const u8
        \\      "bg"
        \\    .seq: u64 = 13
        \\    .kind: core.audit.EventKind
        \\      .tool
        \\    .severity: core.audit.Severity
        \\      .info
        \\    .outcome: core.audit.Outcome
        \\      .ok
        \\    .res_kind: ?core.audit.ResourceKind
        \\      .cmd
        \\    .res_name: ?[]const u8
        \\      "bg"
        \\    .op: ?[]const u8
        \\      "drain"
        \\    .msg: ?[]const u8
        \\      "bg control start"
        \\    .data_name: ?[]const u8
        \\      "bg"
        \\    .call_id: ?[]const u8
        \\      "drain"
        \\    .auth_mech: ?[]const u8
        \\      null
        \\    .attrs: []const app.runtime.AuditAttrSnap
        \\      (empty)
        \\  [13]: app.runtime.AuditEntrySnap
        \\    .sid: []const u8
        \\      "bg"
        \\    .seq: u64 = 14
        \\    .kind: core.audit.EventKind
        \\      .tool
        \\    .severity: core.audit.Severity
        \\      .info
        \\    .outcome: core.audit.Outcome
        \\      .ok
        \\    .res_kind: ?core.audit.ResourceKind
        \\      .cmd
        \\    .res_name: ?[]const u8
        \\      "bg"
        \\    .op: ?[]const u8
        \\      "drain"
        \\    .msg: ?[]const u8
        \\      "bg control success"
        \\    .data_name: ?[]const u8
        \\      "bg"
        \\    .call_id: ?[]const u8
        \\      "drain"
        \\    .auth_mech: ?[]const u8
        \\      null
        \\    .attrs: []const app.runtime.AuditAttrSnap
        \\      [0]: app.runtime.AuditAttrSnap
        \\        .key: []const u8
        \\          "count"
        \\        .vis: core.audit.Vis
        \\          .pub
        \\        .ty: []const u8
        \\          "uint"
    ).expectEqual(trace);
}

test "runtime tui auth commands reject direct login and audit logout records" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sess");
    try tmp.dir.createDirPath(std.testing.io, "home");
    {
        var bad = try tmp.dir.createFile(std.testing.io, "home-bad", .{});
        bad.close(std.testing.io);
    }
    const sess_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "sess");
    defer std.testing.allocator.free(sess_abs);
    const home_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "home");
    defer std.testing.allocator.free(home_abs);
    const bad_home_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "home-bad");
    defer std.testing.allocator.free(bad_home_abs);

    var cfg = cli.Run{
        .mode = .tui,
        .prompt = null,
        .cfg = .{
            .mode = .tui,
            .model = try std.testing.allocator.dupe(u8, "m"),
            .provider = try std.testing.allocator.dupe(u8, "openai"),
            .session_dir = try std.testing.allocator.dupe(u8, sess_abs),
            .provider_cmd = try std.testing.allocator.dupe(u8, "cat >/dev/null; printf 'text:noop\\nstop:done\\n'"),
        },
    };
    defer cfg.cfg.deinit(std.testing.allocator);

    var in_fbs: std.Io.Reader = .fixed("/login openai sk-openai-secret\n/logout openai\n/quit\n");
    var out_buf: [32768]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);
    var rows = AuditRows{};
    defer rows.deinit(std.testing.allocator);

    const sid = try execWithIoHooks(
        std.testing.allocator,
        cfg,
        &in_fbs,
        &out_fbs,
        .{
            .audit_emitter = &rows.emitter,
            .now_ms = struct {
                fn f() i64 {
                    return 432;
                }
            }.f,
            .auth_home = home_abs,
        },
    );
    defer std.testing.allocator.free(sid);

    const written = out_fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "direct provider login disabled by policy") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "PZ_PROVIDER_CMD") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "API key saved for openai") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "logged out of openai") != null);

    var fail_cfg = cli.Run{
        .mode = .tui,
        .prompt = null,
        .cfg = .{
            .mode = .tui,
            .model = try std.testing.allocator.dupe(u8, "m"),
            .provider = try std.testing.allocator.dupe(u8, "openai"),
            .session_dir = try std.testing.allocator.dupe(u8, sess_abs),
            .provider_cmd = try std.testing.allocator.dupe(u8, "cat >/dev/null; printf 'text:noop\\nstop:done\\n'"),
        },
    };
    defer fail_cfg.cfg.deinit(std.testing.allocator);

    var fail_in_fbs: std.Io.Reader = .fixed("/login openai sk-openai-secret\n/quit\n");
    var fail_out_buf: [32768]u8 = undefined;
    var fail_out_fbs: std.Io.Writer = .fixed(&fail_out_buf);

    const fail_sid = try execWithIoHooks(
        std.testing.allocator,
        fail_cfg,
        &fail_in_fbs,
        &fail_out_fbs,
        .{
            .audit_emitter = &rows.emitter,
            .now_ms = struct {
                fn f() i64 {
                    return 432;
                }
            }.f,
            .auth_home = bad_home_abs,
        },
    );
    defer std.testing.allocator.free(fail_sid);

    const fail_written = fail_out_fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, fail_written, "direct provider login disabled by policy") != null);
    try std.testing.expect(std.mem.indexOf(u8, fail_written, "error: login failed") == null);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const trace = try auditTraceSnap(arena.allocator(), rows.rows.items);
    var saw_save_api_key = false;
    var saw_logout = false;
    for (trace) |entry| {
        if (entry.op) |op| {
            if (std.mem.eql(u8, op, "save_api_key")) saw_save_api_key = true;
            if (std.mem.eql(u8, op, "logout")) saw_logout = true;
        }
    }
    try std.testing.expect(!saw_save_api_key);
    try std.testing.expect(saw_logout);
}

test "runtime tui bg commands emit audited redacted control records" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sess");
    const sess_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "sess");
    defer std.testing.allocator.free(sess_abs);

    var cfg = cli.Run{
        .mode = .tui,
        .prompt = null,
        .cfg = .{
            .mode = .tui,
            .model = try std.testing.allocator.dupe(u8, "m"),
            .provider = try std.testing.allocator.dupe(u8, "p"),
            .session_dir = try std.testing.allocator.dupe(u8, sess_abs),
            .provider_cmd = try std.testing.allocator.dupe(u8, "cat >/dev/null; printf 'text:noop\\nstop:done\\n'"),
        },
    };
    defer cfg.cfg.deinit(std.testing.allocator);

    var in_fbs: std.Io.Reader = .fixed("/bg run printf done\n/bg list\n/bg stop 42\n/quit\n");
    var out_buf: [32768]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);
    var rows = AuditRows{};
    defer rows.deinit(std.testing.allocator);

    const sid = try execWithIoHooks(
        std.testing.allocator,
        cfg,
        &in_fbs,
        &out_fbs,
        .{
            .audit_emitter = &rows.emitter,
            .now_ms = struct {
                fn f() i64 {
                    return 765;
                }
            }.f,
        },
    );
    defer std.testing.allocator.free(sid);

    const written = out_fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "bg started id=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "bg not found id=42") != null);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const trace = try auditTraceSnap(arena.allocator(), rows.rows.items);
    try oh.snap(@src(),
        \\[]app.runtime.AuditEntrySnap
        \\  [0]: app.runtime.AuditEntrySnap
        \\    .sid: []const u8
        \\      "bg"
        \\    .seq: u64 = 1
        \\    .kind: core.audit.EventKind
        \\      .tool
        \\    .severity: core.audit.Severity
        \\      .info
        \\    .outcome: core.audit.Outcome
        \\      .ok
        \\    .res_kind: ?core.audit.ResourceKind
        \\      .cmd
        \\    .res_name: ?[]const u8
        \\      "bg"
        \\    .op: ?[]const u8
        \\      "list"
        \\    .msg: ?[]const u8
        \\      "bg control start"
        \\    .data_name: ?[]const u8
        \\      "bg"
        \\    .call_id: ?[]const u8
        \\      "list"
        \\    .auth_mech: ?[]const u8
        \\      null
        \\    .attrs: []const app.runtime.AuditAttrSnap
        \\      (empty)
        \\  [1]: app.runtime.AuditEntrySnap
        \\    .sid: []const u8
        \\      "bg"
        \\    .seq: u64 = 2
        \\    .kind: core.audit.EventKind
        \\      .tool
        \\    .severity: core.audit.Severity
        \\      .info
        \\    .outcome: core.audit.Outcome
        \\      .ok
        \\    .res_kind: ?core.audit.ResourceKind
        \\      .cmd
        \\    .res_name: ?[]const u8
        \\      "bg"
        \\    .op: ?[]const u8
        \\      "list"
        \\    .msg: ?[]const u8
        \\      "bg control success"
        \\    .data_name: ?[]const u8
        \\      "bg"
        \\    .call_id: ?[]const u8
        \\      "list"
        \\    .auth_mech: ?[]const u8
        \\      null
        \\    .attrs: []const app.runtime.AuditAttrSnap
        \\      [0]: app.runtime.AuditAttrSnap
        \\        .key: []const u8
        \\          "count"
        \\        .vis: core.audit.Vis
        \\          .pub
        \\        .ty: []const u8
        \\          "uint"
        \\  [2]: app.runtime.AuditEntrySnap
        \\    .sid: []const u8
        \\      "bg"
        \\    .seq: u64 = 3
        \\    .kind: core.audit.EventKind
        \\      .tool
        \\    .severity: core.audit.Severity
        \\      .info
        \\    .outcome: core.audit.Outcome
        \\      .ok
        \\    .res_kind: ?core.audit.ResourceKind
        \\      .cmd
        \\    .res_name: ?[]const u8
        \\      "bg"
        \\    .op: ?[]const u8
        \\      "start"
        \\    .msg: ?[]const u8
        \\      "bg control start"
        \\    .data_name: ?[]const u8
        \\      "bg"
        \\    .call_id: ?[]const u8
        \\      "start"
        \\    .auth_mech: ?[]const u8
        \\      null
        \\    .attrs: []const app.runtime.AuditAttrSnap
        \\      [0]: app.runtime.AuditAttrSnap
        \\        .key: []const u8
        \\          "cwd"
        \\        .vis: core.audit.Vis
        \\          .mask
        \\        .ty: []const u8
        \\          "str"
        \\  [3]: app.runtime.AuditEntrySnap
        \\    .sid: []const u8
        \\      "bg"
        \\    .seq: u64 = 4
        \\    .kind: core.audit.EventKind
        \\      .tool
        \\    .severity: core.audit.Severity
        \\      .info
        \\    .outcome: core.audit.Outcome
        \\      .ok
        \\    .res_kind: ?core.audit.ResourceKind
        \\      .cmd
        \\    .res_name: ?[]const u8
        \\      "bg"
        \\    .op: ?[]const u8
        \\      "start"
        \\    .msg: ?[]const u8
        \\      "bg control success"
        \\    .data_name: ?[]const u8
        \\      "bg"
        \\    .call_id: ?[]const u8
        \\      "start"
        \\    .auth_mech: ?[]const u8
        \\      null
        \\    .attrs: []const app.runtime.AuditAttrSnap
        \\      [0]: app.runtime.AuditAttrSnap
        \\        .key: []const u8
        \\          "job_id"
        \\        .vis: core.audit.Vis
        \\          .pub
        \\        .ty: []const u8
        \\          "uint"
        \\      [1]: app.runtime.AuditAttrSnap
        \\        .key: []const u8
        \\          "pid"
        \\        .vis: core.audit.Vis
        \\          .pub
        \\        .ty: []const u8
        \\          "uint"
        \\      [2]: app.runtime.AuditAttrSnap
        \\        .key: []const u8
        \\          "cwd"
        \\        .vis: core.audit.Vis
        \\          .mask
        \\        .ty: []const u8
        \\          "str"
        \\      [3]: app.runtime.AuditAttrSnap
        \\        .key: []const u8
        \\          "log_path"
        \\        .vis: core.audit.Vis
        \\          .mask
        \\        .ty: []const u8
        \\          "str"
        \\  [4]: app.runtime.AuditEntrySnap
        \\    .sid: []const u8
        \\      "bg"
        \\    .seq: u64 = 5
        \\    .kind: core.audit.EventKind
        \\      .tool
        \\    .severity: core.audit.Severity
        \\      .info
        \\    .outcome: core.audit.Outcome
        \\      .ok
        \\    .res_kind: ?core.audit.ResourceKind
        \\      .cmd
        \\    .res_name: ?[]const u8
        \\      "bg"
        \\    .op: ?[]const u8
        \\      "list"
        \\    .msg: ?[]const u8
        \\      "bg control start"
        \\    .data_name: ?[]const u8
        \\      "bg"
        \\    .call_id: ?[]const u8
        \\      "list"
        \\    .auth_mech: ?[]const u8
        \\      null
        \\    .attrs: []const app.runtime.AuditAttrSnap
        \\      (empty)
        \\  [5]: app.runtime.AuditEntrySnap
        \\    .sid: []const u8
        \\      "bg"
        \\    .seq: u64 = 6
        \\    .kind: core.audit.EventKind
        \\      .tool
        \\    .severity: core.audit.Severity
        \\      .info
        \\    .outcome: core.audit.Outcome
        \\      .ok
        \\    .res_kind: ?core.audit.ResourceKind
        \\      .cmd
        \\    .res_name: ?[]const u8
        \\      "bg"
        \\    .op: ?[]const u8
        \\      "list"
        \\    .msg: ?[]const u8
        \\      "bg control success"
        \\    .data_name: ?[]const u8
        \\      "bg"
        \\    .call_id: ?[]const u8
        \\      "list"
        \\    .auth_mech: ?[]const u8
        \\      null
        \\    .attrs: []const app.runtime.AuditAttrSnap
        \\      [0]: app.runtime.AuditAttrSnap
        \\        .key: []const u8
        \\          "count"
        \\        .vis: core.audit.Vis
        \\          .pub
        \\        .ty: []const u8
        \\          "uint"
        \\  [6]: app.runtime.AuditEntrySnap
        \\    .sid: []const u8
        \\      "bg"
        \\    .seq: u64 = 7
        \\    .kind: core.audit.EventKind
        \\      .tool
        \\    .severity: core.audit.Severity
        \\      .info
        \\    .outcome: core.audit.Outcome
        \\      .ok
        \\    .res_kind: ?core.audit.ResourceKind
        \\      .cmd
        \\    .res_name: ?[]const u8
        \\      "bg"
        \\    .op: ?[]const u8
        \\      "list"
        \\    .msg: ?[]const u8
        \\      "bg control start"
        \\    .data_name: ?[]const u8
        \\      "bg"
        \\    .call_id: ?[]const u8
        \\      "list"
        \\    .auth_mech: ?[]const u8
        \\      null
        \\    .attrs: []const app.runtime.AuditAttrSnap
        \\      (empty)
        \\  [7]: app.runtime.AuditEntrySnap
        \\    .sid: []const u8
        \\      "bg"
        \\    .seq: u64 = 8
        \\    .kind: core.audit.EventKind
        \\      .tool
        \\    .severity: core.audit.Severity
        \\      .info
        \\    .outcome: core.audit.Outcome
        \\      .ok
        \\    .res_kind: ?core.audit.ResourceKind
        \\      .cmd
        \\    .res_name: ?[]const u8
        \\      "bg"
        \\    .op: ?[]const u8
        \\      "list"
        \\    .msg: ?[]const u8
        \\      "bg control success"
        \\    .data_name: ?[]const u8
        \\      "bg"
        \\    .call_id: ?[]const u8
        \\      "list"
        \\    .auth_mech: ?[]const u8
        \\      null
        \\    .attrs: []const app.runtime.AuditAttrSnap
        \\      [0]: app.runtime.AuditAttrSnap
        \\        .key: []const u8
        \\          "count"
        \\        .vis: core.audit.Vis
        \\          .pub
        \\        .ty: []const u8
        \\          "uint"
        \\  [8]: app.runtime.AuditEntrySnap
        \\    .sid: []const u8
        \\      "bg"
        \\    .seq: u64 = 9
        \\    .kind: core.audit.EventKind
        \\      .tool
        \\    .severity: core.audit.Severity
        \\      .info
        \\    .outcome: core.audit.Outcome
        \\      .ok
        \\    .res_kind: ?core.audit.ResourceKind
        \\      .cmd
        \\    .res_name: ?[]const u8
        \\      "bg"
        \\    .op: ?[]const u8
        \\      "list"
        \\    .msg: ?[]const u8
        \\      "bg control start"
        \\    .data_name: ?[]const u8
        \\      "bg"
        \\    .call_id: ?[]const u8
        \\      "list"
        \\    .auth_mech: ?[]const u8
        \\      null
        \\    .attrs: []const app.runtime.AuditAttrSnap
        \\      (empty)
        \\  [9]: app.runtime.AuditEntrySnap
        \\    .sid: []const u8
        \\      "bg"
        \\    .seq: u64 = 10
        \\    .kind: core.audit.EventKind
        \\      .tool
        \\    .severity: core.audit.Severity
        \\      .info
        \\    .outcome: core.audit.Outcome
        \\      .ok
        \\    .res_kind: ?core.audit.ResourceKind
        \\      .cmd
        \\    .res_name: ?[]const u8
        \\      "bg"
        \\    .op: ?[]const u8
        \\      "list"
        \\    .msg: ?[]const u8
        \\      "bg control success"
        \\    .data_name: ?[]const u8
        \\      "bg"
        \\    .call_id: ?[]const u8
        \\      "list"
        \\    .auth_mech: ?[]const u8
        \\      null
        \\    .attrs: []const app.runtime.AuditAttrSnap
        \\      [0]: app.runtime.AuditAttrSnap
        \\        .key: []const u8
        \\          "count"
        \\        .vis: core.audit.Vis
        \\          .pub
        \\        .ty: []const u8
        \\          "uint"
        \\  [10]: app.runtime.AuditEntrySnap
        \\    .sid: []const u8
        \\      "bg"
        \\    .seq: u64 = 11
        \\    .kind: core.audit.EventKind
        \\      .tool
        \\    .severity: core.audit.Severity
        \\      .info
        \\    .outcome: core.audit.Outcome
        \\      .ok
        \\    .res_kind: ?core.audit.ResourceKind
        \\      .cmd
        \\    .res_name: ?[]const u8
        \\      "bg"
        \\    .op: ?[]const u8
        \\      "stop"
        \\    .msg: ?[]const u8
        \\      "bg control start"
        \\    .data_name: ?[]const u8
        \\      "bg"
        \\    .call_id: ?[]const u8
        \\      "stop"
        \\    .auth_mech: ?[]const u8
        \\      null
        \\    .attrs: []const app.runtime.AuditAttrSnap
        \\      [0]: app.runtime.AuditAttrSnap
        \\        .key: []const u8
        \\          "job_id"
        \\        .vis: core.audit.Vis
        \\          .pub
        \\        .ty: []const u8
        \\          "uint"
        \\  [11]: app.runtime.AuditEntrySnap
        \\    .sid: []const u8
        \\      "bg"
        \\    .seq: u64 = 12
        \\    .kind: core.audit.EventKind
        \\      .tool
        \\    .severity: core.audit.Severity
        \\      .err
        \\    .outcome: core.audit.Outcome
        \\      .fail
        \\    .res_kind: ?core.audit.ResourceKind
        \\      .cmd
        \\    .res_name: ?[]const u8
        \\      "bg"
        \\    .op: ?[]const u8
        \\      "stop"
        \\    .msg: ?[]const u8
        \\      "bg not found"
        \\    .data_name: ?[]const u8
        \\      "bg"
        \\    .call_id: ?[]const u8
        \\      "stop"
        \\    .auth_mech: ?[]const u8
        \\      null
        \\    .attrs: []const app.runtime.AuditAttrSnap
        \\      [0]: app.runtime.AuditAttrSnap
        \\        .key: []const u8
        \\          "job_id"
        \\        .vis: core.audit.Vis
        \\          .pub
        \\        .ty: []const u8
        \\          "uint"
        \\      [1]: app.runtime.AuditAttrSnap
        \\        .key: []const u8
        \\          "status"
        \\        .vis: core.audit.Vis
        \\          .pub
        \\        .ty: []const u8
        \\          "str"
        \\  [12]: app.runtime.AuditEntrySnap
        \\    .sid: []const u8
        \\      "bg"
        \\    .seq: u64 = 13
        \\    .kind: core.audit.EventKind
        \\      .tool
        \\    .severity: core.audit.Severity
        \\      .info
        \\    .outcome: core.audit.Outcome
        \\      .ok
        \\    .res_kind: ?core.audit.ResourceKind
        \\      .cmd
        \\    .res_name: ?[]const u8
        \\      "bg"
        \\    .op: ?[]const u8
        \\      "list"
        \\    .msg: ?[]const u8
        \\      "bg control start"
        \\    .data_name: ?[]const u8
        \\      "bg"
        \\    .call_id: ?[]const u8
        \\      "list"
        \\    .auth_mech: ?[]const u8
        \\      null
        \\    .attrs: []const app.runtime.AuditAttrSnap
        \\      (empty)
        \\  [13]: app.runtime.AuditEntrySnap
        \\    .sid: []const u8
        \\      "bg"
        \\    .seq: u64 = 14
        \\    .kind: core.audit.EventKind
        \\      .tool
        \\    .severity: core.audit.Severity
        \\      .info
        \\    .outcome: core.audit.Outcome
        \\      .ok
        \\    .res_kind: ?core.audit.ResourceKind
        \\      .cmd
        \\    .res_name: ?[]const u8
        \\      "bg"
        \\    .op: ?[]const u8
        \\      "list"
        \\    .msg: ?[]const u8
        \\      "bg control success"
        \\    .data_name: ?[]const u8
        \\      "bg"
        \\    .call_id: ?[]const u8
        \\      "list"
        \\    .auth_mech: ?[]const u8
        \\      null
        \\    .attrs: []const app.runtime.AuditAttrSnap
        \\      [0]: app.runtime.AuditAttrSnap
        \\        .key: []const u8
        \\          "count"
        \\        .vis: core.audit.Vis
        \\          .pub
        \\        .ty: []const u8
        \\          "uint"
    ).expectEqual(trace);
}
test "runtime reload audit snapshots start success and failure" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};

    var rows = AuditRows{};
    defer rows.deinit(std.testing.allocator);

    var ctl_audit = RuntimeCtlAudit{ .hooks = .{
        .audit_emitter = &rows.emitter,
        .now_ms = struct {
            fn f() i64 {
                return 777;
            }
        }.f,
    } };
    var sys_prompt: ?[]const u8 = null;
    var sys_prompt_owned: ?[]u8 = null;
    defer if (sys_prompt_owned) |buf| std.testing.allocator.free(buf);

    const loaded = try reloadContextWithAudit(
        std.testing.allocator,
        &sys_prompt,
        &sys_prompt_owned,
        &ctl_audit,
        struct {
            fn f(alloc: std.mem.Allocator, _: std.Io, _: ?[]const u8) !?[]u8 {
                return try alloc.dupe(u8, "ctx a");
            }
        }.f,
        null,
    );
    try std.testing.expectEqual(ReloadRes.loaded, loaded);

    const empty = try reloadContextWithAudit(
        std.testing.allocator,
        &sys_prompt,
        &sys_prompt_owned,
        &ctl_audit,
        struct {
            fn f(_: std.mem.Allocator, _: std.Io, _: ?[]const u8) !?[]u8 {
                return null;
            }
        }.f,
        null,
    );
    try std.testing.expectEqual(ReloadRes.empty, empty);

    try std.testing.expectError(
        error.AccessDenied,
        reloadContextWithAudit(
            std.testing.allocator,
            &sys_prompt,
            &sys_prompt_owned,
            &ctl_audit,
            struct {
                fn f(_: std.mem.Allocator, _: std.Io, _: ?[]const u8) !?[]u8 {
                    return error.AccessDenied;
                }
            }.f,
            null,
        ),
    );

    const joined = try std.mem.join(std.testing.allocator, "\n", rows.rows.items);
    defer std.testing.allocator.free(joined);
    try oh.snap(@src(),
        \\[]u8
        \\  "{"v":1,"ts_ms":777,"sid":"runtime","seq":1,"kind":"tool","sev":"info","out":"ok","actor":{"kind":"sys"},"res":{"kind":"cfg","name":{"text":"runtime","vis":"pub"},"op":"reload"},"msg":{"text":"runtime control start","vis":"pub"},"data":{"name":{"text":"runtime","vis":"pub"},"call_id":"reload"},"attrs":[]}
        \\{"v":1,"ts_ms":777,"sid":"runtime","seq":2,"kind":"tool","sev":"notice","out":"ok","actor":{"kind":"sys"},"res":{"kind":"cfg","name":{"text":"runtime","vis":"pub"},"op":"reload"},"msg":{"text":"runtime control success","vis":"pub"},"data":{"name":{"text":"runtime","vis":"pub"},"call_id":"reload"},"attrs":[{"key":"loaded","vis":"pub","ty":"bool","val":true}]}
        \\{"v":1,"ts_ms":777,"sid":"runtime","seq":3,"kind":"tool","sev":"info","out":"ok","actor":{"kind":"sys"},"res":{"kind":"cfg","name":{"text":"runtime","vis":"pub"},"op":"reload"},"msg":{"text":"runtime control start","vis":"pub"},"data":{"name":{"text":"runtime","vis":"pub"},"call_id":"reload"},"attrs":[]}
        \\{"v":1,"ts_ms":777,"sid":"runtime","seq":4,"kind":"tool","sev":"notice","out":"ok","actor":{"kind":"sys"},"res":{"kind":"cfg","name":{"text":"runtime","vis":"pub"},"op":"reload"},"msg":{"text":"runtime control success","vis":"pub"},"data":{"name":{"text":"runtime","vis":"pub"},"call_id":"reload"},"attrs":[{"key":"loaded","vis":"pub","ty":"bool","val":false}]}
        \\{"v":1,"ts_ms":777,"sid":"runtime","seq":5,"kind":"tool","sev":"info","out":"ok","actor":{"kind":"sys"},"res":{"kind":"cfg","name":{"text":"runtime","vis":"pub"},"op":"reload"},"msg":{"text":"runtime control start","vis":"pub"},"data":{"name":{"text":"runtime","vis":"pub"},"call_id":"reload"},"attrs":[]}
        \\{"v":1,"ts_ms":777,"sid":"runtime","seq":6,"kind":"tool","sev":"err","out":"fail","actor":{"kind":"sys"},"res":{"kind":"cfg","name":{"text":"runtime","vis":"pub"},"op":"reload"},"msg":{"text":"[mask:324e1bba42a2f616]","vis":"mask"},"data":{"name":{"text":"runtime","vis":"pub"},"call_id":"reload"},"attrs":[]}"
    ).expectEqual(joined);
}

test "runtime rpc control commands emit audited redacted control records" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sess");
    const sess_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "sess");
    defer std.testing.allocator.free(sess_abs);
    const events = [_]core.session.Event{
        .{
            .at_ms = 1,
            .data = .{ .prompt = .{ .text = "old prompt" } },
        },
        .{
            .at_ms = 2,
            .data = .{ .text = .{ .text = "old answer" } },
        },
        .{
            .at_ms = 3,
            .data = .{ .stop = .{ .reason = .done } },
        },
    };
    try writeSessionEventsFile(tmp, "sess/100.jsonl", &events);

    var cfg = cli.Run{
        .mode = .rpc,
        .prompt = null,
        .cfg = .{
            .mode = .rpc,
            .model = try std.testing.allocator.dupe(u8, "m"),
            .provider = try std.testing.allocator.dupe(u8, "p"),
            .session_dir = try std.testing.allocator.dupe(u8, sess_abs),
            .provider_cmd = try std.testing.allocator.dupe(u8, "cat >/dev/null; printf 'text:noop\\nstop:done\\n'"),
        },
    };
    defer cfg.cfg.deinit(std.testing.allocator);

    var in_fbs: std.Io.Reader = .fixed(
        "{\"id\":\"1\",\"cmd\":\"provider\",\"arg\":\"p2\"}\n" ++
            "{\"id\":\"2\",\"type\":\"set_model\",\"provider\":\"p3\",\"model_id\":\"m2\"}\n" ++
            "{\"id\":\"3\",\"cmd\":\"tools\",\"arg\":\"bogus\"}\n" ++
            "{\"id\":\"4\",\"cmd\":\"tools\",\"arg\":\"read,skill\"}\n" ++
            "{\"id\":\"5\",\"cmd\":\"resume\",\"arg\":\"100\"}\n" ++
            "{\"id\":\"6\",\"cmd\":\"fork\",\"arg\":\"200\"}\n" ++
            "{\"id\":\"7\",\"cmd\":\"compact\"}\n" ++
            "{\"id\":\"8\",\"cmd\":\"new\"}\n" ++
            "{\"id\":\"9\",\"cmd\":\"resume\",\"arg\":\"404\"}\n" ++
            "{\"id\":\"10\",\"cmd\":\"upgrade\"}\n" ++
            "{\"id\":\"11\",\"cmd\":\"upgrade\"}\n" ++
            "{\"id\":\"12\",\"cmd\":\"quit\"}\n",
    );
    var out_buf: [32768]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);
    var rows = AuditRows{};
    defer rows.deinit(std.testing.allocator);

    const sid = try execWithIoHooks(
        std.testing.allocator,
        cfg,
        &in_fbs,
        &out_fbs,
        .{
            .audit_emitter = &rows.emitter,
            .now_ms = struct {
                fn f() i64 {
                    return 888;
                }
            }.f,
            .run_upgrade = struct {
                var n: usize = 0;

                fn f(alloc: std.mem.Allocator, _: update_mod.AuditHooks) !update_mod.Outcome {
                    defer n += 1;
                    if (n == 0) {
                        return .{
                            .ok = true,
                            .msg = try alloc.dupe(u8, "already up to date\n"),
                        };
                    }
                    return .{
                        .ok = false,
                        .msg = try alloc.dupe(u8, "upgrade blocked by policy\n"),
                    };
                }
            }.f,
        },
    );
    defer std.testing.allocator.free(sid);

    var filtered = std.ArrayList([]const u8).empty;
    defer filtered.deinit(std.testing.allocator);
    for (rows.rows.items) |row| {
        if (std.mem.indexOf(u8, row, "\"sid\":\"runtime\"") == null) continue;
        try filtered.append(std.testing.allocator, row);
    }
    const joined = try std.mem.join(std.testing.allocator, "\n", filtered.items);
    defer std.testing.allocator.free(joined);
    try oh.snap(@src(),
        \\[]u8
        \\  "{"v":1,"ts_ms":888,"sid":"runtime","seq":1,"kind":"tool","sev":"info","out":"ok","actor":{"kind":"sys"},"res":{"kind":"cfg","name":{"text":"runtime","vis":"pub"},"op":"provider"},"msg":{"text":"runtime control start","vis":"pub"},"data":{"name":{"text":"runtime","vis":"pub"},"call_id":"provider","argv":{"text":"p2","vis":"pub"}},"attrs":[]}
        \\{"v":1,"ts_ms":888,"sid":"runtime","seq":2,"kind":"tool","sev":"notice","out":"ok","actor":{"kind":"sys"},"res":{"kind":"cfg","name":{"text":"runtime","vis":"pub"},"op":"provider"},"msg":{"text":"runtime control success","vis":"pub"},"data":{"name":{"text":"runtime","vis":"pub"},"call_id":"provider","argv":{"text":"p2","vis":"pub"}},"attrs":[]}
        \\{"v":1,"ts_ms":888,"sid":"runtime","seq":3,"kind":"tool","sev":"info","out":"ok","actor":{"kind":"sys"},"res":{"kind":"cfg","name":{"text":"runtime","vis":"pub"},"op":"model"},"msg":{"text":"runtime control start","vis":"pub"},"data":{"name":{"text":"runtime","vis":"pub"},"call_id":"model","argv":{"text":"m2","vis":"pub"}},"attrs":[{"key":"provider","vis":"pub","ty":"str","val":"p3"}]}
        \\{"v":1,"ts_ms":888,"sid":"runtime","seq":4,"kind":"tool","sev":"notice","out":"ok","actor":{"kind":"sys"},"res":{"kind":"cfg","name":{"text":"runtime","vis":"pub"},"op":"model"},"msg":{"text":"runtime control success","vis":"pub"},"data":{"name":{"text":"runtime","vis":"pub"},"call_id":"model","argv":{"text":"m2","vis":"pub"}},"attrs":[{"key":"provider","vis":"pub","ty":"str","val":"p3"}]}
        \\{"v":1,"ts_ms":888,"sid":"runtime","seq":5,"kind":"tool","sev":"info","out":"ok","actor":{"kind":"sys"},"res":{"kind":"cfg","name":{"text":"runtime","vis":"pub"},"op":"tools"},"msg":{"text":"runtime control start","vis":"pub"},"data":{"name":{"text":"runtime","vis":"pub"},"call_id":"tools","argv":{"text":"bogus","vis":"pub"}},"attrs":[]}
        \\{"v":1,"ts_ms":888,"sid":"runtime","seq":6,"kind":"tool","sev":"err","out":"fail","actor":{"kind":"sys"},"res":{"kind":"cfg","name":{"text":"runtime","vis":"pub"},"op":"tools"},"msg":{"text":"[mask:24d3ce8fa6053fec]","vis":"mask"},"data":{"name":{"text":"runtime","vis":"pub"},"call_id":"tools","argv":{"text":"bogus","vis":"pub"}},"attrs":[]}
        \\{"v":1,"ts_ms":888,"sid":"runtime","seq":7,"kind":"tool","sev":"info","out":"ok","actor":{"kind":"sys"},"res":{"kind":"cfg","name":{"text":"runtime","vis":"pub"},"op":"tools"},"msg":{"text":"runtime control start","vis":"pub"},"data":{"name":{"text":"runtime","vis":"pub"},"call_id":"tools","argv":{"text":"read,skill","vis":"pub"}},"attrs":[]}
        \\{"v":1,"ts_ms":888,"sid":"runtime","seq":8,"kind":"tool","sev":"notice","out":"ok","actor":{"kind":"sys"},"res":{"kind":"cfg","name":{"text":"runtime","vis":"pub"},"op":"tools"},"msg":{"text":"runtime control success","vis":"pub"},"data":{"name":{"text":"runtime","vis":"pub"},"call_id":"tools","argv":{"text":"read,skill","vis":"pub"}},"attrs":[{"key":"tools","vis":"pub","ty":"str","val":"read,skill"}]}
        \\{"v":1,"ts_ms":888,"sid":"runtime","seq":9,"kind":"tool","sev":"info","out":"ok","actor":{"kind":"sys"},"res":{"kind":"sess","name":{"text":"session","vis":"pub"},"op":"resume"},"msg":{"text":"runtime control start","vis":"pub"},"data":{"name":{"text":"runtime","vis":"pub"},"call_id":"resume","argv":{"text":"[mask:1f9a8dd2d2543fe7]","vis":"mask"}},"attrs":[]}
        \\{"v":1,"ts_ms":888,"sid":"runtime","seq":10,"kind":"tool","sev":"notice","out":"ok","actor":{"kind":"sys"},"res":{"kind":"sess","name":{"text":"session","vis":"pub"},"op":"resume"},"msg":{"text":"runtime control success","vis":"pub"},"data":{"name":{"text":"runtime","vis":"pub"},"call_id":"resume","argv":{"text":"[mask:1f9a8dd2d2543fe7]","vis":"mask"}},"attrs":[]}
        \\{"v":1,"ts_ms":888,"sid":"runtime","seq":11,"kind":"tool","sev":"info","out":"ok","actor":{"kind":"sys"},"res":{"kind":"sess","name":{"text":"session","vis":"pub"},"op":"fork"},"msg":{"text":"runtime control start","vis":"pub"},"data":{"name":{"text":"runtime","vis":"pub"},"call_id":"fork","argv":{"text":"[mask:c89ec3c8c9704dbe]","vis":"mask"}},"attrs":[]}
        \\{"v":1,"ts_ms":888,"sid":"runtime","seq":12,"kind":"tool","sev":"notice","out":"ok","actor":{"kind":"sys"},"res":{"kind":"sess","name":{"text":"session","vis":"pub"},"op":"fork"},"msg":{"text":"runtime control success","vis":"pub"},"data":{"name":{"text":"runtime","vis":"pub"},"call_id":"fork","argv":{"text":"[mask:c89ec3c8c9704dbe]","vis":"mask"}},"attrs":[]}
        \\{"v":1,"ts_ms":888,"sid":"runtime","seq":13,"kind":"tool","sev":"info","out":"ok","actor":{"kind":"sys"},"res":{"kind":"sess","name":{"text":"session","vis":"pub"},"op":"compact"},"msg":{"text":"runtime control start","vis":"pub"},"data":{"name":{"text":"runtime","vis":"pub"},"call_id":"compact"},"attrs":[]}
        \\{"v":1,"ts_ms":888,"sid":"runtime","seq":14,"kind":"tool","sev":"notice","out":"ok","actor":{"kind":"sys"},"res":{"kind":"sess","name":{"text":"session","vis":"pub"},"op":"compact"},"msg":{"text":"runtime control success","vis":"pub"},"data":{"name":{"text":"runtime","vis":"pub"},"call_id":"compact"},"attrs":[{"key":"in_lines","vis":"pub","ty":"uint","val":3},{"key":"out_lines","vis":"pub","ty":"uint","val":3}]}
        \\{"v":1,"ts_ms":888,"sid":"runtime","seq":15,"kind":"tool","sev":"info","out":"ok","actor":{"kind":"sys"},"res":{"kind":"sess","name":{"text":"session","vis":"pub"},"op":"new"},"msg":{"text":"runtime control start","vis":"pub"},"data":{"name":{"text":"runtime","vis":"pub"},"call_id":"new"},"attrs":[]}
        \\{"v":1,"ts_ms":888,"sid":"runtime","seq":16,"kind":"tool","sev":"notice","out":"ok","actor":{"kind":"sys"},"res":{"kind":"sess","name":{"text":"session","vis":"pub"},"op":"new"},"msg":{"text":"runtime control success","vis":"pub"},"data":{"name":{"text":"runtime","vis":"pub"},"call_id":"new"},"attrs":[]}
        \\{"v":1,"ts_ms":888,"sid":"runtime","seq":17,"kind":"tool","sev":"info","out":"ok","actor":{"kind":"sys"},"res":{"kind":"sess","name":{"text":"session","vis":"pub"},"op":"resume"},"msg":{"text":"runtime control start","vis":"pub"},"data":{"name":{"text":"runtime","vis":"pub"},"call_id":"resume","argv":{"text":"[mask:9820c0c43c1a6dc0]","vis":"mask"}},"attrs":[]}
        \\{"v":1,"ts_ms":888,"sid":"runtime","seq":18,"kind":"tool","sev":"err","out":"fail","actor":{"kind":"sys"},"res":{"kind":"sess","name":{"text":"session","vis":"pub"},"op":"resume"},"msg":{"text":"[mask:a3d269af3f28886b]","vis":"mask"},"data":{"name":{"text":"runtime","vis":"pub"},"call_id":"resume","argv":{"text":"[mask:9820c0c43c1a6dc0]","vis":"mask"}},"attrs":[]}
        \\{"v":1,"ts_ms":888,"sid":"runtime","seq":19,"kind":"tool","sev":"info","out":"ok","actor":{"kind":"sys"},"res":{"kind":"cmd","name":{"text":"upgrade","vis":"pub"},"op":"upgrade"},"msg":{"text":"runtime control start","vis":"pub"},"data":{"name":{"text":"runtime","vis":"pub"},"call_id":"upgrade"},"attrs":[]}
        \\{"v":1,"ts_ms":888,"sid":"runtime","seq":20,"kind":"tool","sev":"notice","out":"ok","actor":{"kind":"sys"},"res":{"kind":"cmd","name":{"text":"upgrade","vis":"pub"},"op":"upgrade"},"msg":{"text":"runtime control success","vis":"pub"},"data":{"name":{"text":"runtime","vis":"pub"},"call_id":"upgrade"},"attrs":[]}
        \\{"v":1,"ts_ms":888,"sid":"runtime","seq":21,"kind":"tool","sev":"info","out":"ok","actor":{"kind":"sys"},"res":{"kind":"cmd","name":{"text":"upgrade","vis":"pub"},"op":"upgrade"},"msg":{"text":"runtime control start","vis":"pub"},"data":{"name":{"text":"runtime","vis":"pub"},"call_id":"upgrade"},"attrs":[]}
        \\{"v":1,"ts_ms":888,"sid":"runtime","seq":22,"kind":"tool","sev":"err","out":"fail","actor":{"kind":"sys"},"res":{"kind":"cmd","name":{"text":"upgrade","vis":"pub"},"op":"upgrade"},"msg":{"text":"[mask:72a5bdd8c44d96df]","vis":"mask"},"data":{"name":{"text":"runtime","vis":"pub"},"call_id":"upgrade"},"attrs":[]}"
    ).expectEqual(joined);
}

test "runtime bg command validates usage and missing ids" {
    var mgr = try bg.Manager.init(std.testing.allocator);
    defer mgr.deinit();

    const usage = try runBgCommand(std.testing.allocator, &mgr, "");
    defer std.testing.allocator.free(usage);
    try std.testing.expectEqualStrings("usage: /bg run <cmd>|list|show <id>|stop <id>\n", usage);

    const run_usage = try runBgCommand(std.testing.allocator, &mgr, "run");
    defer std.testing.allocator.free(run_usage);
    try std.testing.expectEqualStrings("usage: /bg run <cmd>\n", run_usage);

    const show_usage = try runBgCommand(std.testing.allocator, &mgr, "show nope");
    defer std.testing.allocator.free(show_usage);
    try std.testing.expectEqualStrings("usage: /bg show <id>\n", show_usage);

    const stop_usage = try runBgCommand(std.testing.allocator, &mgr, "stop nope");
    defer std.testing.allocator.free(stop_usage);
    try std.testing.expectEqualStrings("usage: /bg stop <id>\n", stop_usage);

    const not_found = try runBgCommand(std.testing.allocator, &mgr, "show 42");
    defer std.testing.allocator.free(not_found);
    try std.testing.expectEqualStrings("bg: not found\n", not_found);

    const stop_not_found = try runBgCommand(std.testing.allocator, &mgr, "stop 42");
    defer std.testing.allocator.free(stop_not_found);
    try std.testing.expectEqualStrings("bg not found id=42\n", stop_not_found);

    const bad_sub = try runBgCommand(std.testing.allocator, &mgr, "wat");
    defer std.testing.allocator.free(bad_sub);
    try std.testing.expectEqualStrings("usage: /bg run <cmd>|list|show <id>|stop <id>\n", bad_sub);
}

test "UX8 walkthrough: bg run spawns job, bg list shows it, bg show shows detail, reload refreshes context" {
    var mgr = try bg.Manager.init(std.testing.allocator);
    defer mgr.deinit();

    // /bg run spawns a job
    const started = try runBgCommand(std.testing.allocator, &mgr, "run echo hello");
    defer std.testing.allocator.free(started);
    try std.testing.expect(std.mem.indexOf(u8, started, "bg started id=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, started, "pid=") != null);

    // /bg list shows running jobs
    const listed = try runBgCommand(std.testing.allocator, &mgr, "list");
    defer std.testing.allocator.free(listed);
    try std.testing.expect(std.mem.indexOf(u8, listed, "id pid state code log cmd\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed, "echo hello\n") != null);

    // /bg show shows job detail
    const shown = try runBgCommand(std.testing.allocator, &mgr, "show 1");
    defer std.testing.allocator.free(shown);
    try std.testing.expect(std.mem.indexOf(u8, shown, "id=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, shown, "state=") != null);
    try std.testing.expect(std.mem.indexOf(u8, shown, "cmd=echo hello\n") != null);

    // /reload refreshes context (load returns new content)
    var rows = AuditRows{};
    defer rows.deinit(std.testing.allocator);
    var ctl_audit = RuntimeCtlAudit{ .hooks = .{
        .audit_emitter = &rows.emitter,
        .now_ms = struct {
            fn f() i64 {
                return 500;
            }
        }.f,
    } };
    var sys_prompt: ?[]const u8 = null;
    var sys_prompt_owned: ?[]u8 = null;
    defer if (sys_prompt_owned) |buf| std.testing.allocator.free(buf);

    const res = try reloadContextWithAudit(
        std.testing.allocator,
        &sys_prompt,
        &sys_prompt_owned,
        &ctl_audit,
        struct {
            fn f(alloc: std.mem.Allocator, _: std.Io, _: ?[]const u8) !?[]u8 {
                return try alloc.dupe(u8, "refreshed context");
            }
        }.f,
        null,
    );
    try std.testing.expectEqual(ReloadRes.loaded, res);
    try std.testing.expectEqualStrings("refreshed context", sys_prompt.?);
    try std.testing.expect(rows.rows.items.len >= 2); // start + success
}

test "parseCmdToolMask fuzz smoke does not panic" {
    var prng = std.Random.DefaultPrng.init(0x5EED_F00D);
    const rnd = prng.random();

    var buf: [64]u8 = undefined;
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        const n = rnd.intRangeAtMost(usize, 0, buf.len);
        var j: usize = 0;
        while (j < n) : (j += 1) {
            const pick = rnd.intRangeAtMost(u8, 0, 9);
            buf[j] = switch (pick) {
                0 => ',',
                1 => ' ',
                2 => 'r',
                3 => 'w',
                4 => 'b',
                5 => 'a',
                6 => 's',
                7 => 'l',
                8 => 'g',
                else => 'x',
            };
        }
        _ = parseCmdToolMask(buf[0..n]) catch {}; // test: error irrelevant
    }
}

test "parseCmdToolMask accepts skill" {
    const got = try parseCmdToolMask("read,skill");
    try std.testing.expectEqual(core.tools.builtin.mask_read | core.tools.builtin.mask_skill, got);
}

test "toolMaskCsvAlloc includes skill" {
    const got = try toolMaskCsvAlloc(
        std.testing.allocator,
        core.tools.builtin.mask_read | core.tools.builtin.mask_skill,
    );
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("read,skill", got);
}

test "chooseLogoutProvider picks active provider when available" {
    const logged_in = [_]core.providers.auth.Provider{ .anthropic, .openai };
    const picked = chooseLogoutProvider("anthropic", &logged_in) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(core.providers.auth.Provider.anthropic, picked);
}

test "chooseLogoutProvider falls back to single logged-in provider" {
    const logged_in = [_]core.providers.auth.Provider{.openai};
    const picked = chooseLogoutProvider("anthropic", &logged_in) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(core.providers.auth.Provider.openai, picked);
}

test "chooseLogoutProvider returns null when ambiguous" {
    const logged_in = [_]core.providers.auth.Provider{ .openai, .google };
    try std.testing.expect(chooseLogoutProvider("anthropic", &logged_in) == null);
}

test "classifyLoginInput treats anthropic empty arg as oauth start" {
    const got = classifyLoginInput(.anthropic, "");
    try std.testing.expectEqual(LoginInputKind.oauth_start, got);
}

test "classifyLoginInput keeps anthropic api key flow" {
    const got = classifyLoginInput(.anthropic, "sk-ant-api03-123");
    try std.testing.expectEqual(LoginInputKind.api_key, got);
}

test "classifyLoginInput treats anthropic callback payload as oauth complete" {
    const got = classifyLoginInput(.anthropic, "http://localhost:64915/callback?code=abc&state=def");
    try std.testing.expectEqual(LoginInputKind.oauth_complete, got);
}

test "classifyLoginInput treats openai empty arg as oauth start" {
    const got = classifyLoginInput(.openai, "");
    try std.testing.expectEqual(LoginInputKind.oauth_start, got);
}

test "classifyLoginInput keeps openai api key flow" {
    const got = classifyLoginInput(.openai, "sk-proj-123");
    try std.testing.expectEqual(LoginInputKind.api_key, got);
}

test "classifyLoginInput treats openai callback payload as oauth complete" {
    const got = classifyLoginInput(.openai, "http://localhost:1455/auth/callback?code=abc&state=def");
    try std.testing.expectEqual(LoginInputKind.oauth_complete, got);
}

test "classifyLoginInput treats openai raw query payload as oauth complete" {
    const got = classifyLoginInput(.openai, "code=abc&state=def");
    try std.testing.expectEqual(LoginInputKind.oauth_complete, got);
}

test "classifyLoginInput keeps google in api key mode" {
    const got = classifyLoginInput(.google, "");
    try std.testing.expectEqual(LoginInputKind.api_key, got);
}

test "classifyLoginInput keeps google key input in api key mode" {
    const got = classifyLoginInput(.google, "ya29-token");
    try std.testing.expectEqual(LoginInputKind.api_key, got);
}

test "resolveArgSrc maps slash command names to completion sources" {
    const models = [_][]const u8{ "m1", "m2" };

    const model_src = resolveArgSrc("/model ", &models) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("m1", model_src[0]);

    const provider_src = resolveArgSrc("/provider ", &models) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("anthropic", provider_src[0]);

    const login_src = resolveArgSrc("/login ", &models) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("openai", login_src[1]);

    const bg_src = resolveArgSrc("/bg ", &models) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("run", bg_src[0]);

    try std.testing.expect(resolveArgSrc("/unknown ", &models) == null);
    try std.testing.expect(resolveArgSrc("plain", &models) == null);
}

test "runtime bg command run show list workflow" {
    var mgr = try bg.Manager.init(std.testing.allocator);
    defer mgr.deinit();

    const started = try runBgCommand(std.testing.allocator, &mgr, "run sleep 1");
    defer std.testing.allocator.free(started);
    try std.testing.expect(std.mem.indexOf(u8, started, "bg started id=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, started, "pid=") != null);
    try std.testing.expect(std.mem.indexOf(u8, started, "pz-bg-") != null);

    const shown = try runBgCommand(std.testing.allocator, &mgr, "show 1");
    defer std.testing.allocator.free(shown);
    try std.testing.expect(std.mem.indexOf(u8, shown, "id=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, shown, "pid=") != null);
    try std.testing.expect(std.mem.indexOf(u8, shown, "state=") != null);
    try std.testing.expect(std.mem.indexOf(u8, shown, "cmd=sleep 1\n") != null);

    const listed = try runBgCommand(std.testing.allocator, &mgr, "list");
    defer std.testing.allocator.free(listed);
    try std.testing.expect(std.mem.indexOf(u8, listed, "id pid state code log cmd\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed, " sleep 1\n") != null);

    const stopped = try runBgCommand(std.testing.allocator, &mgr, "stop 1");
    defer std.testing.allocator.free(stopped);
    try std.testing.expect(
        std.mem.indexOf(u8, stopped, "bg stop sent id=1\n") != null or
            std.mem.indexOf(u8, stopped, "bg already done id=1\n") != null,
    );
}

test "runtime tui tools command updates tool availability per turn" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sess");
    const sess_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "sess");
    defer std.testing.allocator.free(sess_abs);

    const provider_cmd =
        "req=$(cat); " ++
        "if printf '%s' \"$req\" | grep -q '\"name\":\"bash\"'; then " ++
        "printf 'text:has-bash\\nstop:done\\n'; " ++
        "else " ++
        "printf 'text:no-bash\\nstop:done\\n'; " ++
        "fi";

    var cfg = cli.Run{
        .mode = .tui,
        .prompt = null,
        .cfg = .{
            .mode = .tui,
            .model = try std.testing.allocator.dupe(u8, "m"),
            .provider = try std.testing.allocator.dupe(u8, "p"),
            .session_dir = try std.testing.allocator.dupe(u8, sess_abs),
            .provider_cmd = try std.testing.allocator.dupe(u8, provider_cmd),
        },
    };
    defer cfg.cfg.deinit(std.testing.allocator);

    var in_fbs: std.Io.Reader = .fixed("/tools read\none\n/tools all\ntwo\n/quit\n");
    var out_buf: [65536]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const sid = try execWithIo(
        std.testing.allocator,
        cfg,
        &in_fbs,
        &out_fbs,
    );
    defer std.testing.allocator.free(sid);

    const written = out_fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "tools set to read") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "no-bash") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "has-bash") != null);
}

test "runtime rpc tools command updates tool availability per turn" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sess");
    const sess_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "sess");
    defer std.testing.allocator.free(sess_abs);

    const provider_cmd =
        "req=$(cat); " ++
        "if printf '%s' \"$req\" | grep -q '\"name\":\"bash\"'; then " ++
        "printf 'text:has-bash\\nstop:done\\n'; " ++
        "else " ++
        "printf 'text:no-bash\\nstop:done\\n'; " ++
        "fi";

    var cfg = cli.Run{
        .mode = .rpc,
        .prompt = null,
        .cfg = .{
            .mode = .rpc,
            .model = try std.testing.allocator.dupe(u8, "m"),
            .provider = try std.testing.allocator.dupe(u8, "p"),
            .session_dir = try std.testing.allocator.dupe(u8, sess_abs),
            .provider_cmd = try std.testing.allocator.dupe(u8, provider_cmd),
        },
    };
    defer cfg.cfg.deinit(std.testing.allocator);

    var in_fbs: std.Io.Reader = .fixed(
        "{\"cmd\":\"tools\",\"arg\":\"read\"}\n" ++
            "{\"cmd\":\"prompt\",\"text\":\"one\"}\n" ++
            "{\"cmd\":\"tools\",\"arg\":\"all\"}\n" ++
            "{\"cmd\":\"prompt\",\"text\":\"two\"}\n" ++
            "{\"cmd\":\"quit\"}\n",
    );
    var out_buf: [65536]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const sid = try execWithIo(
        std.testing.allocator,
        cfg,
        &in_fbs,
        &out_fbs,
    );
    defer std.testing.allocator.free(sid);

    const written = out_fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"cmd\":\"tools\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "no-bash") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "has-bash") != null);
}

test "showLogoutOverlay builds overlay and frees on deinit" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};
    const alloc = std.testing.allocator;
    var ui = try tui_harness.Ui.init(alloc, 80, 12, "m", "p");
    defer ui.deinit();

    // Empty providers: no overlay created, no leak.
    {
        const provs = try alloc.alloc(core.providers.auth.Provider, 0);
        defer alloc.free(provs);
        try std.testing.expect(!try showLogoutOverlay(alloc, &ui, provs));
        try std.testing.expect(ui.ov == null);
    }

    // Two providers: overlay created with dyn_items.
    {
        var provs = try alloc.alloc(core.providers.auth.Provider, 2);
        defer alloc.free(provs);
        provs[0] = .anthropic;
        provs[1] = .openai;
        try std.testing.expect(try showLogoutOverlay(alloc, &ui, provs));
        try std.testing.expect(ui.ov != null);
        try std.testing.expect(ui.ov.?.dyn_items != null);
        try oh.snap(@src(),
            \\[][]u8
            \\  [0]: []u8
            \\    "anthropic"
            \\  [1]: []u8
            \\    "openai"
        ).expectEqual(ui.ov.?.dyn_items.?);
        ui.ov.?.deinit(alloc);
        ui.ov = null;
    }
}

test "slash logout without explicit provider frees logged-in list cleanly" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "sess");
    try tmp.dir.createDirPath(std.testing.io, "home");

    const sess_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "sess");
    defer std.testing.allocator.free(sess_abs);
    const home_abs = try testRealPathAlloc(std.testing.allocator, tmp.dir, "home");
    defer std.testing.allocator.free(home_abs);

    var cfg = cli.Run{
        .mode = .tui,
        .prompt = null,
        .cfg = .{
            .mode = .tui,
            .model = try std.testing.allocator.dupe(u8, "m"),
            .provider = try std.testing.allocator.dupe(u8, "openai"),
            .session_dir = try std.testing.allocator.dupe(u8, sess_abs),
            .provider_cmd = try std.testing.allocator.dupe(u8, "cat >/dev/null; printf 'text:noop\\nstop:done\\n'"),
        },
    };
    defer cfg.cfg.deinit(std.testing.allocator);

    var in_fbs: std.Io.Reader = .fixed("/login openai sk-openai-secret\n/logout\n/quit\n");
    var out_buf: [32768]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const sid = try execWithIoHooks(
        std.testing.allocator,
        cfg,
        &in_fbs,
        &out_fbs,
        .{
            .auth_home = home_abs,
        },
    );
    defer std.testing.allocator.free(sid);

    const written = out_fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "direct provider login disabled by policy") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "no providers logged in") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "API key saved for openai") == null);
}

test "LiveTurn tracks last_stop last_err and last_model" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};
    const alloc = std.testing.allocator;
    var lt = try LiveTurn.init(alloc);
    defer lt.deinit();

    // Enqueue stop event
    try lt.enqueueProvider(.{ .stop = .{ .reason = .max_out } });

    // Enqueue err event
    try lt.enqueueProvider(.{ .err = "bad request" });

    // Drain events
    const ev1 = lt.popProvider().?;
    defer freeProviderEv(alloc, ev1.ev);
    const ev2 = lt.popProvider().?;
    defer freeProviderEv(alloc, ev2.ev);
    try std.testing.expect(lt.popProvider() == null);

    // Overwrite err
    try lt.enqueueProvider(.{ .err = "timeout" });
    const ev3 = lt.popProvider().?;
    defer freeProviderEv(alloc, ev3.ev);
    const first = try std.fmt.allocPrint(
        alloc,
        "last_stop={s} last_err={?s} last_model={?s} seqs={},{},{}",
        .{ @tagName(lt.last_stop.?), lt.last_err, lt.last_model, ev1.seq, ev2.seq, ev3.seq },
    );
    defer alloc.free(first);
    try oh.snap(@src(),
        \\[]u8
        \\  "last_stop=max_out last_err=timeout last_model=null seqs=1,2,3"
    ).expectEqual(first);

    // Simulate turn reset
    lt.mu.lock();
    lt.last_stop = null;
    if (lt.last_err) |e| {
        alloc.free(e);
        lt.last_err = null;
    }
    if (lt.last_model) |m| {
        alloc.free(m);
        lt.last_model = null;
    }
    lt.last_model = try alloc.dupe(u8, "claude-opus-4-20250918");
    lt.mu.unlock();
    const second = try std.fmt.allocPrint(
        alloc,
        "last_stop={s} last_err={?s} last_model={?s} seqs={},{},{}",
        .{ "null", lt.last_err, lt.last_model, ev1.seq, ev2.seq, ev3.seq },
    );
    defer alloc.free(second);
    try oh.snap(@src(),
        \\[]u8
        \\  "last_stop=null last_err=null last_model=claude-opus-4-20250918 seqs=1,2,3"
    ).expectEqual(second);
}

test "LiveTurn cloneReq duplicates retained request" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};
    const alloc = std.testing.allocator;
    var lt = try LiveTurn.init(alloc);
    defer lt.deinit();

    lt.last_req = .{
        .sid = try alloc.dupe(u8, "sess-1"),
        .prompt = try alloc.dupe(u8, "hello"),
        .model = try alloc.dupe(u8, "m-1"),
        .provider_label = try alloc.dupe(u8, "p-1"),
        .provider_opts = .{ .temp = 0.2, .max_out = 42 },
        .system_prompt = try alloc.dupe(u8, "sys"),
    };

    const dup = (try lt.cloneReq(alloc)) orelse return error.TestUnexpectedResult;
    defer {
        var req = dup;
        req.deinit(alloc);
    }
    const snap = try std.fmt.allocPrint(
        alloc,
        "sid={s} prompt={s} model={s} provider={s} temp={d} max_out={} system={s}",
        .{
            dup.sid,
            dup.prompt,
            dup.model,
            dup.provider_label,
            dup.provider_opts.temp.?,
            dup.provider_opts.max_out.?,
            dup.system_prompt.?,
        },
    );
    defer alloc.free(snap);
    try oh.snap(@src(),
        \\[]u8
        \\  "sid=sess-1 prompt=hello model=m-1 provider=p-1 temp=0.2 max_out=42 system=sys"
    ).expectEqual(snap);
}

test "buildSystemPrompt rejects explicit prompt under policy lock" {
    var run = cli.Run{
        .mode = .tui,
        .prompt = null,
        .cfg = .{
            .mode = .tui,
            .model = try std.testing.allocator.dupe(u8, config.model_default),
            .provider = try std.testing.allocator.dupe(u8, config.provider_default),
            .session_dir = try std.testing.allocator.dupe(u8, config.session_dir_default),
            .policy_lock = .{ .system_prompt = true },
        },
        .system_prompt = "sys",
    };
    defer run.cfg.deinit(std.testing.allocator);

    try std.testing.expectError(error.PolicyLockedSystemPrompt, buildSystemPrompt(std.testing.allocator, run, null));
}

test "buildSystemPrompt rejects context under policy lock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "AGENTS.md", .data = "ctx" });
    const old = try testCwdRealPathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(old);
    const cwd = try testRealPathAlloc(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(cwd);
    try chdirPath(cwd);
    defer chdirPath(old) catch {}; // test: error irrelevant

    var run = cli.Run{
        .mode = .tui,
        .prompt = null,
        .cfg = .{
            .mode = .tui,
            .model = try std.testing.allocator.dupe(u8, config.model_default),
            .provider = try std.testing.allocator.dupe(u8, config.provider_default),
            .session_dir = try std.testing.allocator.dupe(u8, config.session_dir_default),
            .policy_lock = .{ .context = true },
        },
    };
    defer run.cfg.deinit(std.testing.allocator);

    try std.testing.expectError(error.PolicyLockedContext, buildSystemPrompt(std.testing.allocator, run, null));
}

test "shouldRetryOverflow gates retry to real overflow in same model once" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};
    const alloc = std.testing.allocator;
    var lt = try LiveTurn.init(alloc);
    defer lt.deinit();

    lt.last_model = try alloc.dupe(u8, "m-1");
    lt.last_stop = .max_out;
    const a = shouldRetryOverflow(alloc, &lt, "m-1", false);
    const b = shouldRetryOverflow(alloc, &lt, "m-2", false);
    const c = shouldRetryOverflow(alloc, &lt, "m-1", true);

    lt.last_stop = null;
    lt.last_err = try alloc.dupe(u8, "{\"error\":{\"code\":\"context_length_exceeded\"}}");
    const d = shouldRetryOverflow(alloc, &lt, "m-1", false);

    alloc.free(lt.last_err.?);
    lt.last_err = try alloc.dupe(u8, "400 Bad Request");
    const e = shouldRetryOverflow(alloc, &lt, "m-1", false);

    const snap = try std.fmt.allocPrint(alloc, "{any}\n{any}\n{any}\n{any}\n{any}\n", .{ a, b, c, d, e });
    defer alloc.free(snap);
    try oh.snap(@src(),
        \\[]u8
        \\  "true
        \\false
        \\false
        \\true
        \\false
        \\"
    ).expectEqual(snap);
}

test "shouldRetryOverflowState property: retried disables retry" {
    const zc = @import("zcheck");
    try zc.check(struct {
        fn prop(args: struct {
            err_text: zc.String,
            stop_max_out: bool,
        }) bool {
            return !shouldRetryOverflowState(
                std.testing.allocator,
                "m",
                if (args.stop_max_out) .max_out else null,
                args.err_text.slice(),
                "m",
                true,
            );
        }
    }.prop, .{ .iterations = 300 });
}

test "shouldRetryOverflowState property: model mismatch disables retry" {
    const zc = @import("zcheck");
    try zc.check(struct {
        fn prop(args: struct {
            err_text: zc.String,
            stop_max_out: bool,
        }) bool {
            return !shouldRetryOverflowState(
                std.testing.allocator,
                "model-a",
                if (args.stop_max_out) .max_out else null,
                args.err_text.slice(),
                "model-b",
                false,
            );
        }
    }.prop, .{ .iterations = 300 });
}

test "shouldRetryOverflowState property: max_out forces retry in same model" {
    const zc = @import("zcheck");
    try zc.check(struct {
        fn prop(args: struct { err_text: zc.String }) bool {
            return shouldRetryOverflowState(
                std.testing.allocator,
                "m",
                .max_out,
                args.err_text.slice(),
                "m",
                false,
            );
        }
    }.prop, .{ .iterations = 300 });
}

test "autoCompact draws compacting notice before compactor runs" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sess");
    const sess_abs = try testRealPathAlloc(alloc, tmp.dir, "sess");
    defer alloc.free(sess_abs);

    var ui = try tui_harness.Ui.init(alloc, 80, 12, "m", "p");
    defer ui.deinit();
    ui.panels.ctx_limit = 100;
    ui.panels.cum_tok = 90;
    ui.panels.has_usage = true;

    var out_buf: [16384]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const Ctx = struct {
        ui: *tui_harness.Ui,
        saw_notice: bool = false,

        fn run(raw: ?*anyopaque, _: std.mem.Allocator, _: std.Io.Dir, _: []const u8, _: i64) !CompactRun {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            for (self.ui.tr.blocks.items) |blk| {
                if (std.mem.eql(u8, blk.buf.items, "[compacting...]")) {
                    self.saw_notice = true;
                    return .compacted;
                }
            }
            return error.TestUnexpectedResult;
        }
    };

    var ctx = Ctx{ .ui = &ui };
    try std.testing.expectEqual(AutoCompactOutcome.compacted, try autoCompactWith(
        alloc,
        &ui,
        &out_fbs,
        "sess-1",
        sess_abs,
        false,
        false,
        &ctx,
        Ctx.run,
    ));
    try std.testing.expect(ctx.saw_notice);

    var snap: std.ArrayListUnmanaged(u8) = .empty;
    defer snap.deinit(alloc);
    for (ui.tr.blocks.items, 0..) |blk, i| {
        if (i != 0) try snap.append(alloc, '\n');
        try snap.appendSlice(alloc, blk.buf.items);
    }
    const snap_txt = try snap.toOwnedSlice(alloc);
    defer alloc.free(snap_txt);

    try oh.snap(@src(),
        \\[]u8
        \\  "[compacting...]
        \\[session compacted]"
    ).expectEqual(snap_txt);
    try std.testing.expect(std.mem.indexOf(u8, out_fbs.buffered(), "[compacting...]") != null);
}

test "autoCompact reports summary budget stop metadata" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sess");
    const sess_abs = try testRealPathAlloc(alloc, tmp.dir, "sess");
    defer alloc.free(sess_abs);

    var ui = try tui_harness.Ui.init(alloc, 80, 12, "m", "p");
    defer ui.deinit();
    ui.panels.ctx_limit = 100;
    ui.panels.cum_tok = 90;
    ui.panels.has_usage = true;

    var out_buf: [16384]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const Ctx = struct {
        fn run(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io.Dir, _: []const u8, _: i64) !CompactRun {
            return .{ .stopped = .{
                .outcome = .over_budget,
                .input_bytes = 90210,
                .input_tokens = 8192,
                .max_bytes = 65536,
                .max_input_tokens = 4096,
                .kept_events = 3,
                .dropped_events = 17,
            } };
        }
    };

    try std.testing.expectEqual(AutoCompactOutcome.stopped, try autoCompactWith(
        alloc,
        &ui,
        &out_fbs,
        "sess-1",
        sess_abs,
        false,
        false,
        null,
        Ctx.run,
    ));

    var snap: std.ArrayListUnmanaged(u8) = .empty;
    defer snap.deinit(alloc);
    for (ui.tr.blocks.items, 0..) |blk, i| {
        if (i != 0) try snap.append(alloc, '\n');
        try snap.appendSlice(alloc, blk.buf.items);
    }
    const snap_txt = try snap.toOwnedSlice(alloc);
    defer alloc.free(snap_txt);

    try oh.snap(@src(),
        \\[]u8
        \\  "[compacting...]
        \\[auto-compact stopped: summary input over budget bytes=90210/65536 tokens=8192/4096 kept=3 dropped=17]"
    ).expectEqual(snap_txt);
    try std.testing.expect(std.mem.indexOf(u8, out_fbs.buffered(), "[compacting...]") != null);
}

test "resolveAbsCmd rejects PATH-only commands" {
    const alloc = std.testing.allocator;
    // Candidates that do not exist as absolute paths.
    const bogus = &[_][]const u8{ "/nonexistent/bin/xyz123", "/also/missing/xyz123" };
    // Must fail — PATH is never consulted.
    try std.testing.expectError(error.CmdNotFound, resolveAbsCmd(alloc, std.testing.io, bogus));
}

test "resolveAbsCmd finds existing absolute path" {
    const alloc = std.testing.allocator;
    // /bin/sh exists on all POSIX systems.
    const candidates = &[_][]const u8{ "/nonexistent/bin/nope", "/bin/sh" };
    const result = try resolveAbsCmd(alloc, std.testing.io, candidates);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("/bin/sh", result);
}

test "P0-4 regression: AskUiCtx stored/sel_by_q alloc+free no leaks" {
    // Exercises the StoredAnswer and sel_by_q allocation path that AskUiCtx
    // uses internally. std.testing.allocator catches any leaks.
    const alloc = std.testing.allocator;

    // Allocate stored answers exactly as runWithReader does.
    const n: usize = 5;
    var stored = try alloc.alloc(AskUiCtx.StoredAnswer, n);
    defer {
        for (stored) |a| {
            if (a.answer) |txt| alloc.free(txt);
        }
        alloc.free(stored);
    }
    for (stored) |*a| a.* = .{};

    const sel_by_q = try alloc.alloc(usize, n);
    defer alloc.free(sel_by_q);
    @memset(sel_by_q, 0);

    // Simulate setting answers (as setStoredAnswer does).
    stored[0].answer = try alloc.dupe(u8, "first answer");
    stored[0].index = 0;
    stored[2].answer = try alloc.dupe(u8, "third answer");
    stored[2].index = 2;

    // Overwrite an answer (the old one must be freed, as setStoredAnswer does).
    alloc.free(stored[0].answer.?);
    stored[0].answer = try alloc.dupe(u8, "updated first");
    stored[0].index = 0;

    // Verify firstUnanswered works correctly with our stored state.
    try std.testing.expectEqual(@as(?usize, 1), firstUnanswered(stored[0..]));

    // Collect answers and free them.
    const opts = [_]core.tools.Call.AskArgs.Option{
        .{ .label = "A" },
        .{ .label = "B" },
    };
    const qs = [_]core.tools.Call.AskArgs.Question{
        .{ .id = "q0", .question = "Q0", .options = opts[0..], .allow_other = false },
        .{ .id = "q1", .question = "Q1", .options = opts[0..], .allow_other = false },
        .{ .id = "q2", .question = "Q2", .options = opts[0..], .allow_other = true },
        .{ .id = "q3", .question = "Q3", .options = opts[0..], .allow_other = false },
        .{ .id = "q4", .question = "Q4", .options = opts[0..], .allow_other = false },
    };
    const answers = try collectAskAnswers(alloc, qs[0..], stored[0..]);
    defer alloc.free(answers);
    try std.testing.expectEqual(@as(usize, 2), answers.len);

    const payload = try buildAskResult(alloc, false, answers);
    defer alloc.free(payload);
    try std.testing.expect(payload.len > 0);
}

// --- UX6: Session walkthrough tests ---

fn slashHelper(
    alloc: std.mem.Allocator,
    line: []const u8,
    sid: *([]u8),
    model: *([]const u8),
    model_owned: *?[]u8,
    provider: *([]const u8),
    provider_owned: *?[]u8,
    pol: *const RuntimePolicy,
    tools_rt: *core.tools.builtin.Runtime,
    bg_mgr: *bg.Manager,
    session_dir_path: ?[]const u8,
    no_session: bool,
    out: *std.Io.Writer,
    ctl_audit: *RuntimeCtlAudit,
) !CmdRes {
    return handleSlashCommand(
        alloc,
        line,
        sid,
        model,
        model_owned,
        provider,
        provider_owned,
        pol,
        tools_rt,
        bg_mgr,
        session_dir_path,
        no_session,
        null,
        out,
        .{},
        ctl_audit,
        null,
    );
}

test "UX6: /new creates clean session with new sid" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try tmp.dir.openDir(std.testing.io, ".", .{});
    defer root.close(std.testing.io);
    var guard = try path_guard.CwdGuard.enter(root);
    defer guard.deinit();
    var pol = try RuntimePolicy.load(alloc, defaultIo(), null);
    defer pol.deinit();

    var sid = try alloc.dupe(u8, "old-session");
    defer alloc.free(sid);
    var model: []const u8 = "m";
    var provider: []const u8 = "p";
    var model_owned: ?[]u8 = null;
    defer if (model_owned) |b| alloc.free(b);
    var provider_owned: ?[]u8 = null;
    defer if (provider_owned) |b| alloc.free(b);
    var tools_rt = core.tools.builtin.Runtime.init(.{ .alloc = alloc });
    defer tools_rt.deinit();
    var bg_mgr = try bg.Manager.init(alloc);
    defer bg_mgr.deinit();
    var ctl_audit = RuntimeCtlAudit{ .hooks = .{} };
    var out_buf: [512]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const got = try slashHelper(alloc, "/new", &sid, &model, &model_owned, &provider, &provider_owned, &pol, &tools_rt, &bg_mgr, null, true, &out_fbs, &ctl_audit);
    try std.testing.expectEqual(CmdRes.handled, got);
    // sid changed from original
    try std.testing.expect(!std.mem.eql(u8, sid, "old-session"));
    try std.testing.expect(std.mem.indexOf(u8, out_fbs.buffered(), "new session") != null);
}

test "UX6: /name persists session title" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "sess");
    const sess_abs = try testRealPathAlloc(alloc, tmp.dir, "sess");
    defer alloc.free(sess_abs);

    var root = try tmp.dir.openDir(std.testing.io, ".", .{});
    defer root.close(std.testing.io);
    var guard = try path_guard.CwdGuard.enter(root);
    defer guard.deinit();
    var pol = try RuntimePolicy.load(alloc, defaultIo(), null);
    defer pol.deinit();

    var sid = try alloc.dupe(u8, "100");
    defer alloc.free(sid);
    var model: []const u8 = "m";
    var provider: []const u8 = "p";
    var model_owned: ?[]u8 = null;
    defer if (model_owned) |b| alloc.free(b);
    var provider_owned: ?[]u8 = null;
    defer if (provider_owned) |b| alloc.free(b);
    var tools_rt = core.tools.builtin.Runtime.init(.{ .alloc = alloc });
    defer tools_rt.deinit();
    var bg_mgr = try bg.Manager.init(alloc);
    defer bg_mgr.deinit();
    var ctl_audit = RuntimeCtlAudit{ .hooks = .{} };
    var out_buf: [512]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const got = try slashHelper(alloc, "/name my-project", &sid, &model, &model_owned, &provider, &provider_owned, &pol, &tools_rt, &bg_mgr, sess_abs, false, &out_fbs, &ctl_audit);
    try std.testing.expectEqual(CmdRes.handled, got);
    try std.testing.expect(std.mem.indexOf(u8, out_fbs.buffered(), "session named: my-project") != null);
}

test "UX6: /name without arg shows usage" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try tmp.dir.openDir(std.testing.io, ".", .{});
    defer root.close(std.testing.io);
    var guard = try path_guard.CwdGuard.enter(root);
    defer guard.deinit();
    var pol = try RuntimePolicy.load(alloc, defaultIo(), null);
    defer pol.deinit();

    var sid = try alloc.dupe(u8, "s");
    defer alloc.free(sid);
    var model: []const u8 = "m";
    var provider: []const u8 = "p";
    var model_owned: ?[]u8 = null;
    defer if (model_owned) |b| alloc.free(b);
    var provider_owned: ?[]u8 = null;
    defer if (provider_owned) |b| alloc.free(b);
    var tools_rt = core.tools.builtin.Runtime.init(.{ .alloc = alloc });
    defer tools_rt.deinit();
    var bg_mgr = try bg.Manager.init(alloc);
    defer bg_mgr.deinit();
    var ctl_audit = RuntimeCtlAudit{ .hooks = .{} };
    var out_buf: [512]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const got = try slashHelper(alloc, "/name", &sid, &model, &model_owned, &provider, &provider_owned, &pol, &tools_rt, &bg_mgr, null, true, &out_fbs, &ctl_audit);
    try std.testing.expectEqual(CmdRes.handled, got);
    try std.testing.expect(std.mem.indexOf(u8, out_fbs.buffered(), "usage: /name") != null);
}

test "UX6: /resume with no arg returns select_session" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try tmp.dir.openDir(std.testing.io, ".", .{});
    defer root.close(std.testing.io);
    var guard = try path_guard.CwdGuard.enter(root);
    defer guard.deinit();
    var pol = try RuntimePolicy.load(alloc, defaultIo(), null);
    defer pol.deinit();

    var sid = try alloc.dupe(u8, "s");
    defer alloc.free(sid);
    var model: []const u8 = "m";
    var provider: []const u8 = "p";
    var model_owned: ?[]u8 = null;
    defer if (model_owned) |b| alloc.free(b);
    var provider_owned: ?[]u8 = null;
    defer if (provider_owned) |b| alloc.free(b);
    var tools_rt = core.tools.builtin.Runtime.init(.{ .alloc = alloc });
    defer tools_rt.deinit();
    var bg_mgr = try bg.Manager.init(alloc);
    defer bg_mgr.deinit();
    var ctl_audit = RuntimeCtlAudit{ .hooks = .{} };
    var out_buf: [512]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const got = try slashHelper(alloc, "/resume", &sid, &model, &model_owned, &provider, &provider_owned, &pol, &tools_rt, &bg_mgr, null, true, &out_fbs, &ctl_audit);
    try std.testing.expectEqual(CmdRes.select_session, got);
}

test "UX6: /resume with sid switches to that session" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "sess");
    const sess_abs = try testRealPathAlloc(alloc, tmp.dir, "sess");
    defer alloc.free(sess_abs);

    // Write a minimal session file so resume can find it.
    const events = [_]core.session.Event{
        .{ .at_ms = 1, .data = .{ .prompt = .{ .text = "hello" } } },
        .{ .at_ms = 2, .data = .{ .stop = .{ .reason = .done } } },
    };
    try writeSessionEventsFile(tmp, "sess/200.jsonl", &events);

    var root = try tmp.dir.openDir(std.testing.io, ".", .{});
    defer root.close(std.testing.io);
    var guard = try path_guard.CwdGuard.enter(root);
    defer guard.deinit();
    var pol = try RuntimePolicy.load(alloc, defaultIo(), null);
    defer pol.deinit();

    var sid = try alloc.dupe(u8, "100");
    defer alloc.free(sid);
    var model: []const u8 = "m";
    var provider: []const u8 = "p";
    var model_owned: ?[]u8 = null;
    defer if (model_owned) |b| alloc.free(b);
    var provider_owned: ?[]u8 = null;
    defer if (provider_owned) |b| alloc.free(b);
    var tools_rt = core.tools.builtin.Runtime.init(.{ .alloc = alloc });
    defer tools_rt.deinit();
    var bg_mgr = try bg.Manager.init(alloc);
    defer bg_mgr.deinit();
    var ctl_audit = RuntimeCtlAudit{ .hooks = .{} };
    var out_buf: [512]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const got = try slashHelper(alloc, "/resume 200", &sid, &model, &model_owned, &provider, &provider_owned, &pol, &tools_rt, &bg_mgr, sess_abs, false, &out_fbs, &ctl_audit);
    try std.testing.expectEqual(CmdRes.resumed, got);
    try std.testing.expectEqualStrings("200", sid);
    try std.testing.expect(std.mem.indexOf(u8, out_fbs.buffered(), "resumed session 200") != null);
}

test "UX6: /fork with no arg returns select_fork" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try tmp.dir.openDir(std.testing.io, ".", .{});
    defer root.close(std.testing.io);
    var guard = try path_guard.CwdGuard.enter(root);
    defer guard.deinit();
    var pol = try RuntimePolicy.load(alloc, defaultIo(), null);
    defer pol.deinit();

    var sid = try alloc.dupe(u8, "s");
    defer alloc.free(sid);
    var model: []const u8 = "m";
    var provider: []const u8 = "p";
    var model_owned: ?[]u8 = null;
    defer if (model_owned) |b| alloc.free(b);
    var provider_owned: ?[]u8 = null;
    defer if (provider_owned) |b| alloc.free(b);
    var tools_rt = core.tools.builtin.Runtime.init(.{ .alloc = alloc });
    defer tools_rt.deinit();
    var bg_mgr = try bg.Manager.init(alloc);
    defer bg_mgr.deinit();
    var ctl_audit = RuntimeCtlAudit{ .hooks = .{} };
    var out_buf: [512]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const got = try slashHelper(alloc, "/fork", &sid, &model, &model_owned, &provider, &provider_owned, &pol, &tools_rt, &bg_mgr, null, true, &out_fbs, &ctl_audit);
    try std.testing.expectEqual(CmdRes.select_fork, got);
}

test "UX6: /fork with sid copies session" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "sess");
    const sess_abs = try testRealPathAlloc(alloc, tmp.dir, "sess");
    defer alloc.free(sess_abs);

    const events = [_]core.session.Event{
        .{ .at_ms = 1, .data = .{ .prompt = .{ .text = "hello" } } },
        .{ .at_ms = 2, .data = .{ .stop = .{ .reason = .done } } },
    };
    try writeSessionEventsFile(tmp, "sess/300.jsonl", &events);

    var root = try tmp.dir.openDir(std.testing.io, ".", .{});
    defer root.close(std.testing.io);
    var guard = try path_guard.CwdGuard.enter(root);
    defer guard.deinit();
    var pol = try RuntimePolicy.load(alloc, defaultIo(), null);
    defer pol.deinit();

    var sid = try alloc.dupe(u8, "100");
    defer alloc.free(sid);
    var model: []const u8 = "m";
    var provider: []const u8 = "p";
    var model_owned: ?[]u8 = null;
    defer if (model_owned) |b| alloc.free(b);
    var provider_owned: ?[]u8 = null;
    defer if (provider_owned) |b| alloc.free(b);
    var tools_rt = core.tools.builtin.Runtime.init(.{ .alloc = alloc });
    defer tools_rt.deinit();
    var bg_mgr = try bg.Manager.init(alloc);
    defer bg_mgr.deinit();
    var ctl_audit = RuntimeCtlAudit{ .hooks = .{} };
    var out_buf: [512]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const got = try slashHelper(alloc, "/fork 300", &sid, &model, &model_owned, &provider, &provider_owned, &pol, &tools_rt, &bg_mgr, sess_abs, false, &out_fbs, &ctl_audit);
    try std.testing.expectEqual(CmdRes.handled, got);
    try std.testing.expect(std.mem.indexOf(u8, out_fbs.buffered(), "forked session") != null);
    // sid changed to the new fork
    try std.testing.expect(!std.mem.eql(u8, sid, "100"));
}

test "UX6: /compact on disabled session shows notice" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try tmp.dir.openDir(std.testing.io, ".", .{});
    defer root.close(std.testing.io);
    var guard = try path_guard.CwdGuard.enter(root);
    defer guard.deinit();
    var pol = try RuntimePolicy.load(alloc, defaultIo(), null);
    defer pol.deinit();

    var sid = try alloc.dupe(u8, "s");
    defer alloc.free(sid);
    var model: []const u8 = "m";
    var provider: []const u8 = "p";
    var model_owned: ?[]u8 = null;
    defer if (model_owned) |b| alloc.free(b);
    var provider_owned: ?[]u8 = null;
    defer if (provider_owned) |b| alloc.free(b);
    var tools_rt = core.tools.builtin.Runtime.init(.{ .alloc = alloc });
    defer tools_rt.deinit();
    var bg_mgr = try bg.Manager.init(alloc);
    defer bg_mgr.deinit();
    var ctl_audit = RuntimeCtlAudit{ .hooks = .{} };
    var out_buf: [512]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const got = try slashHelper(alloc, "/compact", &sid, &model, &model_owned, &provider, &provider_owned, &pol, &tools_rt, &bg_mgr, null, true, &out_fbs, &ctl_audit);
    try std.testing.expectEqual(CmdRes.handled, got);
    // Should report error about sessions being disabled
    try std.testing.expect(out_fbs.buffered().len > 0);
}

test "UX6: /export on disabled session shows error" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try tmp.dir.openDir(std.testing.io, ".", .{});
    defer root.close(std.testing.io);
    var guard = try path_guard.CwdGuard.enter(root);
    defer guard.deinit();
    var pol = try RuntimePolicy.load(alloc, defaultIo(), null);
    defer pol.deinit();

    var sid = try alloc.dupe(u8, "s");
    defer alloc.free(sid);
    var model: []const u8 = "m";
    var provider: []const u8 = "p";
    var model_owned: ?[]u8 = null;
    defer if (model_owned) |b| alloc.free(b);
    var provider_owned: ?[]u8 = null;
    defer if (provider_owned) |b| alloc.free(b);
    var tools_rt = core.tools.builtin.Runtime.init(.{ .alloc = alloc });
    defer tools_rt.deinit();
    var bg_mgr = try bg.Manager.init(alloc);
    defer bg_mgr.deinit();
    var ctl_audit = RuntimeCtlAudit{ .hooks = .{} };
    var out_buf: [512]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const got = try slashHelper(alloc, "/export out.md", &sid, &model, &model_owned, &provider, &provider_owned, &pol, &tools_rt, &bg_mgr, null, true, &out_fbs, &ctl_audit);
    try std.testing.expectEqual(CmdRes.handled, got);
    try std.testing.expect(out_fbs.buffered().len > 0);
}

test "UX6: /export writes file for valid session" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "sess");
    const sess_abs = try testRealPathAlloc(alloc, tmp.dir, "sess");
    defer alloc.free(sess_abs);

    const events = [_]core.session.Event{
        .{ .at_ms = 1, .data = .{ .prompt = .{ .text = "hello" } } },
        .{ .at_ms = 2, .data = .{ .text = .{ .text = "world" } } },
        .{ .at_ms = 3, .data = .{ .stop = .{ .reason = .done } } },
    };
    try writeSessionEventsFile(tmp, "sess/400.jsonl", &events);

    var root = try tmp.dir.openDir(std.testing.io, ".", .{});
    defer root.close(std.testing.io);
    var guard = try path_guard.CwdGuard.enter(root);
    defer guard.deinit();
    var pol = try RuntimePolicy.load(alloc, defaultIo(), null);
    defer pol.deinit();

    var sid = try alloc.dupe(u8, "400");
    defer alloc.free(sid);
    var model: []const u8 = "m";
    var provider: []const u8 = "p";
    var model_owned: ?[]u8 = null;
    defer if (model_owned) |b| alloc.free(b);
    var provider_owned: ?[]u8 = null;
    defer if (provider_owned) |b| alloc.free(b);
    var tools_rt = core.tools.builtin.Runtime.init(.{ .alloc = alloc });
    defer tools_rt.deinit();
    var bg_mgr = try bg.Manager.init(alloc);
    defer bg_mgr.deinit();
    var ctl_audit = RuntimeCtlAudit{ .hooks = .{} };
    var out_buf: [512]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const got = try slashHelper(alloc, "/export", &sid, &model, &model_owned, &provider, &provider_owned, &pol, &tools_rt, &bg_mgr, sess_abs, false, &out_fbs, &ctl_audit);
    try std.testing.expectEqual(CmdRes.handled, got);
    try std.testing.expect(std.mem.indexOf(u8, out_fbs.buffered(), "exported to") != null);
}

// --- UX7: Auth/providers walkthrough tests ---

test "UX7: /login with no arg returns select_login overlay" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try tmp.dir.openDir(std.testing.io, ".", .{});
    defer root.close(std.testing.io);
    var guard = try path_guard.CwdGuard.enter(root);
    defer guard.deinit();
    var pol = try RuntimePolicy.load(alloc, defaultIo(), null);
    defer pol.deinit();

    var sid = try alloc.dupe(u8, "s");
    defer alloc.free(sid);
    var model: []const u8 = "m";
    var provider: []const u8 = "p";
    var model_owned: ?[]u8 = null;
    defer if (model_owned) |b| alloc.free(b);
    var provider_owned: ?[]u8 = null;
    defer if (provider_owned) |b| alloc.free(b);
    var tools_rt = core.tools.builtin.Runtime.init(.{ .alloc = alloc });
    defer tools_rt.deinit();
    var bg_mgr = try bg.Manager.init(alloc);
    defer bg_mgr.deinit();
    var ctl_audit = RuntimeCtlAudit{ .hooks = .{} };
    var out_buf: [512]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const got = try slashHelper(alloc, "/login", &sid, &model, &model_owned, &provider, &provider_owned, &pol, &tools_rt, &bg_mgr, null, true, &out_fbs, &ctl_audit);
    try std.testing.expectEqual(CmdRes.select_login, got);
}

test "UX7: /login unknown provider shows error" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try tmp.dir.openDir(std.testing.io, ".", .{});
    defer root.close(std.testing.io);
    var guard = try path_guard.CwdGuard.enter(root);
    defer guard.deinit();
    var pol = try RuntimePolicy.load(alloc, defaultIo(), null);
    defer pol.deinit();

    var sid = try alloc.dupe(u8, "s");
    defer alloc.free(sid);
    var model: []const u8 = "m";
    var provider: []const u8 = "p";
    var model_owned: ?[]u8 = null;
    defer if (model_owned) |b| alloc.free(b);
    var provider_owned: ?[]u8 = null;
    defer if (provider_owned) |b| alloc.free(b);
    var tools_rt = core.tools.builtin.Runtime.init(.{ .alloc = alloc });
    defer tools_rt.deinit();
    var bg_mgr = try bg.Manager.init(alloc);
    defer bg_mgr.deinit();
    var ctl_audit = RuntimeCtlAudit{ .hooks = .{} };
    var out_buf: [512]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const got = try slashHelper(alloc, "/login bogus-provider", &sid, &model, &model_owned, &provider, &provider_owned, &pol, &tools_rt, &bg_mgr, null, true, &out_fbs, &ctl_audit);
    try std.testing.expectEqual(CmdRes.handled, got);
    try std.testing.expect(std.mem.indexOf(u8, out_fbs.buffered(), "unknown provider: bogus-provider") != null);
}

test "UX7: /logout with unknown provider shows error" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try tmp.dir.openDir(std.testing.io, ".", .{});
    defer root.close(std.testing.io);
    var guard = try path_guard.CwdGuard.enter(root);
    defer guard.deinit();
    var pol = try RuntimePolicy.load(alloc, defaultIo(), null);
    defer pol.deinit();

    var sid = try alloc.dupe(u8, "s");
    defer alloc.free(sid);
    var model: []const u8 = "m";
    var provider: []const u8 = "p";
    var model_owned: ?[]u8 = null;
    defer if (model_owned) |b| alloc.free(b);
    var provider_owned: ?[]u8 = null;
    defer if (provider_owned) |b| alloc.free(b);
    var tools_rt = core.tools.builtin.Runtime.init(.{ .alloc = alloc });
    defer tools_rt.deinit();
    var bg_mgr = try bg.Manager.init(alloc);
    defer bg_mgr.deinit();
    var ctl_audit = RuntimeCtlAudit{ .hooks = .{} };
    var out_buf: [512]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const got = try slashHelper(alloc, "/logout bogus", &sid, &model, &model_owned, &provider, &provider_owned, &pol, &tools_rt, &bg_mgr, null, true, &out_fbs, &ctl_audit);
    try std.testing.expectEqual(CmdRes.handled, got);
    try std.testing.expect(std.mem.indexOf(u8, out_fbs.buffered(), "unknown provider: bogus") != null);
}

test "UX7: /model with arg changes active model" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try tmp.dir.openDir(std.testing.io, ".", .{});
    defer root.close(std.testing.io);
    var guard = try path_guard.CwdGuard.enter(root);
    defer guard.deinit();
    var pol = try RuntimePolicy.load(alloc, defaultIo(), null);
    defer pol.deinit();

    var sid = try alloc.dupe(u8, "s");
    defer alloc.free(sid);
    var model: []const u8 = "sonnet-4";
    var provider: []const u8 = "anthropic";
    var model_owned: ?[]u8 = null;
    defer if (model_owned) |b| alloc.free(b);
    var provider_owned: ?[]u8 = null;
    defer if (provider_owned) |b| alloc.free(b);
    var tools_rt = core.tools.builtin.Runtime.init(.{ .alloc = alloc });
    defer tools_rt.deinit();
    var bg_mgr = try bg.Manager.init(alloc);
    defer bg_mgr.deinit();
    var ctl_audit = RuntimeCtlAudit{ .hooks = .{} };
    var out_buf: [512]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const got = try slashHelper(alloc, "/model opus-4", &sid, &model, &model_owned, &provider, &provider_owned, &pol, &tools_rt, &bg_mgr, null, true, &out_fbs, &ctl_audit);
    try std.testing.expectEqual(CmdRes.handled, got);
    try std.testing.expectEqualStrings("opus-4", model);
    try std.testing.expect(std.mem.indexOf(u8, out_fbs.buffered(), "model set to opus-4") != null);
}

test "UX7: /model with no arg returns select_model" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try tmp.dir.openDir(std.testing.io, ".", .{});
    defer root.close(std.testing.io);
    var guard = try path_guard.CwdGuard.enter(root);
    defer guard.deinit();
    var pol = try RuntimePolicy.load(alloc, defaultIo(), null);
    defer pol.deinit();

    var sid = try alloc.dupe(u8, "s");
    defer alloc.free(sid);
    var model: []const u8 = "m";
    var provider: []const u8 = "p";
    var model_owned: ?[]u8 = null;
    defer if (model_owned) |b| alloc.free(b);
    var provider_owned: ?[]u8 = null;
    defer if (provider_owned) |b| alloc.free(b);
    var tools_rt = core.tools.builtin.Runtime.init(.{ .alloc = alloc });
    defer tools_rt.deinit();
    var bg_mgr = try bg.Manager.init(alloc);
    defer bg_mgr.deinit();
    var ctl_audit = RuntimeCtlAudit{ .hooks = .{} };
    var out_buf: [512]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const got = try slashHelper(alloc, "/model", &sid, &model, &model_owned, &provider, &provider_owned, &pol, &tools_rt, &bg_mgr, null, true, &out_fbs, &ctl_audit);
    try std.testing.expectEqual(CmdRes.select_model, got);
}

test "UX6: /share calls share_gist and prints url" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sess");
    const events = [_]core.session.Event{
        .{ .at_ms = 1, .data = .{ .prompt = .{ .text = "hello" } } },
        .{ .at_ms = 2, .data = .{ .text = .{ .text = "world" } } },
        .{ .at_ms = 3, .data = .{ .stop = .{ .reason = .done } } },
    };
    try writeSessionEventsFile(tmp, "sess/100.jsonl", &events);

    var root = try tmp.dir.openDir(std.testing.io, ".", .{});
    defer root.close(std.testing.io);
    var guard = try path_guard.CwdGuard.enter(root);
    defer guard.deinit();
    var pol = try RuntimePolicy.load(alloc, defaultIo(), null);
    defer pol.deinit();

    const sess_abs = try testRealPathAlloc(alloc, tmp.dir, "sess");
    defer alloc.free(sess_abs);

    var sid = try alloc.dupe(u8, "100");
    defer alloc.free(sid);
    var model: []const u8 = "m";
    var provider: []const u8 = "p";
    var model_owned: ?[]u8 = null;
    defer if (model_owned) |b| alloc.free(b);
    var provider_owned: ?[]u8 = null;
    defer if (provider_owned) |b| alloc.free(b);
    var tools_rt = core.tools.builtin.Runtime.init(.{ .alloc = alloc });
    defer tools_rt.deinit();
    var bg_mgr = try bg.Manager.init(alloc);
    defer bg_mgr.deinit();
    var ctl_audit = RuntimeCtlAudit{ .hooks = .{
        .share_gist = struct {
            fn ok(a: std.mem.Allocator, _: std.Io, _: []const u8, _: *const RuntimePolicy) ![]u8 {
                return try a.dupe(u8, "https://gist.example.com/123");
            }
        }.ok,
    } };
    var out_buf: [1024]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const got = try handleSlashCommand(alloc, "/share", &sid, &model, &model_owned, &provider, &provider_owned, &pol, &tools_rt, &bg_mgr, sess_abs, false, null, &out_fbs, ctl_audit.hooks, &ctl_audit, null);
    try std.testing.expectEqual(CmdRes.handled, got);
    try std.testing.expect(std.mem.indexOf(u8, out_fbs.buffered(), "https://gist.example.com/123") != null);
}

test "UX6: /resume failure leaves prior sid intact" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sess");
    // Only session 100 exists; resuming 999 must fail
    const events = [_]core.session.Event{
        .{ .at_ms = 1, .data = .{ .prompt = .{ .text = "x" } } },
        .{ .at_ms = 2, .data = .{ .stop = .{ .reason = .done } } },
    };
    try writeSessionEventsFile(tmp, "sess/100.jsonl", &events);
    const sess_abs = try testRealPathAlloc(alloc, tmp.dir, "sess");
    defer alloc.free(sess_abs);

    var root = try tmp.dir.openDir(std.testing.io, ".", .{});
    defer root.close(std.testing.io);
    var guard = try path_guard.CwdGuard.enter(root);
    defer guard.deinit();
    var pol = try RuntimePolicy.load(alloc, defaultIo(), null);
    defer pol.deinit();

    var sid = try alloc.dupe(u8, "100");
    defer alloc.free(sid);
    var model: []const u8 = "m";
    var provider: []const u8 = "p";
    var model_owned: ?[]u8 = null;
    defer if (model_owned) |b| alloc.free(b);
    var provider_owned: ?[]u8 = null;
    defer if (provider_owned) |b| alloc.free(b);
    var tools_rt = core.tools.builtin.Runtime.init(.{ .alloc = alloc });
    defer tools_rt.deinit();
    var bg_mgr = try bg.Manager.init(alloc);
    defer bg_mgr.deinit();
    var ctl_audit = RuntimeCtlAudit{ .hooks = .{} };
    var out_buf: [512]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const got = try slashHelper(alloc, "/resume 999", &sid, &model, &model_owned, &provider, &provider_owned, &pol, &tools_rt, &bg_mgr, sess_abs, false, &out_fbs, &ctl_audit);
    try std.testing.expectEqual(CmdRes.handled, got);
    // sid must remain unchanged after failed resume
    try std.testing.expectEqualStrings("100", sid);
}

test "UX7: /provider with arg switches active provider" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try tmp.dir.openDir(std.testing.io, ".", .{});
    defer root.close(std.testing.io);
    var guard = try path_guard.CwdGuard.enter(root);
    defer guard.deinit();
    var pol = try RuntimePolicy.load(alloc, defaultIo(), null);
    defer pol.deinit();

    var sid = try alloc.dupe(u8, "s");
    defer alloc.free(sid);
    var model: []const u8 = "m";
    var provider: []const u8 = "anthropic";
    var model_owned: ?[]u8 = null;
    defer if (model_owned) |b| alloc.free(b);
    var provider_owned: ?[]u8 = null;
    defer if (provider_owned) |b| alloc.free(b);
    var tools_rt = core.tools.builtin.Runtime.init(.{ .alloc = alloc });
    defer tools_rt.deinit();
    var bg_mgr = try bg.Manager.init(alloc);
    defer bg_mgr.deinit();
    var ctl_audit = RuntimeCtlAudit{ .hooks = .{} };
    var out_buf: [512]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const got = try slashHelper(alloc, "/provider openai", &sid, &model, &model_owned, &provider, &provider_owned, &pol, &tools_rt, &bg_mgr, null, true, &out_fbs, &ctl_audit);
    try std.testing.expectEqual(CmdRes.handled, got);
    try std.testing.expectEqualStrings("openai", provider);
    try std.testing.expect(std.mem.indexOf(u8, out_fbs.buffered(), "provider set to openai") != null);
}

test "UX7: missing provider hint points to approved provider command adapters" {
    const msg = missingProviderMsgForInitErr(.anthropic, error.AuthNotFound);
    try std.testing.expect(std.mem.indexOf(u8, msg, "PZ_PROVIDER_CMD") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "approved CLI adapter") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "/login anthropic") == null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "ANTHROPIC_API_KEY") == null);

    const omsg = missingProviderMsgForInitErr(.openai, error.AuthNotFound);
    try std.testing.expect(std.mem.indexOf(u8, omsg, "PZ_PROVIDER_CMD") != null);
    try std.testing.expect(std.mem.indexOf(u8, omsg, "OPENAI_API_KEY") == null);

    try std.testing.expect(std.mem.indexOf(u8, missing_provider_msg, "direct provider runtimes are disabled by policy") != null);
}

test "UX10: version check notice appears when update available" {
    const alloc = std.testing.allocator;
    var ui = try tui_harness.Ui.init(alloc, 80, 12, "m", "p");
    defer ui.deinit();

    // Simulate a completed version check with a newer version.
    var checker = version_check.Checker.init();
    checker.result = try version_check.Checker.thread_alloc.dupe(u8, "v99.0.0");
    checker.done.store(true, .release);
    defer checker.deinit();

    var out_buf: [16384]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);
    var done = false;

    try maybeShowVersionUpdate(alloc, &ui, &checker, &done, &out_fbs);

    try std.testing.expect(done);

    // Verify transcript blocks contain the update notice.
    var found_update = false;
    var found_upgrade = false;
    for (ui.tr.blocks.items) |blk| {
        if (std.mem.indexOf(u8, blk.buf.items, "Update available: v99.0.0") != null) found_update = true;
        if (std.mem.indexOf(u8, blk.buf.items, "/upgrade") != null) found_upgrade = true;
    }
    try std.testing.expect(found_update);
    try std.testing.expect(found_upgrade);
}

test "UX10: version check notice skips when already done" {
    const alloc = std.testing.allocator;
    var ui = try tui_harness.Ui.init(alloc, 80, 12, "m", "p");
    defer ui.deinit();

    var checker = version_check.Checker.init();
    checker.result = try version_check.Checker.thread_alloc.dupe(u8, "v99.0.0");
    checker.done.store(true, .release);
    defer checker.deinit();

    var out_buf: [16384]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);
    var done = true; // Already done

    try maybeShowVersionUpdate(alloc, &ui, &checker, &done, &out_fbs);

    // No blocks should be added when already done.
    try std.testing.expectEqual(@as(usize, 0), ui.tr.blocks.items.len);
}

test "UX11: manual /compact shows compacting notice" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sess");
    const sess_abs = try testRealPathAlloc(alloc, tmp.dir, "sess");
    defer alloc.free(sess_abs);

    var ui = try tui_harness.Ui.init(alloc, 80, 12, "m", "p");
    defer ui.deinit();
    ui.panels.ctx_limit = 100;
    ui.panels.cum_tok = 95;
    ui.panels.has_usage = true;

    var out_buf: [16384]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const Ctx = struct {
        saw_notice: bool = false,
        ui_ref: *tui_harness.Ui,

        fn run(raw: ?*anyopaque, _: std.mem.Allocator, _: std.Io.Dir, _: []const u8, _: i64) !CompactRun {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            for (self.ui_ref.tr.blocks.items) |blk| {
                if (std.mem.eql(u8, blk.buf.items, "[compacting...]")) {
                    self.saw_notice = true;
                    return .compacted;
                }
            }
            return error.TestUnexpectedResult;
        }
    };

    var ctx = Ctx{ .ui_ref = &ui };
    const outcome = try autoCompactWith(
        alloc,
        &ui,
        &out_fbs,
        "sess-1",
        sess_abs,
        false,
        true, // force
        &ctx,
        Ctx.run,
    );

    try std.testing.expectEqual(AutoCompactOutcome.compacted, outcome);
    try std.testing.expect(ctx.saw_notice);

    // Verify output stream also contains the notice.
    try std.testing.expect(std.mem.indexOf(u8, out_fbs.buffered(), "[compacting...]") != null);
}

test "UX11: compaction preserves history after compact" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sess");
    const sess_abs = try testRealPathAlloc(alloc, tmp.dir, "sess");
    defer alloc.free(sess_abs);

    var ui = try tui_harness.Ui.init(alloc, 80, 12, "m", "p");
    defer ui.deinit();
    ui.panels.ctx_limit = 100;
    ui.panels.cum_tok = 95;
    ui.panels.has_usage = true;

    // Add some transcript history before compaction.
    try ui.tr.infoText("turn 1");
    try ui.tr.infoText("turn 2");
    const pre_ct = ui.tr.blocks.items.len;

    var out_buf: [16384]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const Ctx = struct {
        fn run(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io.Dir, _: []const u8, _: i64) !CompactRun {
            return .compacted;
        }
    };

    const outcome = try autoCompactWith(
        alloc,
        &ui,
        &out_fbs,
        "sess-1",
        sess_abs,
        false,
        true,
        null,
        Ctx.run,
    );
    try std.testing.expectEqual(AutoCompactOutcome.compacted, outcome);

    // History blocks (turn 1, turn 2) plus [compacting...] and [session compacted].
    try std.testing.expectEqual(pre_ct + 2, ui.tr.blocks.items.len);

    // Verify original history still present.
    try std.testing.expectEqualStrings("turn 1", ui.tr.blocks.items[0].buf.items);
    try std.testing.expectEqualStrings("turn 2", ui.tr.blocks.items[1].buf.items);
}

test "UX11: compaction failure is non-fatal" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "sess");
    const sess_abs = try testRealPathAlloc(alloc, tmp.dir, "sess");
    defer alloc.free(sess_abs);

    var ui = try tui_harness.Ui.init(alloc, 80, 12, "m", "p");
    defer ui.deinit();
    ui.panels.ctx_limit = 100;
    ui.panels.cum_tok = 95;
    ui.panels.has_usage = true;

    var out_buf: [16384]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const Ctx = struct {
        fn run(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io.Dir, _: []const u8, _: i64) !CompactRun {
            return error.FileNotFound;
        }
    };

    // Compaction failure should return .failed, not propagate the error.
    const outcome = try autoCompactWith(
        alloc,
        &ui,
        &out_fbs,
        "sess-1",
        sess_abs,
        false,
        true,
        null,
        Ctx.run,
    );
    try std.testing.expectEqual(AutoCompactOutcome.failed, outcome);

    // Verify failure message in transcript.
    var found_fail = false;
    for (ui.tr.blocks.items) |blk| {
        if (std.mem.indexOf(u8, blk.buf.items, "auto-compact failed") != null) found_fail = true;
    }
    try std.testing.expect(found_fail);
}

// ── UX3: Commands walkthrough ──

test "UX3 /clear resets transcript to empty" {
    var ui = try tui_harness.Ui.init(std.testing.allocator, 40, 10, "m", "p");
    defer ui.deinit();

    try ui.onProvider(.{ .text = "response text" });
    try ui.tr.userText("user msg");
    try std.testing.expect(ui.tr.count() > 0);

    ui.clearTranscript();
    try std.testing.expectEqual(@as(usize, 0), ui.tr.count());

    // After clear, vscreen should show empty transcript
    const vscreen = @import("../modes/tui/vscreen.zig");
    const TestBuf = @import("../modes/tui/test_buf.zig").TestBuf;
    var vs = try vscreen.VScreen.init(std.testing.allocator, 40, 10);
    defer vs.deinit();
    var buf: [16384]u8 = undefined;
    var out = TestBuf.init(&buf);
    try ui.draw(&out);
    vs.clear();
    vs.feed(out.view());

    const row0 = try vs.rowText(std.testing.allocator, 0);
    defer std.testing.allocator.free(row0);
    try std.testing.expectEqual(@as(usize, 0), row0.len);
}

test "UX3 /new via transcript shows new session info" {
    var ui = try tui_harness.Ui.init(std.testing.allocator, 50, 10, "m", "p");
    defer ui.deinit();

    // Simulate what runtime does on /new: emit info text
    try ui.tr.infoText("new session abc123");

    const vscreen = @import("../modes/tui/vscreen.zig");
    const TestBuf = @import("../modes/tui/test_buf.zig").TestBuf;
    var vs = try vscreen.VScreen.init(std.testing.allocator, 50, 10);
    defer vs.deinit();
    var buf: [16384]u8 = undefined;
    var out = TestBuf.init(&buf);
    try ui.draw(&out);
    vs.clear();
    vs.feed(out.view());

    var found = false;
    var r: usize = 0;
    while (r < 5) : (r += 1) {
        const row = try vs.rowText(std.testing.allocator, r);
        defer std.testing.allocator.free(row);
        if (std.mem.indexOf(u8, row, "new session abc123") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "UX3 /help /hotkeys output via info transcript" {
    var ui = try tui_harness.Ui.init(std.testing.allocator, 60, 20, "m", "p");
    defer ui.deinit();

    // Simulate /help output (runtime writes to transcript as info)
    try ui.tr.infoText("/help  /session  /model  /tools  /clear  /new  /hotkeys  /quit");

    const vscreen = @import("../modes/tui/vscreen.zig");
    const TestBuf = @import("../modes/tui/test_buf.zig").TestBuf;
    var vs = try vscreen.VScreen.init(std.testing.allocator, 60, 20);
    defer vs.deinit();
    var buf: [16384]u8 = undefined;
    var out = TestBuf.init(&buf);
    try ui.draw(&out);
    vs.clear();
    vs.feed(out.view());

    var found_help = false;
    var found_hotkeys = false;
    var r: usize = 0;
    while (r < 15) : (r += 1) {
        const row = try vs.rowText(std.testing.allocator, r);
        defer std.testing.allocator.free(row);
        if (std.mem.indexOf(u8, row, "/help") != null) found_help = true;
        if (std.mem.indexOf(u8, row, "/hotkeys") != null) found_hotkeys = true;
    }
    try std.testing.expect(found_help);
    try std.testing.expect(found_hotkeys);
}

test "UX3 /settings triggers overlay" {
    var ui = try tui_harness.Ui.init(std.testing.allocator, 40, 12, "m", "p");
    defer ui.deinit();

    // Simulate what runtime does on /settings: set overlay
    const labels = [_][]const u8{ "Show tools", "Show thinking" };
    const toggles = try std.testing.allocator.alloc(bool, 2);
    toggles[0] = true;
    toggles[1] = false;
    ui.ov = .{
        .items = &labels,
        .title = "Settings",
        .kind = .settings,
        .toggles = toggles,
    };

    try std.testing.expect(ui.ov != null);
    try std.testing.expectEqualStrings("Settings", ui.ov.?.title);

    // Render with overlay — no crash
    const vscreen = @import("../modes/tui/vscreen.zig");
    const TestBuf = @import("../modes/tui/test_buf.zig").TestBuf;
    var vs = try vscreen.VScreen.init(std.testing.allocator, 40, 12);
    defer vs.deinit();
    var buf: [16384]u8 = undefined;
    var out = TestBuf.init(&buf);
    try ui.draw(&out);
    vs.clear();
    vs.feed(out.view());

    // Overlay should render "Settings" title somewhere
    var found = false;
    var r: usize = 0;
    while (r < 12) : (r += 1) {
        const row = try vs.rowText(std.testing.allocator, r);
        defer std.testing.allocator.free(row);
        if (std.mem.indexOf(u8, row, "Settings") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "UX3 /session returns session info" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try tmp.dir.openDir(std.testing.io, ".", .{});
    defer root.close(std.testing.io);
    var guard = try path_guard.CwdGuard.enter(root);
    defer guard.deinit();
    var pol = try RuntimePolicy.load(alloc, defaultIo(), null);
    defer pol.deinit();

    var sid = try alloc.dupe(u8, "test-sid");
    defer alloc.free(sid);
    var model: []const u8 = "m";
    var provider: []const u8 = "p";
    var model_owned: ?[]u8 = null;
    defer if (model_owned) |b| alloc.free(b);
    var provider_owned: ?[]u8 = null;
    defer if (provider_owned) |b| alloc.free(b);
    var tools_rt = core.tools.builtin.Runtime.init(.{ .alloc = alloc });
    defer tools_rt.deinit();
    var bg_mgr = try bg.Manager.init(alloc);
    defer bg_mgr.deinit();
    var ctl_audit = RuntimeCtlAudit{ .hooks = .{} };
    var out_buf: [2048]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const got = try slashHelper(alloc, "/session", &sid, &model, &model_owned, &provider, &provider_owned, &pol, &tools_rt, &bg_mgr, null, true, &out_fbs, &ctl_audit);
    try std.testing.expectEqual(CmdRes.handled, got);
    const written = out_fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "Session Info") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "test-sid") != null);
}

test "UX3 /changelog returns changelog text" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try tmp.dir.openDir(std.testing.io, ".", .{});
    defer root.close(std.testing.io);
    var guard = try path_guard.CwdGuard.enter(root);
    defer guard.deinit();
    var pol = try RuntimePolicy.load(alloc, defaultIo(), null);
    defer pol.deinit();

    var sid = try alloc.dupe(u8, "s");
    defer alloc.free(sid);
    var model: []const u8 = "m";
    var provider: []const u8 = "p";
    var model_owned: ?[]u8 = null;
    defer if (model_owned) |b| alloc.free(b);
    var provider_owned: ?[]u8 = null;
    defer if (provider_owned) |b| alloc.free(b);
    var tools_rt = core.tools.builtin.Runtime.init(.{ .alloc = alloc });
    defer tools_rt.deinit();
    var bg_mgr = try bg.Manager.init(alloc);
    defer bg_mgr.deinit();
    var ctl_audit = RuntimeCtlAudit{ .hooks = .{} };
    var out_buf: [4096]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const got = try slashHelper(alloc, "/changelog", &sid, &model, &model_owned, &provider, &provider_owned, &pol, &tools_rt, &bg_mgr, null, true, &out_fbs, &ctl_audit);
    try std.testing.expectEqual(CmdRes.handled, got);
    try std.testing.expect(std.mem.indexOf(u8, out_fbs.buffered(), "What's New") != null);
}

test "UX3 /copy returns copy action" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try tmp.dir.openDir(std.testing.io, ".", .{});
    defer root.close(std.testing.io);
    var guard = try path_guard.CwdGuard.enter(root);
    defer guard.deinit();
    var pol = try RuntimePolicy.load(alloc, defaultIo(), null);
    defer pol.deinit();

    var sid = try alloc.dupe(u8, "s");
    defer alloc.free(sid);
    var model: []const u8 = "m";
    var provider: []const u8 = "p";
    var model_owned: ?[]u8 = null;
    defer if (model_owned) |b| alloc.free(b);
    var provider_owned: ?[]u8 = null;
    defer if (provider_owned) |b| alloc.free(b);
    var tools_rt = core.tools.builtin.Runtime.init(.{ .alloc = alloc });
    defer tools_rt.deinit();
    var bg_mgr = try bg.Manager.init(alloc);
    defer bg_mgr.deinit();
    var ctl_audit = RuntimeCtlAudit{ .hooks = .{} };
    var out_buf: [512]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const got = try slashHelper(alloc, "/copy", &sid, &model, &model_owned, &provider, &provider_owned, &pol, &tools_rt, &bg_mgr, null, true, &out_fbs, &ctl_audit);
    try std.testing.expectEqual(CmdRes.copy, got);
}

test "UX3 /quit returns quit action" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try tmp.dir.openDir(std.testing.io, ".", .{});
    defer root.close(std.testing.io);
    var guard = try path_guard.CwdGuard.enter(root);
    defer guard.deinit();
    var pol = try RuntimePolicy.load(alloc, defaultIo(), null);
    defer pol.deinit();

    var sid = try alloc.dupe(u8, "s");
    defer alloc.free(sid);
    var model: []const u8 = "m";
    var provider: []const u8 = "p";
    var model_owned: ?[]u8 = null;
    defer if (model_owned) |b| alloc.free(b);
    var provider_owned: ?[]u8 = null;
    defer if (provider_owned) |b| alloc.free(b);
    var tools_rt = core.tools.builtin.Runtime.init(.{ .alloc = alloc });
    defer tools_rt.deinit();
    var bg_mgr = try bg.Manager.init(alloc);
    defer bg_mgr.deinit();
    var ctl_audit = RuntimeCtlAudit{ .hooks = .{} };
    var out_buf: [512]u8 = undefined;
    var out_fbs: std.Io.Writer = .fixed(&out_buf);

    const got = try slashHelper(alloc, "/quit", &sid, &model, &model_owned, &provider, &provider_owned, &pol, &tools_rt, &bg_mgr, null, true, &out_fbs, &ctl_audit);
    try std.testing.expectEqual(CmdRes.quit, got);
}
