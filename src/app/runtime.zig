const std = @import("std");
const cli = @import("cli.zig");
const bg = @import("bg.zig");
const changelog = @import("changelog.zig");
const version_check = @import("version.zig");
const config = @import("config.zig");
const core = @import("../core/mod.zig");
const print_fmt = @import("../modes/print/format.zig");
const print_err = @import("../modes/print/errors.zig");
const tui_harness = @import("../modes/tui/harness.zig");
const tui_render = @import("../modes/tui/render.zig");
const tui_term = @import("../modes/tui/term.zig");
const tui_input = @import("../modes/tui/input.zig");
const tui_editor = @import("../modes/tui/editor.zig");
const tui_frame = @import("../modes/tui/frame.zig");
const tui_theme = @import("../modes/tui/theme.zig");
const tui_overlay = @import("../modes/tui/overlay.zig");
const tui_pathcomp = @import("../modes/tui/pathcomp.zig");
const args_mod = @import("args.zig");

pub const Err = error{
    SessionNotFound,
    AmbiguousSession,
    InvalidSessionPath,
    TerminalSetupFailed,
};

const map_ctx_t = struct {
    fn map(_: *@This(), err: anyerror) core.providers.types.Err {
        if (err == error.Timeout or err == error.WireBreak) return error.TransportTransient;
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return error.TransportFatal;
    }
};

const ProviderRuntime = struct {
    tr: core.providers.proc_transport.Transport,
    map_ctx: map_ctx_t = .{},
    map: core.providers.types.Adapter = undefined,
    pol: core.providers.first_provider.Pol = undefined,
    client: core.providers.first_provider.Client = undefined,

    fn init(self: *ProviderRuntime, alloc: std.mem.Allocator, provider_cmd: []const u8) !void {
        self.tr = try core.providers.proc_transport.Transport.init(.{
            .alloc = alloc,
            .cmd = provider_cmd,
        });
        self.map_ctx = .{};
        self.map = core.providers.types.Adapter.from(map_ctx_t, &self.map_ctx, map_ctx_t.map);
        self.pol = try core.providers.first_provider.Pol.init(.{
            .max_tries = 4,
            .backoff = .{
                .base_ms = 2000,
                .max_ms = 60000,
                .mul = 2,
            },
            .retryable = core.providers.types.retryable,
        });
        self.client = core.providers.first_provider.Client.init(
            alloc,
            self.tr.asRawTransport(),
            self.map,
            self.pol,
            null,
        );
    }

    fn deinit(self: *ProviderRuntime) void {
        self.tr.deinit();
        self.* = undefined;
    }
};

const NativeProviderRuntime = struct {
    client: core.providers.anthropic.Client,

    fn init(alloc: std.mem.Allocator) !NativeProviderRuntime {
        return .{
            .client = try core.providers.anthropic.Client.init(alloc),
        };
    }

    fn deinit(self: *NativeProviderRuntime) void {
        self.client.deinit();
    }
};

const missing_provider_msg = "provider_cmd missing; set --provider-cmd or PZ_PROVIDER_CMD";

const MissingProvider = struct {
    alloc: std.mem.Allocator,

    fn asProvider(self: *MissingProvider) core.providers.Provider {
        return core.providers.Provider.from(MissingProvider, self, MissingProvider.start);
    }

    fn start(self: *MissingProvider, _: core.providers.Req) !core.providers.Stream {
        const stream = try self.alloc.create(MissingProviderStream);
        stream.* = .{
            .alloc = self.alloc,
        };
        return core.providers.Stream.from(
            MissingProviderStream,
            stream,
            MissingProviderStream.next,
            MissingProviderStream.deinit,
        );
    }
};

const MissingProviderStream = struct {
    alloc: std.mem.Allocator,
    idx: u8 = 0,

    fn next(self: *MissingProviderStream) !?core.providers.Ev {
        defer self.idx +|= 1;

        return switch (self.idx) {
            0 => .{ .err = missing_provider_msg },
            1 => .{ .stop = .{ .reason = .err } },
            else => null,
        };
    }

    fn deinit(self: *MissingProviderStream) void {
        self.alloc.destroy(self);
    }
};

const PrintSink = struct {
    fmt: print_fmt.Formatter,
    stop_reason: ?core.providers.StopReason = null,

    fn init(alloc: std.mem.Allocator, out: std.Io.AnyWriter) PrintSink {
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
                        self.stop_reason = print_err.mergeStop(self.stop_reason, stop.reason);
                    },
                    else => {},
                }
                try self.fmt.push(pev);
            },
            else => {},
        }
    }
};

const TuiSink = struct {
    ui: *tui_harness.Ui,
    out: std.Io.AnyWriter,

    fn push(self: *TuiSink, ev: core.loop.ModeEv) !void {
        switch (ev) {
            .provider => |pev| try self.ui.onProvider(pev),
            else => {},
        }
        try self.ui.draw(self.out);
    }
};

/// Reads stdin on a dedicated thread during streaming. Sets an atomic
/// flag when ESC is pressed, allowing the core loop's CancelSrc to
/// detect cancellation without platform-specific non-blocking hacks.
/// Mirrors pi's CancellableLoader + AbortController pattern.
const InputWatcher = struct {
    canceled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
    fd: std.posix.fd_t,
    /// Buffer for non-ESC bytes consumed during streaming, replayed after join().
    stash: [64]u8 = undefined,
    stash_len: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

    fn init(fd: std.posix.fd_t) InputWatcher {
        return .{ .fd = fd };
    }

    /// Start watching stdin for ESC on a background thread.
    /// Returns false if thread spawn failed (cancel unavailable).
    fn start(self: *InputWatcher) bool {
        self.canceled.store(false, .release);
        self.stop.store(false, .release);
        self.stash_len.store(0, .release);
        self.thread = std.Thread.spawn(.{}, watchFn, .{self}) catch return false;
        return true;
    }

    /// Stop the watcher, join the thread, replay stashed bytes into reader.
    fn join(self: *InputWatcher, reader: ?*tui_input.Reader) void {
        self.stop.store(true, .release);
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

    fn watchFn(self: *InputWatcher) void {
        while (!self.stop.load(.acquire)) {
            // poll with 100ms timeout so join() can stop us promptly.
            var fds = [1]std.posix.pollfd{.{
                .fd = self.fd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            const n = std.posix.poll(&fds, 100) catch break;
            if (n == 0) continue; // timeout — recheck stop flag
            var buf: [1]u8 = undefined;
            const r = std.posix.read(self.fd, &buf) catch break;
            if (r == 1 and buf[0] == 0x1b) {
                self.canceled.store(true, .release);
                return;
            }
            // Stash non-ESC byte for replay
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

const JsonSink = struct {
    alloc: std.mem.Allocator,
    out: std.Io.AnyWriter,

    fn push(self: *JsonSink, ev: core.loop.ModeEv) !void {
        switch (ev) {
            .replay => |payload| try self.emit("replay", payload),
            .session => |payload| try self.emit("session", payload),
            .provider => |payload| try self.emit("provider", payload),
            .tool => |payload| try self.emit("tool", payload),
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

pub fn exec(alloc: std.mem.Allocator, run_cmd: cli.Run) (Err || anyerror)![]u8 {
    return execWithIo(alloc, run_cmd, null, null);
}

pub fn execWithWriter(
    alloc: std.mem.Allocator,
    run_cmd: cli.Run,
    out: ?std.Io.AnyWriter,
) (Err || anyerror)![]u8 {
    return execWithIo(alloc, run_cmd, null, out);
}

pub fn execWithIo(
    alloc: std.mem.Allocator,
    run_cmd: cli.Run,
    in: ?std.Io.AnyReader,
    out: ?std.Io.AnyWriter,
) (Err || anyerror)![]u8 {
    var provider_rt: ProviderRuntime = undefined;
    var native_rt: NativeProviderRuntime = undefined;
    var missing_provider = MissingProvider{
        .alloc = alloc,
    };
    var provider: core.providers.Provider = undefined;
    var has_provider_rt = false;
    var has_native_rt = false;
    defer if (has_provider_rt) provider_rt.deinit();
    defer if (has_native_rt) native_rt.deinit();

    if (run_cmd.cfg.provider_cmd) |provider_cmd| {
        try provider_rt.init(alloc, provider_cmd);
        has_provider_rt = true;
        provider = provider_rt.client.asProvider();
    } else if (NativeProviderRuntime.init(alloc)) |nr| {
        native_rt = nr;
        has_native_rt = true;
        provider = native_rt.client.asProvider();
    } else |_| {
        provider = missing_provider.asProvider();
    }

    var tools_rt = core.tools.builtin.Runtime.init(.{
        .alloc = alloc,
        .tool_mask = run_cmd.tool_mask,
    });

    var sid: []u8 = &.{};
    var session_dir_path: ?[]u8 = null;
    defer if (session_dir_path) |path| alloc.free(path);
    errdefer if (sid.len > 0) alloc.free(sid);

    var store: ?core.session.SessionStore = null;
    var fs_store_impl: core.session.fs_store.Store = undefined;
    var null_store_impl = core.session.NullStore.init();

    if (run_cmd.no_session) {
        sid = try newSid(alloc);
        store = null_store_impl.asSessionStore();
    } else {
        const plan = try resolveSessionPlan(alloc, run_cmd);
        sid = plan.sid;
        session_dir_path = plan.dir_path;

        try std.fs.cwd().makePath(plan.dir_path);
        var session_dir = try std.fs.cwd().openDir(plan.dir_path, .{ .iterate = true });
        errdefer session_dir.close();
        fs_store_impl = try core.session.fs_store.Store.init(.{
            .alloc = alloc,
            .dir = session_dir,
            .flush = .{ .always = {} },
            .replay = .{},
        });
        store = fs_store_impl.asSessionStore();
    }
    defer if (store) |*s| s.deinit();
    const st = store.?;

    // Build system prompt: --system-prompt overrides, else load AGENTS.md/CLAUDE.md
    const sys_prompt = try buildSystemPrompt(alloc, run_cmd);
    defer if (sys_prompt) |sp| alloc.free(sp);

    const writer = if (out) |w| w else std.fs.File.stdout().deprecatedWriter().any();
    const reader = if (in) |r| r else std.fs.File.stdin().deprecatedReader().any();
    switch (run_cmd.mode) {
        .print => try runPrint(
            alloc,
            run_cmd,
            sid,
            provider,
            st,
            &tools_rt,
            writer,
            sys_prompt,
        ),
        .json => try runJson(
            alloc,
            run_cmd,
            sid,
            provider,
            st,
            &tools_rt,
            reader,
            writer,
            sys_prompt,
        ),
        .tui => try runTui(
            alloc,
            run_cmd,
            &sid,
            provider,
            st,
            &tools_rt,
            reader,
            writer,
            session_dir_path,
            run_cmd.no_session,
            sys_prompt,
            has_native_rt and native_rt.client.isSub(),
        ),
        .rpc => try runRpc(
            alloc,
            run_cmd,
            &sid,
            provider,
            st,
            &tools_rt,
            reader,
            writer,
            session_dir_path,
            run_cmd.no_session,
            sys_prompt,
        ),
    }

    return sid;
}

fn runPrint(
    alloc: std.mem.Allocator,
    run_cmd: cli.Run,
    sid: []const u8,
    provider: core.providers.Provider,
    store: core.session.SessionStore,
    tools_rt: *core.tools.builtin.Runtime,
    out: std.Io.AnyWriter,
    sys_prompt: ?[]const u8,
) !void {
    const prompt = run_cmd.prompt orelse return error.EmptyPrompt;

    var sink_impl = PrintSink.init(alloc, out);
    defer sink_impl.deinit();
    sink_impl.fmt.verbose = run_cmd.verbose;

    const mode = core.loop.ModeSink.from(PrintSink, &sink_impl, PrintSink.push);

    _ = try core.loop.run(.{
        .alloc = alloc,
        .sid = sid,
        .prompt = prompt,
        .model = run_cmd.cfg.model,
        .provider_label = run_cmd.cfg.provider,
        .provider = provider,
        .store = store,
        .reg = tools_rt.registry(),
        .mode = mode,
        .system_prompt = sys_prompt,
        .provider_opts = run_cmd.thinking.toProviderOpts(),
        .max_turns = run_cmd.max_turns,
    });

    try sink_impl.fmt.finish();
    if (sink_impl.stop_reason) |reason| {
        if (print_err.mapStop(reason)) |mapped| return mapped;
    }
}

fn runJson(
    alloc: std.mem.Allocator,
    run_cmd: cli.Run,
    sid: []const u8,
    provider: core.providers.Provider,
    store: core.session.SessionStore,
    tools_rt: *core.tools.builtin.Runtime,
    in: std.Io.AnyReader,
    out: std.Io.AnyWriter,
    sys_prompt: ?[]const u8,
) !void {
    var sink_impl = JsonSink{
        .alloc = alloc,
        .out = out,
    };
    const mode = core.loop.ModeSink.from(JsonSink, &sink_impl, JsonSink.push);
    const popts = run_cmd.thinking.toProviderOpts();
    const tctx = TurnCtx{
        .alloc = alloc,
        .provider = provider,
        .store = store,
        .tools_rt = tools_rt,
        .mode = mode,
        .max_turns = run_cmd.max_turns,
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
    while (try in.readUntilDelimiterOrEofAlloc(alloc, '\n', 64 * 1024)) |raw_line| {
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
    provider: core.providers.Provider,
    store: core.session.SessionStore,
    tools_rt: *core.tools.builtin.Runtime,
    in: std.Io.AnyReader,
    out: std.Io.AnyWriter,
    session_dir_path: ?[]const u8,
    no_session: bool,
    sys_prompt_arg: ?[]const u8,
    is_sub: bool,
) !void {
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

    const cwd_path = getCwd(alloc) catch "";
    defer if (cwd_path.len > 0) alloc.free(cwd_path);
    const branch = getGitBranch(alloc) catch "";
    defer if (branch.len > 0) alloc.free(branch);

    const tsz = tui_term.size(std.posix.STDOUT_FILENO) orelse tui_term.Size{ .w = 80, .h = 24 };
    var ui = try tui_harness.Ui.initFull(alloc, tsz.w, tsz.h, model, provider_label, cwd_path, branch);
    defer ui.deinit();
    ui.img_cap = @import("../modes/tui/imgproto.zig").detect();
    ui.pn.ctx_limit = modelCtxWindow(model);
    ui.pn.is_sub = is_sub;

    _ = tui_term.installSigwinch();
    try tui_render.Renderer.setup(out);
    try tui_render.Renderer.setTitle(out, cwd_path);

    defer {
        tui_render.Renderer.setTitle(out, "") catch |err| {
            std.debug.print("warning: title reset failed: {s}\n", .{@errorName(err)});
        };
        tui_render.Renderer.cleanup(out) catch |err| {
            std.debug.print("warning: terminal cleanup failed: {s}\n", .{@errorName(err)});
        };
    }

    var sink_impl = TuiSink{
        .ui = &ui,
        .out = out,
    };
    const mode = core.loop.ModeSink.from(TuiSink, &sink_impl, TuiSink.push);

    const stdin_fd = std.posix.STDIN_FILENO;
    const is_tty = std.posix.isatty(stdin_fd);

    // Enable raw mode early so the InputWatcher's poll() works for -p prompts
    if (is_tty) {
        if (!tui_term.enableRaw(stdin_fd)) return error.TerminalSetupFailed;
    }
    defer if (is_tty) tui_term.restore(stdin_fd);

    var watcher = InputWatcher.init(stdin_fd);
    const cancel = core.loop.CancelSrc.from(InputWatcher, &watcher, InputWatcher.isCanceled);
    const tctx = TurnCtx{
        .alloc = alloc,
        .provider = provider,
        .store = store,
        .tools_rt = tools_rt,
        .mode = mode,
        .max_turns = run_cmd.max_turns,
        .cancel = cancel,
    };
    var bg_mgr = try bg.Mgr.init(alloc);
    defer bg_mgr.deinit();
    try syncBgFooter(alloc, &ui, &bg_mgr);
    var thinking = run_cmd.thinking;
    var popts = thinking.toProviderOpts();
    var auto_compact_on: bool = true;
    ui.pn.thinking_label = thinkingLabel(thinking);
    ui.border_fg = thinkingBorderFg(thinking);

    // Background version check (TUI only, skip for dev builds)
    const skip_ver = std.posix.getenv("PZ_SKIP_VERSION_CHECK") != null or
        std.mem.indexOf(u8, cli.version, "-dev") != null;
    var ver_check = version_check.Check.init(alloc);
    if (!skip_ver) ver_check.spawn();
    defer ver_check.deinit();

    // Startup info matching pi's display
    const is_resumed = switch (run_cmd.session) {
        .cont, .resm, .explicit => true,
        .auto => false,
    };
    try showStartup(alloc, &ui, is_resumed);

    // Set terminal title (OSC 0)
    try out.writeAll("\x1b]0;pz\x07");
    defer out.writeAll("\x1b]0;\x07") catch |err| {
        std.debug.print("warning: title clear failed: {s}\n", .{@errorName(err)});
    };

    try ui.draw(out);

    // Check for new version after initial draw
    if (ver_check.poll()) |new_ver| {
        const t = tui_theme.get();
        const ver_msg = try std.fmt.allocPrint(alloc, "Update available: {s}", .{new_ver});
        defer alloc.free(ver_msg);
        try ui.tr.styledText(ver_msg, .{ .fg = t.accent });
        try ui.tr.infoText("  https://github.com/joelreymont/pz/releases");
        try ui.draw(out);
    }
    if (run_cmd.prompt) |prompt| {
        var init_cmd_buf: [4096]u8 = undefined;
        var init_cmd_fbs = std.io.fixedBufferStream(&init_cmd_buf);
        const cmd = try handleSlashCommand(
            alloc,
            prompt,
            sid,
            &model,
            &model_owned,
            &provider_label,
            &provider_owned,
            tools_rt,
            &bg_mgr,
            session_dir_path,
            no_session,
            sys_prompt,
            init_cmd_fbs.writer().any(),
        );
        if (cmd == .quit) return;
        if (cmd == .clear) {
            ui.clearTranscript();
        }
        if (cmd == .copy) {
            try copyLastResponse(alloc, &ui);
        }
        if (cmd == .cost) {
            try showCost(alloc, &ui);
        }
        if (cmd == .reload) {
            // Reload context and continue to input loop
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
            if (session_dir_path) |sdp| {
                if (listSessionSids(alloc, sdp)) |sids| {
                    if (sids.len > 0) {
                        ui.ov = tui_overlay.Overlay.initDyn(alloc, sids, "Resume Session", .session);
                    }
                } else |_| {}
            }
        }
        if (cmd == .select_settings) {
            ui.ov = try buildSettingsOverlay(alloc, &ui, auto_compact_on);
        }
        if (cmd == .select_fork) {
            if (session_dir_path) |sdp| {
                if (listUserMessages(alloc, sdp, sid.*)) |msgs| {
                    if (msgs.len > 0) {
                        var ov = tui_overlay.Overlay.initDyn(alloc, msgs, "Fork from message", .session);
                        ov.sel = msgs.len - 1;
                        ov.fixScroll();
                        ov.kind = .fork;
                        ui.ov = ov;
                    }
                } else |_| {}
            }
        }
        if (cmd == .handled or cmd == .clear or cmd == .copy or cmd == .cost or cmd == .reload or cmd == .select_model or cmd == .select_session or cmd == .select_settings or cmd == .select_fork) {
            const cmd_text = init_cmd_fbs.getWritten();
            if (cmd_text.len > 0) {
                try ui.tr.infoText(cmd_text);
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
            ui.pn.run_state = .idle;
        } else {
            try ui.setModel(model);
            try ui.setProvider(provider_label);
            try ui.draw(out);
        }
        // Fall through to input loop (stay in TUI like pi does)
    }

    if (is_tty) {
        // Raw mode already enabled above (before -p prompt path)
        var reader = tui_input.Reader.initWithNotify(stdin_fd, bg_mgr.wakeFd());
        var followup_queue: std.ArrayListUnmanaged([]u8) = .empty;
        defer {
            for (followup_queue.items) |q| alloc.free(q);
            followup_queue.deinit(alloc);
        }

        while (true) {
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
                                        const new = try alloc.dupe(u8, sel);
                                        if (model_owned) |old| alloc.free(old);
                                        model_owned = new;
                                        model = new;
                                        ui.pn.ctx_limit = modelCtxWindow(model);
                                        try ui.setModel(model);
                                        ui.ov.?.deinit(alloc);
                                        ui.ov = null;
                                    },
                                    .session => {
                                        const next_sid = try alloc.dupe(u8, sel);
                                        alloc.free(sid.*);
                                        sid.* = next_sid;
                                        try ui.tr.infoText(sel);
                                        ui.ov.?.deinit(alloc);
                                        ui.ov = null;
                                    },
                                    .settings => {
                                        // Toggle the selected setting
                                        ui.ov.?.toggle();
                                        applySettingsToggle(&ui, ui.ov.?.sel, ui.ov.?.getToggle(ui.ov.?.sel) orelse false, &auto_compact_on);
                                    },
                                    .fork => {
                                        const next_sid = try newSid(alloc);
                                        errdefer alloc.free(next_sid);
                                        if (session_dir_path) |sdp| {
                                            try forkSessionFile(sdp, sid.*, next_sid);
                                        }
                                        alloc.free(sid.*);
                                        sid.* = next_sid;
                                        try ui.ed.setText(sel);
                                        try ui.tr.infoText("[forked session]");
                                        ui.ov.?.deinit(alloc);
                                        ui.ov = null;
                                    },
                                    .login => {
                                        // Set env var hint in editor for API key entry
                                        const env_var: []const u8 = if (std.mem.eql(u8, sel, "anthropic"))
                                            "ANTHROPIC_API_KEY"
                                        else if (std.mem.eql(u8, sel, "openai"))
                                            "OPENAI_API_KEY"
                                        else
                                            "GOOGLE_API_KEY";
                                        const msg = try std.fmt.allocPrint(alloc, "Paste {s} API key (or set {s} env var):", .{ sel, env_var });
                                        defer alloc.free(msg);
                                        try ui.tr.infoText(msg);
                                        // Set editor to /login <provider> so user can paste the key
                                        const prompt_text = try std.fmt.allocPrint(alloc, "/login {s} ", .{sel});
                                        defer alloc.free(prompt_text);
                                        try ui.ed.setText(prompt_text);
                                        ui.ov.?.deinit(alloc);
                                        ui.ov = null;
                                    },
                                    .logout => {
                                        // Remove credentials for selected provider
                                        const provider_map = std.StaticStringMap(core.providers.auth.Provider).initComptime(.{
                                            .{ "anthropic", .anthropic },
                                            .{ "openai", .openai },
                                            .{ "google", .google },
                                        });
                                        if (provider_map.get(sel)) |prov| {
                                            try core.providers.auth.logout(alloc, prov);
                                            const msg2 = try std.fmt.allocPrint(alloc, "logged out of {s}", .{sel});
                                            defer alloc.free(msg2);
                                            try ui.tr.infoText(msg2);
                                        }
                                        ui.ov.?.deinit(alloc);
                                        ui.ov = null;
                                    },
                                }
                            },
                            .esc, .ctrl_c, .ctrl_l => {
                                ui.ov.?.deinit(alloc);
                                ui.ov = null;
                            },
                            else => {},
                        }
                        try ui.draw(out);
                        continue;
                    }

                    // Command preview intercept
                    if (ui.cp) |*cp| {
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
                                    // Arg mode: replace arg in editor
                                    if (cp.selectedArg()) |arg| {
                                        const text = ui.ed.text();
                                        const sp = std.mem.indexOfScalar(u8, text, ' ') orelse text.len;
                                        ui.ed.buf.items.len = sp;
                                        try ui.ed.buf.appendSlice(ui.ed.alloc, " ");
                                        try ui.ed.buf.appendSlice(ui.ed.alloc, arg);
                                        ui.ed.cur = ui.ed.buf.items.len;
                                    }
                                } else {
                                    // Cmd mode: fill command name
                                    const cmd = cp.selected();
                                    ui.ed.buf.items.len = 0;
                                    try ui.ed.buf.appendSlice(ui.ed.alloc, "/");
                                    try ui.ed.buf.appendSlice(ui.ed.alloc, cmd.name);
                                    try ui.ed.buf.appendSlice(ui.ed.alloc, " ");
                                    ui.ed.cur = ui.ed.buf.items.len;
                                }
                                ui.cp = null;
                                ui.arg_src = resolveArgSrc(ui.ed.text(), models_list);
                                ui.updatePreview();
                                try ui.draw(out);
                                continue;
                            },
                            .esc => {
                                ui.cp = null;
                                ui.clearPathItems();
                                try ui.draw(out);
                                continue;
                            },
                            else => {},
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
                            var cmd_fbs = std.io.fixedBufferStream(&cmd_buf);
                            const cmd = try handleSlashCommand(
                                alloc,
                                prompt,
                                sid,
                                &model,
                                &model_owned,
                                &provider_label,
                                &provider_owned,
                                tools_rt,
                                &bg_mgr,
                                session_dir_path,
                                no_session,
                                sys_prompt,
                                cmd_fbs.writer().any(),
                            );
                            if (cmd == .quit) return;
                            if (cmd == .clear) {
                                ui.clearTranscript();
                                try ui.draw(out);
                                continue;
                            }
                            if (cmd == .copy) {
                                try copyLastResponse(alloc, &ui);
                                try ui.draw(out);
                                continue;
                            }
                            if (cmd == .cost) {
                                try showCost(alloc, &ui);
                                try ui.draw(out);
                                continue;
                            }
                            if (cmd == .reload) {
                                // Reload context files
                                if (try core.context.load(alloc)) |new_ctx| {
                                    if (sys_prompt_owned) |old| alloc.free(old);
                                    sys_prompt_owned = new_ctx;
                                    sys_prompt = new_ctx;
                                    try ui.tr.infoText("[context reloaded]");
                                } else {
                                    if (sys_prompt_owned) |old| alloc.free(old);
                                    sys_prompt_owned = null;
                                    sys_prompt = null;
                                    try ui.tr.infoText("[context reloaded (no files)]");
                                }
                                try ui.draw(out);
                                continue;
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
                                if (session_dir_path) |sdp| {
                                    if (listSessionSids(alloc, sdp)) |sids| {
                                        if (sids.len > 0) {
                                            ui.ov = tui_overlay.Overlay.initDyn(alloc, sids, "Resume Session", .session);
                                        }
                                    } else |_| {}
                                }
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
                                            var ov = tui_overlay.Overlay.initDyn(alloc, msgs, "Fork from message", .session);
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
                                const login_items = [_][]const u8{ "anthropic", "openai", "google" };
                                var ov = tui_overlay.Overlay.init(&login_items, 0);
                                ov.title = "Login (set API key)";
                                ov.kind = .login;
                                ui.ov = ov;
                                try ui.draw(out);
                                continue;
                            }
                            if (cmd == .select_logout) {
                                const providers = core.providers.auth.listLoggedIn(alloc) catch try alloc.alloc(core.providers.auth.Provider, 0);
                                if (providers.len == 0) {
                                    alloc.free(providers);
                                    try ui.tr.infoText("no providers logged in");
                                } else {
                                    const names = try alloc.alloc([]u8, providers.len);
                                    for (providers, 0..) |p, i| {
                                        names[i] = try alloc.dupe(u8, core.providers.auth.providerName(p));
                                    }
                                    alloc.free(providers);
                                    var ov = tui_overlay.Overlay.initDyn(alloc, names, "Logout", .logout);
                                    ui.ov = ov;
                                    _ = &ov;
                                }
                                try ui.draw(out);
                                continue;
                            }
                            if (cmd == .handled) {
                                const cmd_text = cmd_fbs.getWritten();
                                if (cmd_text.len > 0) {
                                    try ui.tr.infoText(cmd_text);
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
                                try runBashMode(alloc, &ui, bcmd, sid.*, store);
                                try ui.draw(out);
                                continue;
                            }

                            try ui.draw(out);
                            if (!watcher.start()) try ui.tr.infoText("[ESC cancel unavailable]");
                            const run_err = tctx.run(.{
                                .sid = sid.*,
                                .prompt = prompt,
                                .model = model,
                                .provider_label = provider_label,
                                .provider_opts = popts,
                                .system_prompt = sys_prompt,
                            });
                            watcher.join(&reader);
                            if (watcher.isCanceled()) try ui.tr.infoText("[canceled]");
                            ui.pn.run_state = .idle;
                            try run_err;
                            if (auto_compact_on) try autoCompact(alloc, &ui, sid.*, session_dir_path, no_session);
                            try ui.draw(out);

                            // Process queued follow-ups
                            while (followup_queue.items.len > 0) {
                                if (watcher.isCanceled()) break;
                                const fq = followup_queue.orderedRemove(0);
                                defer alloc.free(fq);
                                try ui.tr.userText(fq);
                                if (!watcher.start()) try ui.tr.infoText("[ESC cancel unavailable]");
                                const fq_err = tctx.run(.{
                                    .sid = sid.*,
                                    .prompt = fq,
                                    .model = model,
                                    .provider_label = provider_label,
                                    .provider_opts = popts,
                                    .system_prompt = sys_prompt,
                                });
                                watcher.join(&reader);
                                if (watcher.isCanceled()) try ui.tr.infoText("[canceled]");
                                ui.pn.run_state = .idle;
                                try fq_err;
                                if (auto_compact_on) try autoCompact(alloc, &ui, sid.*, session_dir_path, no_session);
                                try ui.draw(out);
                            }
                        },
                        .cancel => {
                            if (pre) |p| alloc.free(p);
                            return;
                        },
                        .interrupt => {
                            if (pre) |p| alloc.free(p);
                            try ui.draw(out);
                        },
                        .cycle_thinking => {
                            if (pre) |p| alloc.free(p);
                            thinking = cycleThinking(thinking);
                            popts = thinking.toProviderOpts();
                            ui.pn.thinking_label = thinkingLabel(thinking);
                            ui.border_fg = thinkingBorderFg(thinking);
                            try ui.draw(out);
                        },
                        .cycle_model => {
                            if (pre) |p| alloc.free(p);
                            model = try cycleModel(alloc, model, &model_owned, models_list);
                            ui.pn.ctx_limit = modelCtxWindow(model);
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
                            tui_term.restore(stdin_fd);
                            const ed_result = openExtEditor(alloc, ui.editorText());
                            _ = tui_term.enableRaw(stdin_fd);
                            if (ed_result) |maybe_txt| {
                                if (maybe_txt) |txt| {
                                    defer alloc.free(txt);
                                    try ui.ed.setText(txt);
                                }
                            } else |err| {
                                const msg = try std.fmt.allocPrint(alloc, "[editor failed: {s}]", .{@errorName(err)});
                                defer alloc.free(msg);
                                try ui.tr.infoText(msg);
                            }
                            try ui.draw(out);
                        },
                        .queue_followup => {
                            if (pre) |p| alloc.free(p);
                            // Queue current text as follow-up, clear editor
                            const snap2 = ui.editorText();
                            if (snap2.len > 0) {
                                const queued = try alloc.dupe(u8, snap2);
                                followup_queue.append(alloc, queued) catch |err| {
                                    alloc.free(queued);
                                    return err;
                                };
                                ui.ed.clear();
                                try ui.tr.infoText("(queued follow-up)");
                            }
                            try ui.draw(out);
                        },
                        .edit_queued => {
                            if (pre) |p| alloc.free(p);
                            // Show queued messages in editor (join with newlines)
                            if (followup_queue.items.len > 0) {
                                var total: usize = 0;
                                for (followup_queue.items) |q| total += q.len + 1;
                                const joined = try alloc.alloc(u8, total);
                                var off: usize = 0;
                                for (followup_queue.items) |q| {
                                    @memcpy(joined[off .. off + q.len], q);
                                    joined[off + q.len] = '\n';
                                    off += q.len + 1;
                                }
                                // Clear queue, set editor
                                for (followup_queue.items) |q| alloc.free(q);
                                followup_queue.items.len = 0;
                                try ui.ed.setText(joined[0..if (total > 0) total - 1 else 0]);
                                alloc.free(joined);
                            }
                            try ui.draw(out);
                        },
                        .paste_image => {
                            if (pre) |p| alloc.free(p);
                            try pasteImage(alloc, &ui);
                            try ui.draw(out);
                        },
                        .reverse_cycle_model => {
                            if (pre) |p| alloc.free(p);
                            model = try reverseCycleModel(alloc, model, &model_owned, models_list);
                            ui.pn.ctx_limit = modelCtxWindow(model);
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
                            ui.updatePreview();
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
                            ui.updatePreview();
                            try ui.draw(out);
                        },
                    }
                },
                .mouse => |mev| {
                    ui.onMouse(mev);
                    try ui.draw(out);
                },
                .notify => {
                    try flushBgDone(alloc, &ui, &bg_mgr);
                    try syncBgFooter(alloc, &ui, &bg_mgr);
                    try ui.draw(out);
                },
                .paste => |text| {
                    if (text.len > 0) {
                        ui.ed.insertSlice(text) catch {
                            try ui.tr.infoText("[paste: invalid UTF-8]");
                        };
                        ui.arg_src = resolveArgSrc(ui.ed.text(), models_list);
                        ui.updatePreview();
                        try ui.draw(out);
                    }
                },
                .resize => {
                    if (tui_term.size(std.posix.STDOUT_FILENO)) |sz| {
                        try ui.resize(sz.w, sz.h);
                        try ui.draw(out);
                    }
                },
                .none => {},
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
        while (try in.readUntilDelimiterOrEofAlloc(alloc, '\n', 64 * 1024)) |raw_line| {
            defer alloc.free(raw_line);

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
                tools_rt,
                &bg_mgr,
                session_dir_path,
                no_session,
                sys_prompt,
                out,
            );
            if (cmd == .quit) return;
            if (cmd == .clear) {
                ui.clearTranscript();
                try ui.draw(out);
                cmd_ct += 1;
                continue;
            }
            if (cmd == .copy) {
                try copyLastResponse(alloc, &ui);
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
                if (try core.context.load(alloc)) |new_ctx| {
                    if (sys_prompt_owned) |old| alloc.free(old);
                    sys_prompt_owned = new_ctx;
                    sys_prompt = new_ctx;
                } else {
                    if (sys_prompt_owned) |old| alloc.free(old);
                    sys_prompt_owned = null;
                    sys_prompt = null;
                }
                try ui.draw(out);
                cmd_ct += 1;
                continue;
            }
            if (cmd == .handled) {
                try syncBgFooter(alloc, &ui, &bg_mgr);
                try ui.setModel(model);
                try ui.setProvider(provider_label);
                try ui.draw(out);
                cmd_ct += 1;
                continue;
            }

            // Bash mode: !cmd or !!cmd
            if (parseBashCmd(trimmed)) |bcmd| {
                try runBashMode(alloc, &ui, bcmd, sid.*, store);
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
            if (auto_compact_on) try autoCompact(alloc, &ui, sid.*, session_dir_path, no_session);
            turn_ct += 1;
        }
        if (turn_ct == 0 and cmd_ct == 0 and run_cmd.prompt == null) return error.EmptyPrompt;
    }
}

fn runRpc(
    alloc: std.mem.Allocator,
    run_cmd: cli.Run,
    sid: *([]u8),
    provider: core.providers.Provider,
    store: core.session.SessionStore,
    tools_rt: *core.tools.builtin.Runtime,
    in: std.Io.AnyReader,
    out: std.Io.AnyWriter,
    session_dir_path: ?[]const u8,
    no_session: bool,
    sys_prompt: ?[]const u8,
) !void {
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
    const mode = core.loop.ModeSink.from(JsonSink, &sink_impl, JsonSink.push);
    const popts = run_cmd.thinking.toProviderOpts();
    const tctx = TurnCtx{
        .alloc = alloc,
        .provider = provider,
        .store = store,
        .tools_rt = tools_rt,
        .mode = mode,
        .max_turns = run_cmd.max_turns,
    };
    var bg_mgr = try bg.Mgr.init(alloc);
    defer bg_mgr.deinit();

    while (try in.readUntilDelimiterOrEofAlloc(alloc, '\n', 128 * 1024)) |raw_line| {
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
                .msg = "invalid_json",
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
                .msg = "missing_cmd",
            });
            continue;
        }
        const cmd = normalizeRpcCmd(raw_cmd);

        const RpcCmd = enum { prompt, model, provider, tools, bg, new, @"resume", session, tree, fork, compact, help, commands, quit, exit };
        const rpc_map = std.StaticStringMap(RpcCmd).initComptime(.{
            .{ "prompt", .prompt },
            .{ "model", .model },
            .{ "provider", .provider },
            .{ "tools", .tools },
            .{ "bg", .bg },
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
                .msg = "unknown_cmd",
            });
            continue;
        };

        switch (resolved) {
            .prompt => {
                const prompt = req.text orelse req.arg orelse "";
                if (prompt.len == 0) {
                    try writeJsonLine(alloc, out, .{
                        .type = "rpc_error",
                        .id = req.id,
                        .cmd = raw_cmd,
                        .msg = "missing_text",
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
                if (std.mem.eql(u8, raw_cmd, "set_model")) {
                    if (req.provider) |prov| {
                        if (prov.len > 0) {
                            const prov_dup = try alloc.dupe(u8, prov);
                            if (provider_owned) |curr| alloc.free(curr);
                            provider_owned = prov_dup;
                            provider_label = prov_dup;
                        }
                    }
                }

                const next = req.model_id orelse req.model orelse req.arg orelse "";
                if (next.len == 0) {
                    try writeJsonLine(alloc, out, .{
                        .type = "rpc_error",
                        .id = req.id,
                        .cmd = raw_cmd,
                        .msg = "missing_model",
                    });
                    continue;
                }
                const dup = try alloc.dupe(u8, next);
                if (model_owned) |curr| alloc.free(curr);
                model_owned = dup;
                model = dup;
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
                if (next.len == 0) {
                    try writeJsonLine(alloc, out, .{
                        .type = "rpc_error",
                        .id = req.id,
                        .cmd = raw_cmd,
                        .msg = "missing_provider",
                    });
                    continue;
                }
                const dup = try alloc.dupe(u8, next);
                if (provider_owned) |curr| alloc.free(curr);
                provider_owned = dup;
                provider_label = dup;
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
                    const mask = parseCmdToolMask(raw) catch {
                        try writeJsonLine(alloc, out, .{
                            .type = "rpc_error",
                            .id = req.id,
                            .cmd = raw_cmd,
                            .msg = "invalid_tools",
                        });
                        continue;
                    };
                    tools_rt.tool_mask = mask;
                }
                const tool_csv = try toolMaskCsvAlloc(alloc, tools_rt.tool_mask);
                defer alloc.free(tool_csv);
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
            .new => {
                const next_sid = try newSid(alloc);
                alloc.free(sid.*);
                sid.* = next_sid;
                try writeJsonLine(alloc, out, .{
                    .type = "rpc_ack",
                    .id = req.id,
                    .cmd = raw_cmd,
                    .sid = sid.*,
                });
            },
            .@"resume" => {
                const token = req.session_path orelse req.session orelse req.sid orelse req.arg;
                applyResumeSid(alloc, sid, session_dir_path, no_session, token) catch |err| {
                    try writeJsonLine(alloc, out, .{
                        .type = "rpc_error",
                        .id = req.id,
                        .cmd = raw_cmd,
                        .msg = if (err == error.SessionDisabled) "session_disabled" else @errorName(err),
                    });
                    continue;
                };
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
                    try writeJsonLine(alloc, out, .{
                        .type = "rpc_error",
                        .id = req.id,
                        .cmd = raw_cmd,
                        .msg = "session_disabled",
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
                applyForkSid(alloc, sid, session_dir_path, no_session, req.sid orelse req.arg) catch |err| {
                    try writeJsonLine(alloc, out, .{
                        .type = "rpc_error",
                        .id = req.id,
                        .cmd = raw_cmd,
                        .msg = if (err == error.SessionDisabled) "session_disabled" else @errorName(err),
                    });
                    continue;
                };
                try writeJsonLine(alloc, out, .{
                    .type = "rpc_ack",
                    .id = req.id,
                    .cmd = raw_cmd,
                    .sid = sid.*,
                });
            },
            .compact => {
                const session_dir = requireSessionDir(session_dir_path, no_session) catch {
                    try writeJsonLine(alloc, out, .{
                        .type = "rpc_error",
                        .id = req.id,
                        .cmd = raw_cmd,
                        .msg = "session_disabled",
                    });
                    continue;
                };
                var dir = try std.fs.cwd().openDir(session_dir, .{});
                defer dir.close();
                const ck = try core.session.compactSession(alloc, dir, sid.*, std.time.milliTimestamp());
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
                    .commands = "prompt,model,provider,tools,bg,new,resume,session,tree,fork,compact,quit",
                });
            },
            .commands => {
                const commands = [_][]const u8{
                    "prompt", "model", "provider", "tools", "bg", "new", "resume", "session", "tree", "fork", "compact", "help", "quit",
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

const CmdRes = enum {
    unhandled,
    handled,
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

fn handleSlashCommand(
    alloc: std.mem.Allocator,
    line: []const u8,
    sid: *([]u8),
    model: *([]const u8),
    model_owned: *?[]u8,
    provider: *([]const u8),
    provider_owned: *?[]u8,
    tools_rt: *core.tools.builtin.Runtime,
    bg_mgr: *bg.Mgr,
    session_dir_path: ?[]const u8,
    no_session: bool,
    _: ?[]const u8, // sys_prompt (unused after settings became interactive)
    out: std.Io.AnyWriter,
) !CmdRes {
    if (line.len == 0 or line[0] != '/') return .unhandled;

    const body = std.mem.trim(u8, line[1..], " \t");
    if (body.len == 0) return .handled;

    const sp = std.mem.indexOfAny(u8, body, " \t");
    const cmd = if (sp) |i| body[0..i] else body;
    const arg = if (sp) |i| std.mem.trim(u8, body[i + 1 ..], " \t") else "";

    const Cmd = enum { help, quit, exit, session, model, provider, tools, bg, new, @"resume", tree, fork, compact, @"export", settings, hotkeys, login, logout, clear, cost, copy, name, reload, share, changelog };
    const cmd_map = std.StaticStringMap(Cmd).initComptime(.{
        .{ "help", .help },
        .{ "quit", .quit },
        .{ "exit", .exit },
        .{ "session", .session },
        .{ "model", .model },
        .{ "provider", .provider },
        .{ "tools", .tools },
        .{ "bg", .bg },
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
        try writeTextLine(alloc, out, "unknown command: /{s}\n", .{cmd});
        return .handled;
    };

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
                \\  /login             Login (OAuth)
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
            const dup = try alloc.dupe(u8, arg);
            if (model_owned.*) |curr| alloc.free(curr);
            model_owned.* = dup;
            model.* = dup;
            try writeTextLine(alloc, out, "model set to {s}\n", .{dup});
        },
        .provider => {
            if (arg.len == 0) {
                try writeTextLine(alloc, out, "provider {s}\n", .{provider.*});
                return .handled;
            }
            const dup = try alloc.dupe(u8, arg);
            if (provider_owned.*) |curr| alloc.free(curr);
            provider_owned.* = dup;
            provider.* = dup;
            try writeTextLine(alloc, out, "provider set to {s}\n", .{dup});
        },
        .tools => {
            if (arg.len != 0) {
                const mask = parseCmdToolMask(arg) catch {
                    try out.writeAll("error: invalid tools value\n");
                    return .handled;
                };
                tools_rt.tool_mask = mask;
                const tool_csv = try toolMaskCsvAlloc(alloc, tools_rt.tool_mask);
                defer alloc.free(tool_csv);
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
        .new => {
            const next_sid = try newSid(alloc);
            alloc.free(sid.*);
            sid.* = next_sid;
            try writeTextLine(alloc, out, "new session {s}\n", .{sid.*});
        },
        .@"resume" => {
            if (arg.len == 0) return .select_session;
            applyResumeSid(alloc, sid, session_dir_path, no_session, arg) catch |err| {
                if (err == error.SessionDisabled) {
                    try out.writeAll("error: session disabled\n");
                    return .handled;
                }
                try writeTextLine(alloc, out, "error: resume failed ({s})\n", .{@errorName(err)});
                return .handled;
            };
            try writeTextLine(alloc, out, "resumed session {s}\n", .{sid.*});
        },
        .tree => {
            const session_dir = requireSessionDir(session_dir_path, no_session) catch {
                try out.writeAll("error: session disabled\n");
                return .handled;
            };
            const tree = try listSessionsAlloc(alloc, session_dir);
            defer alloc.free(tree);
            try out.writeAll(tree);
            if (tree.len == 0 or tree[tree.len - 1] != '\n') try out.writeAll("\n");
        },
        .fork => {
            if (arg.len == 0) return .select_fork;
            applyForkSid(alloc, sid, session_dir_path, no_session, arg) catch |err| {
                if (err == error.SessionDisabled) {
                    try out.writeAll("error: session disabled\n");
                    return .handled;
                }
                try writeTextLine(alloc, out, "error: fork failed ({s})\n", .{@errorName(err)});
                return .handled;
            };
            try writeTextLine(alloc, out, "forked session {s}\n", .{sid.*});
        },
        .compact => {
            const session_dir = requireSessionDir(session_dir_path, no_session) catch {
                try out.writeAll("error: session disabled\n");
                return .handled;
            };
            var dir = try std.fs.cwd().openDir(session_dir, .{});
            defer dir.close();
            const ck = try core.session.compactSession(alloc, dir, sid.*, std.time.milliTimestamp());
            try writeTextLine(alloc, out, "compacted in={d} out={d}\n", .{ ck.in_lines, ck.out_lines });
        },
        .@"export" => {
            const session_dir = requireSessionDir(session_dir_path, no_session) catch {
                try out.writeAll("error: session disabled\n");
                return .handled;
            };
            var dir = try std.fs.cwd().openDir(session_dir, .{});
            defer dir.close();
            const out_path = if (arg.len > 0) arg else null;
            const path = core.session.exportMarkdown(alloc, dir, sid.*, out_path) catch |err| {
                try writeTextLine(alloc, out, "export failed: {s}\n", .{@errorName(err)});
                return .handled;
            };
            defer alloc.free(path);
            try writeTextLine(alloc, out, "exported to {s}\n", .{path});
        },
        .settings => return .select_settings,
        .hotkeys => {
            try out.writeAll(
                \\Keyboard shortcuts:
                \\  Enter          Submit message
                \\  ESC            Clear input / Cancel
                \\  Ctrl+C         Clear input / Quit
                \\  Ctrl+D         Quit (when input empty)
                \\  Ctrl+Z         Undo
                \\  Ctrl+Shift+Z   Redo
                \\  Up/Down        Input history
                \\  Ctrl+A         Move to start
                \\  Ctrl+E         Move to end
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
                \\  Alt+Enter      Queue follow-up
                \\  Alt+Up         Edit queued messages
                \\  Page Up/Down   Scroll transcript (half page)
                \\  Scroll Up/Down Scroll transcript
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
                try out.writeAll("error: session disabled\n");
            }
        },
        .login => {
            if (arg.len == 0) return .select_login;
            // /login <provider> <key> — save API key
            const sp2 = std.mem.indexOfAny(u8, arg, " \t");
            if (sp2) |i| {
                const prov_name = arg[0..i];
                const key = std.mem.trim(u8, arg[i + 1 ..], " \t");
                if (key.len == 0) {
                    try out.writeAll("usage: /login <provider> <key>\n");
                    return .handled;
                }
                const prov_map = std.StaticStringMap(core.providers.auth.Provider).initComptime(.{
                    .{ "anthropic", .anthropic },
                    .{ "openai", .openai },
                    .{ "google", .google },
                });
                const prov = prov_map.get(prov_name) orelse {
                    try writeTextLine(alloc, out, "unknown provider: {s}\n", .{prov_name});
                    return .handled;
                };
                try core.providers.auth.saveApiKey(alloc, prov, key);
                try writeTextLine(alloc, out, "API key saved for {s}\n", .{prov_name});
            } else {
                try out.writeAll("usage: /login <provider> <key>\n");
            }
        },
        .logout => return .select_logout,
        .reload => return .reload,
        .share => {
            const session_dir = requireSessionDir(session_dir_path, no_session) catch {
                try out.writeAll("error: session disabled\n");
                return .handled;
            };
            var dir = try std.fs.cwd().openDir(session_dir, .{});
            defer dir.close();
            const md_path = core.session.exportMarkdown(alloc, dir, sid.*, null) catch |err| {
                try writeTextLine(alloc, out, "export failed: {s}\n", .{@errorName(err)});
                return .handled;
            };
            defer alloc.free(md_path);
            const gist_url = shareGist(alloc, md_path) catch |err| {
                try writeTextLine(alloc, out, "gist failed: {s}\n", .{@errorName(err)});
                return .handled;
            };
            defer alloc.free(gist_url);
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

fn runBgCommand(alloc: std.mem.Allocator, bg_mgr: *bg.Mgr, arg: []const u8) ![]u8 {
    const body = std.mem.trim(u8, arg, " \t");
    if (body.len == 0) {
        return alloc.dupe(u8, "usage: /bg run <cmd>|list|show <id>|stop <id>\n");
    }

    const sp = std.mem.indexOfAny(u8, body, " \t");
    const sub = if (sp) |i| body[0..i] else body;
    const rest = if (sp) |i| std.mem.trim(u8, body[i + 1 ..], " \t") else "";

    if (std.mem.eql(u8, sub, "run")) {
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
    }

    if (std.mem.eql(u8, sub, "list")) {
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
    }

    if (std.mem.eql(u8, sub, "show")) {
        const id = parseBgId(rest) catch return alloc.dupe(u8, "usage: /bg show <id>\n");
        const v = (try bg_mgr.view(alloc, id)) orelse return alloc.dupe(u8, "bg: not found\n");
        defer bg.deinitView(alloc, v);

        return std.fmt.allocPrint(alloc, "id={d}\npid={d}\nstate={s}\ncode={?d}\nstarted_ms={d}\nended_ms={?d}\nlog={s}\ncmd={s}\n", .{
            v.id,
            v.pid,
            bg.stateName(v.state),
            v.code,
            v.started_at_ms,
            v.ended_at_ms,
            v.log_path,
            v.cmd,
        });
    }

    if (std.mem.eql(u8, sub, "stop")) {
        const id = parseBgId(rest) catch return alloc.dupe(u8, "usage: /bg stop <id>\n");
        const stop = try bg_mgr.stop(id);
        return switch (stop) {
            .sent => std.fmt.allocPrint(alloc, "bg stop sent id={d}\n", .{id}),
            .already_done => std.fmt.allocPrint(alloc, "bg already done id={d}\n", .{id}),
            .not_found => std.fmt.allocPrint(alloc, "bg not found id={d}\n", .{id}),
        };
    }

    return alloc.dupe(u8, "usage: /bg run <cmd>|list|show <id>|stop <id>\n");
}

fn parseBgId(text: []const u8) !u64 {
    const tok = std.mem.trim(u8, text, " \t");
    if (tok.len == 0) return error.InvalidId;
    return std.fmt.parseInt(u64, tok, 10);
}

fn flushBgDone(alloc: std.mem.Allocator, ui: *tui_harness.Ui, bg_mgr: *bg.Mgr) !void {
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
            try std.fmt.allocPrint(alloc, "[bg {d} {s} code={?d} log={s}]", .{
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

fn syncBgFooter(alloc: std.mem.Allocator, ui: *tui_harness.Ui, bg_mgr: *bg.Mgr) !void {
    const jobs = try bg_mgr.list(alloc);
    defer bg.deinitViews(alloc, jobs);

    const launched: u32 = @intCast(jobs.len);
    var running: u32 = 0;
    for (jobs) |job| {
        if (job.state == .running) running +%= 1;
    }
    const done: u32 = launched -| running;
    ui.pn.setBgStatus(launched, running, done);
}

fn shareGist(alloc: std.mem.Allocator, md_path: []const u8) ![]u8 {
    const result = try std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "gh", "gist", "create", "--public=false", md_path },
    });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    if (result.term.Exited != 0) return error.GistFailed;
    const url = std.mem.trim(u8, result.stdout, " \t\n\r");
    if (url.len == 0) return error.GistFailed;
    return try alloc.dupe(u8, url);
}

fn writeJsonLine(
    alloc: std.mem.Allocator,
    out: std.Io.AnyWriter,
    value: anytype,
) !void {
    const raw = try std.json.Stringify.valueAlloc(alloc, value, .{});
    defer alloc.free(raw);
    try out.writeAll(raw);
    try out.writeAll("\n");
}

fn writeTextLine(
    alloc: std.mem.Allocator,
    out: std.Io.AnyWriter,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const raw = try std.fmt.allocPrint(alloc, fmt, args);
    defer alloc.free(raw);
    try out.writeAll(raw);
}

fn listUserMessages(alloc: std.mem.Allocator, session_dir: []const u8, sid: []const u8) ![][]u8 {
    var dir = try std.fs.cwd().openDir(session_dir, .{});
    defer dir.close();

    var rdr = core.session.reader.ReplayReader.init(alloc, dir, sid, .{}) catch return try alloc.alloc([]u8, 0);
    defer rdr.deinit();

    var msgs = std.ArrayList([]u8).empty;
    errdefer {
        for (msgs.items) |m| alloc.free(m);
        msgs.deinit(alloc);
    }

    while (rdr.next() catch null) |ev| {
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

    const f = std.fs.openFileAbsolute(abs, .{ .mode = .read_only }) catch |err| switch (err) {
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
    defer f.close();

    const st = try f.stat();
    var lines: usize = 0;
    var user_msgs: u32 = 0;
    var asst_msgs: u32 = 0;
    var tool_calls: u32 = 0;
    var tool_results: u32 = 0;
    // Replay once to count lines and message types.
    if (session_dir_path) |sdp| {
        var dir = std.fs.cwd().openDir(sdp, .{}) catch return .{
            .path = abs,
            .path_owned = abs,
            .bytes = st.size,
            .lines = lines,
        };
        defer dir.close();
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
                else => {},
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

fn parseCmdToolMask(raw: []const u8) !u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidToolMask;
    const special = std.StaticStringMap(u8).initComptime(.{
        .{ "all", core.tools.builtin.mask_all },
        .{ "none", 0 },
    });
    if (special.get(trimmed)) |m| return m;

    var mask: u8 = 0;
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

const tui_cmdprev = @import("../modes/tui/cmdprev.zig");

fn completeSlashCmd(ed: *tui_harness.editor.Editor) void {
    const text = ed.text();
    if (text.len == 0 or text[0] != '/') return;
    const prefix = text[1..];
    var match: ?[]const u8 = null;
    var count: usize = 0;
    for (tui_cmdprev.cmds) |cmd| {
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

    const items = tui_pathcomp.list(alloc, prefix) orelse return;
    defer tui_pathcomp.freeList(alloc, items);

    const repl: []const u8 = if (items.len == 1)
        items[0]
    else blk: {
        const cp = tui_pathcomp.commonPrefix(tui_pathcomp.asConst(items));
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

fn toolMaskCsvAlloc(alloc: std.mem.Allocator, mask: u8) ![]u8 {
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
    };
    const bits = [_]u8{
        core.tools.builtin.mask_read,
        core.tools.builtin.mask_write,
        core.tools.builtin.mask_bash,
        core.tools.builtin.mask_edit,
        core.tools.builtin.mask_grep,
        core.tools.builtin.mask_find,
        core.tools.builtin.mask_ls,
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

fn applyResumeSid(
    alloc: std.mem.Allocator,
    sid: *([]u8),
    session_dir_path: ?[]const u8,
    no_session: bool,
    token: ?[]const u8,
) (SessionOpErr || anyerror)!void {
    const dir = try requireSessionDir(session_dir_path, no_session);
    const next_sid = try resolveResumeSid(alloc, dir, token);
    alloc.free(sid.*);
    sid.* = next_sid;
}

fn applyForkSid(
    alloc: std.mem.Allocator,
    sid: *([]u8),
    session_dir_path: ?[]const u8,
    no_session: bool,
    token: ?[]const u8,
) (SessionOpErr || anyerror)!void {
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
    var dir = try std.fs.cwd().openDir(session_dir, .{ .iterate = true });
    defer dir.close();

    var names = std.ArrayList([]u8).empty;
    defer {
        for (names.items) |n| alloc.free(n);
        names.deinit(alloc);
    }

    var it = dir.iterate();
    while (try it.next()) |ent| {
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

fn listSessionSids(alloc: std.mem.Allocator, session_dir: []const u8) ![][]u8 {
    var dir = try std.fs.cwd().openDir(session_dir, .{ .iterate = true });
    defer dir.close();

    var names = std.ArrayList([]u8).empty;
    errdefer {
        for (names.items) |n| alloc.free(n);
        names.deinit(alloc);
    }

    var it = dir.iterate();
    while (try it.next()) |ent| {
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

fn fileSidFromName(name: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, name, ".jsonl")) return null;
    if (name.len <= ".jsonl".len) return null;
    return name[0 .. name.len - ".jsonl".len];
}

fn forkSessionFile(session_dir: []const u8, src_sid: []const u8, dst_sid: []const u8) !void {
    var dir = try std.fs.cwd().openDir(session_dir, .{});
    defer dir.close();

    var src_buf: [256]u8 = undefined;
    const src_path = std.fmt.bufPrint(&src_buf, "{s}.jsonl", .{src_sid}) catch return error.NameTooLong;
    var dst_buf: [256]u8 = undefined;
    const dst_path = std.fmt.bufPrint(&dst_buf, "{s}.jsonl", .{dst_sid}) catch return error.NameTooLong;

    var dst = try dir.createFile(dst_path, .{
        .truncate = true,
    });
    defer dst.close();

    var src = dir.openFile(src_path, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer src.close();

    var buf: [8192]u8 = undefined;
    while (true) {
        const n = try src.read(&buf);
        if (n == 0) break;
        try dst.writeAll(buf[0..n]);
    }
    try dst.sync();
}

fn newSid(alloc: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(alloc, "{d}", .{std.time.microTimestamp()});
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

fn getCwd(alloc: std.mem.Allocator) ![]u8 {
    const full = try std.fs.cwd().realpathAlloc(alloc, ".");
    // Shorten home prefix to ~/ (matching pi)
    const home = std.posix.getenv("HOME") orelse "";
    if (home.len > 0 and std.mem.startsWith(u8, full, home)) {
        const short = try std.fmt.allocPrint(alloc, "~{s}", .{full[home.len..]});
        alloc.free(full);
        return short;
    }
    return full;
}

fn getGitBranch(alloc: std.mem.Allocator) ![]u8 {
    // Try jj bookmark first (jj always detaches HEAD)
    if (getJjBookmark(alloc)) |b| return b;

    const head = std.fs.cwd().readFileAlloc(alloc, ".git/HEAD", 256) catch return error.NotFound;
    defer alloc.free(head);
    const prefix = "ref: refs/heads/";
    if (std.mem.startsWith(u8, head, prefix)) {
        const rest = std.mem.trimRight(u8, head[prefix.len..], "\n\r ");
        return try alloc.dupe(u8, rest);
    }
    // Detached HEAD — show "detached" like pi
    return try alloc.dupe(u8, "detached");
}

fn getJjBookmark(alloc: std.mem.Allocator) ?[]u8 {
    // Check if .jj/ exists (jj-managed repo)
    std.fs.cwd().access(".jj", .{}) catch return null;

    // Run jj log to get bookmarks for current change
    const argv = [_][]const u8{ "jj", "log", "--no-graph", "-r", "@", "-T", "bookmarks" };
    var child = std.process.Child.init(argv[0..], alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return null;
    const stdout = child.stdout.?.readToEndAlloc(alloc, 4096) catch {
        _ = child.wait() catch |err| {
            std.debug.print("warning: child wait failed: {s}\n", .{@errorName(err)});
        };
        return null;
    };
    _ = child.wait() catch {
        alloc.free(stdout);
        return null;
    };

    const trimmed = std.mem.trimRight(u8, stdout, "\n\r ");
    if (trimmed.len == 0) {
        alloc.free(stdout);
        return null;
    }

    // May have multiple bookmarks separated by space; take first, strip trailing *
    var it = std.mem.splitScalar(u8, trimmed, ' ');
    const first = it.next() orelse {
        alloc.free(stdout);
        return null;
    };
    const name = if (first.len > 0 and first[first.len - 1] == '*')
        first[0 .. first.len - 1]
    else
        first;

    const result = alloc.dupe(u8, name) catch {
        alloc.free(stdout);
        return null;
    };
    alloc.free(stdout);
    return result;
}

const default_model = "claude-opus-4-6";
const default_provider = "anthropic";

fn resolveDefault(model: []const u8) []const u8 {
    return if (std.mem.eql(u8, model, "default")) default_model else model;
}

fn resolveDefaultProvider(provider: []const u8) []const u8 {
    return if (std.mem.eql(u8, provider, "default")) default_provider else provider;
}

fn modelCtxWindow(model: []const u8) u64 {
    const table = .{
        .{ "opus-4", 200000 },
        .{ "sonnet-4", 200000 },
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

fn buildSystemPrompt(alloc: std.mem.Allocator, run_cmd: cli.Run) !?[]u8 {
    if (run_cmd.system_prompt) |sp| {
        if (run_cmd.append_system_prompt) |ap| {
            return try std.fmt.allocPrint(alloc, "{s}\n\n{s}", .{ sp, ap });
        }
        return try alloc.dupe(u8, sp);
    }

    const ctx = try core.context.load(alloc);
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
    "claude-opus-4-6",
    "claude-sonnet-4-5",
    "claude-haiku-4-5-20251001",
};

const provider_args = [_][]const u8{ "anthropic", "openai", "google" };
const tool_args = [_][]const u8{ "all", "none", "read", "write", "bash", "edit", "grep", "find", "ls" };
const bg_args = [_][]const u8{ "run", "list", "show", "stop" };

/// Resolve arg completion source based on current editor text.
fn resolveArgSrc(text: []const u8, models: []const []const u8) ?[]const []const u8 {
    if (text.len == 0 or text[0] != '/') return null;
    const body = text[1..];
    const sp = std.mem.indexOfScalar(u8, body, ' ') orelse return null;
    const cmd = body[0..sp];
    if (std.mem.eql(u8, cmd, "model")) return models;
    if (std.mem.eql(u8, cmd, "provider")) return &provider_args;
    if (std.mem.eql(u8, cmd, "tools")) return &tool_args;
    if (std.mem.eql(u8, cmd, "bg")) return &bg_args;
    if (std.mem.eql(u8, cmd, "login") or std.mem.eql(u8, cmd, "logout")) return &provider_args;
    return null;
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

fn showStartup(alloc: std.mem.Allocator, ui: *tui_harness.Ui, is_resumed: bool) !void {
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
        .{ "ctrl+z", "to suspend" },
        .{ "up/down", "for input history" },
        .{ "ctrl+a/e", "to start/end of line" },
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
        .{ "alt+up", "to edit all queued messages" },
        .{ "ctrl+v", "to paste image" },
        .{ "drop files", "to attach" },
    };
    for (keys) |kv| {
        // key in dim, description in muted (matching pi)
        const line = try std.fmt.allocPrint(alloc, " \x1b[38;2;102;102;102m{s}\x1b[38;2;128;128;128m {s}\x1b[0m", .{ kv[0], kv[1] });
        defer alloc.free(line);
        try ui.tr.pushAnsiText(line);
    }

    // Context section
    const ctx_paths = try core.context.discoverPaths(alloc);
    defer {
        for (ctx_paths) |p| alloc.free(p);
        alloc.free(ctx_paths);
    }
    if (ctx_paths.len > 0) {
        try ui.tr.styledText("", .{}); // blank line
        try ui.tr.styledText("", .{}); // blank line (pi has 2)
        try ui.tr.styledText("[Context]", .{ .fg = t.md_heading });
        const home = std.posix.getenv("HOME") orelse "";
        for (ctx_paths) |p| {
            // Shorten home prefix to ~/
            const display = if (home.len > 0 and std.mem.startsWith(u8, p, home))
                try std.fmt.allocPrint(alloc, "  ~{s}", .{p[home.len..]})
            else
                try std.fmt.allocPrint(alloc, "  {s}", .{p});
            defer alloc.free(display);
            try ui.tr.infoText(display);
        }
    }

    // Skills section
    const skills = try discoverSkills(alloc);
    defer {
        for (skills) |s| alloc.free(s);
        alloc.free(skills);
    }
    if (skills.len > 0) {
        try ui.tr.styledText("", .{}); // blank line
        try ui.tr.styledText("[Skills]", .{ .fg = t.md_heading });
        try ui.tr.infoText("  user");
        const home2 = std.posix.getenv("HOME") orelse "";
        for (skills) |p| {
            const display2 = if (home2.len > 0 and std.mem.startsWith(u8, p, home2))
                try std.fmt.allocPrint(alloc, "    ~{s}", .{p[home2.len..]})
            else
                try std.fmt.allocPrint(alloc, "    {s}", .{p});
            defer alloc.free(display2);
            try ui.tr.infoText(display2);
        }
    }

    // What's New section (only on fresh sessions)
    if (!is_resumed) {
        var state = config.PzState.load(alloc) orelse config.PzState{};
        defer state.deinit(alloc);

        const new_entries = changelog.entriesSince(state.last_hash);
        if (new_entries.len > 0) {
            const formatted = try changelog.formatRaw(alloc, new_entries, 10);
            defer alloc.free(formatted);
            try ui.tr.styledText("", .{}); // blank line
            try ui.tr.styledText("[What's New]", .{ .fg = t.md_heading });
            // Split and display each line
            var off: usize = 0;
            while (off < formatted.len) {
                const eol = std.mem.indexOfScalarPos(u8, formatted, off, '\n') orelse formatted.len;
                try ui.tr.infoText(formatted[off..eol]);
                off = eol + 1;
            }
        }

        // Update state with current git hash
        const new_state = config.PzState{ .last_hash = cli.git_hash };
        new_state.save(alloc);
    }

    // Trailing blank lines before prompt (matching pi's spacing)
    try ui.tr.styledText("", .{});
    try ui.tr.styledText("", .{});
}

fn discoverSkills(alloc: std.mem.Allocator) ![][]u8 {
    const home = std.posix.getenv("HOME") orelse return &.{};
    const base = std.fs.path.join(alloc, &.{ home, ".claude", "skills" }) catch return &.{};
    defer alloc.free(base);

    var dir = std.fs.cwd().openDir(base, .{ .iterate = true }) catch return &.{};
    defer dir.close();

    var paths: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (paths.items) |p| alloc.free(p);
        paths.deinit(alloc);
    }

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        const skill_path = std.fs.path.join(alloc, &.{ base, entry.name, "SKILL.md" }) catch continue;
        // Check file exists
        if (std.fs.cwd().access(skill_path, .{})) |_| {
            try paths.append(alloc, skill_path);
        } else |_| {
            alloc.free(skill_path);
        }
    }

    // Sort for stable display
    std.mem.sort([]u8, paths.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    return try paths.toOwnedSlice(alloc);
}

fn showCost(_: std.mem.Allocator, ui: *tui_harness.Ui) !void {
    const u = ui.pn.usage;
    const mc = ui.pn.cost_micents;

    // Format cost as $N.NNN
    var cost_buf: [24]u8 = undefined;
    const cost_str = if (mc > 0)
        std.fmt.bufPrint(&cost_buf, "${d}.{d:0>3}", .{ mc / 100_000, (mc % 100_000) / 100 }) catch "?"
    else
        "$0.000";

    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();
    try w.print("Tokens  in: {d}  out: {d}  total: {d}", .{ u.in_tok, u.out_tok, u.tot_tok });
    if (u.cache_read > 0 or u.cache_write > 0)
        try w.print("\nCache   read: {d}  write: {d}", .{ u.cache_read, u.cache_write });
    try w.print("\nCost    {s}", .{cost_str});
    try ui.tr.infoText(fbs.getWritten());
}

fn copyLastResponse(alloc: std.mem.Allocator, ui: *tui_harness.Ui) !void {
    const text = ui.lastResponseText() orelse {
        try ui.tr.infoText("[nothing to copy]");
        return;
    };
    const clip_cmds = [_][]const u8{ "pbcopy", "xclip", "xsel", "wl-copy" };
    for (clip_cmds) |cmd| {
        if (try pipeToCmd(alloc, cmd, text)) {
            try ui.tr.infoText("[copied to clipboard]");
            return;
        }
    }
    try ui.tr.infoText("[copy failed: no clipboard tool found]");
}

fn pipeToCmd(alloc: std.mem.Allocator, cmd: []const u8, text: []const u8) !bool {
    const argv = [_][]const u8{cmd};
    var child = std.process.Child.init(argv[0..], alloc);
    child.stdin_behavior = .Pipe;
    child.spawn() catch return false;
    if (child.stdin) |*stdin| {
        try stdin.writeAll(text);
        stdin.close();
        child.stdin = null;
    }
    const term = child.wait() catch return false;
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

const compact_threshold_pct: u32 = 80;

fn autoCompact(
    alloc: std.mem.Allocator,
    ui: *tui_harness.Ui,
    sid: []const u8,
    session_dir_path: ?[]const u8,
    no_session: bool,
) !void {
    if (no_session or session_dir_path == null) return;
    if (ui.pn.ctx_limit == 0) return;
    if (!ui.pn.has_usage) return;
    const pct = ui.pn.cum_tok *| 100 / ui.pn.ctx_limit;
    if (pct < compact_threshold_pct) return;

    var dir = try std.fs.cwd().openDir(session_dir_path.?, .{});
    defer dir.close();
    const now = std.time.milliTimestamp();
    _ = core.session.compactSession(alloc, dir, sid, now) catch |err| {
        const msg = try std.fmt.allocPrint(alloc, "[auto-compact failed: {s}]", .{@errorName(err)});
        defer alloc.free(msg);
        try ui.tr.infoText(msg);
        return;
    };
    try ui.tr.infoText("[session compacted]");
}

const BashCmd = struct {
    cmd: []const u8,
    include: bool, // true = !cmd (include in context), false = !!cmd (exclude)
};

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
    store: core.session.SessionStore,
) !void {
    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "/bin/bash", "-lc", bcmd.cmd },
        .max_output_bytes = 256 * 1024,
    }) catch |err| {
        const msg = try std.fmt.allocPrint(alloc, "bash error: {s}", .{@errorName(err)});
        defer alloc.free(msg);
        try ui.tr.append(.{ .err = msg });
        return;
    };
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    const output = if (result.stdout.len > 0) result.stdout else result.stderr;
    const is_err = switch (result.term) {
        .Exited => |code| code != 0,
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
        .out = if (output.len > 0) output else "(no output)",
        .is_err = is_err,
    } });

    // Save to session if include mode
    if (bcmd.include) {
        try store.append(sid, .{ .data = .{ .prompt = .{ .text = bcmd.cmd } } });
        try store.append(sid, .{ .data = .{ .tool_call = .{
            .id = "bash",
            .name = "bash",
            .args = bcmd.cmd,
        } } });
        try store.append(sid, .{ .data = .{ .tool_result = .{
            .id = "bash",
            .out = if (output.len > 0) output else "(no output)",
            .is_err = is_err,
        } } });
    }
}

fn openExtEditor(alloc: std.mem.Allocator, current: []const u8) !?[]u8 {
    const ed = std.posix.getenv("EDITOR") orelse std.posix.getenv("VISUAL") orelse "vi";

    // Write current text to unique temp file
    var tmp_buf: [64]u8 = undefined;
    const ts: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    const tmp = try std.fmt.bufPrint(&tmp_buf, "/tmp/pz-edit-{d}.txt", .{ts});
    defer std.fs.deleteFileAbsolute(tmp) catch |err| {
        std.debug.print("warning: temp file cleanup failed: {s}\n", .{@errorName(err)});
    };
    {
        const f = try std.fs.createFileAbsolute(tmp, .{});
        defer f.close();
        try f.writeAll(current);
    }

    const argv = [_][]const u8{ ed, tmp };
    var child = std.process.Child.init(argv[0..], alloc);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    _ = try child.wait();

    // Read back
    const f = try std.fs.openFileAbsolute(tmp, .{});
    defer f.close();
    const content = try f.readToEndAlloc(alloc, 1024 * 1024);
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

fn pasteImage(alloc: std.mem.Allocator, ui: *tui_harness.Ui) !void {
    // macOS: check clipboard for image via osascript
    const argv = [_][]const u8{
        "osascript",                                                                                                     "-e",
        "try\nset theType to (clipboard info for «class PNGf»)\nreturn \"image\"\non error\nreturn \"none\"\nend try",
    };
    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = argv[0..],
        .max_output_bytes = 256,
    }) catch {
        try ui.tr.infoText("[paste: clipboard check failed]");
        return;
    };
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (!std.mem.eql(u8, trimmed, "image")) {
        try pasteText(alloc, ui);
        return;
    }

    // Save clipboard image to temp file
    const save_argv = [_][]const u8{
        "osascript",                                                                                                                                                              "-e",
        "set imgData to the clipboard as «class PNGf»\nset fp to open for access POSIX file \"/tmp/pz-paste.png\" with write permission\nwrite imgData to fp\nclose access fp",
    };
    const save_result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = save_argv[0..],
        .max_output_bytes = 256,
    }) catch {
        try ui.tr.infoText("[paste: save failed]");
        return;
    };
    defer alloc.free(save_result.stdout);
    defer alloc.free(save_result.stderr);

    ui.tr.imageBlock("/tmp/pz-paste.png") catch |err| {
        ui.tr.infoText("[pasted image: /tmp/pz-paste.png]") catch return err;
    };
}

fn pasteText(alloc: std.mem.Allocator, ui: *tui_harness.Ui) !void {
    const argv = [_][]const u8{"pbpaste"};
    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = argv[0..],
        .max_output_bytes = 256 * 1024,
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
    provider: core.providers.Provider,
    store: core.session.SessionStore,
    tools_rt: *core.tools.builtin.Runtime,
    mode: core.loop.ModeSink,
    max_turns: u16 = 0,
    cancel: ?core.loop.CancelSrc = null,

    const TurnOpts = struct {
        sid: []const u8,
        prompt: []const u8,
        model: []const u8,
        provider_label: []const u8 = "",
        provider_opts: core.providers.Opts = .{},
        system_prompt: ?[]const u8 = null,
    };

    fn run(self: *const TurnCtx, opts: TurnOpts) !void {
        _ = try core.loop.run(.{
            .alloc = self.alloc,
            .sid = opts.sid,
            .prompt = opts.prompt,
            .model = opts.model,
            .provider_label = opts.provider_label,
            .provider = self.provider,
            .store = self.store,
            .reg = self.tools_rt.registry(),
            .mode = self.mode,
            .system_prompt = opts.system_prompt,
            .provider_opts = opts.provider_opts,
            .max_turns = self.max_turns,
            .cancel = self.cancel,
        });
    }
};

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

fn eofReader() std.Io.AnyReader {
    const S = struct {
        fn read(_: *const anyopaque, buf: []u8) anyerror!usize {
            _ = buf;
            return 0; // EOF
        }
    };
    return .{ .context = undefined, .readFn = &S.read };
}

test "runtime executes print mode and persists session events" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("sess");
    const sess_abs = try tmp.dir.realpathAlloc(std.testing.allocator, "sess");
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
    var out_fbs = std.io.fixedBufferStream(&out_buf);

    const sid = try execWithIo(std.testing.allocator, cfg, eofReader(), out_fbs.writer().any());
    defer std.testing.allocator.free(sid);

    var session_dir = try std.fs.openDirAbsolute(sess_abs, .{});
    defer session_dir.close();

    var rdr = try core.session.ReplayReader.init(std.testing.allocator, session_dir, sid, .{});
    defer rdr.deinit();

    const ev0 = (try rdr.next()) orelse return error.TestUnexpectedResult;
    switch (ev0.data) {
        .prompt => |out| try std.testing.expectEqualStrings("ping", out.text),
        else => return error.TestUnexpectedResult,
    }

    const ev1 = (try rdr.next()) orelse return error.TestUnexpectedResult;
    switch (ev1.data) {
        .text => |out| try std.testing.expectEqualStrings("pong", out.text),
        else => return error.TestUnexpectedResult,
    }

    const ev2 = (try rdr.next()) orelse return error.TestUnexpectedResult;
    switch (ev2.data) {
        .stop => |out| try std.testing.expect(out.reason == .done),
        else => return error.TestUnexpectedResult,
    }

    try std.testing.expect((try rdr.next()) == null);
    // Non-verbose: only text output, no stop metadata
    try std.testing.expectEqualStrings("pong\n", out_fbs.getWritten());
}

test "runtime executes tool calls through loop registry in print mode" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("sess");
    const sess_abs = try tmp.dir.realpathAlloc(std.testing.allocator, "sess");
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
    var out_fbs = std.io.fixedBufferStream(&out_buf);

    const sid = try execWithIo(std.testing.allocator, cfg, eofReader(), out_fbs.writer().any());
    defer std.testing.allocator.free(sid);

    const written = out_fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, written, "done") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "tool_result id=\"call-1\" is_err=false out=\"hi\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "stop reason=done") != null);
}

test "runtime forwards provider label to provider request" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("sess");
    const sess_abs = try tmp.dir.realpathAlloc(std.testing.allocator, "sess");
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
    var out_fbs = std.io.fixedBufferStream(&out_buf);

    const sid = try execWithIo(std.testing.allocator, cfg, eofReader(), out_fbs.writer().any());
    defer std.testing.allocator.free(sid);

    const written = out_fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, written, "provider=prov-x") != null);
}

test "runtime executes tui mode path with provided prompt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("sess");
    const sess_abs = try tmp.dir.realpathAlloc(std.testing.allocator, "sess");
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
    var out_fbs = std.io.fixedBufferStream(&out_buf);

    const sid = try execWithIo(std.testing.allocator, cfg, eofReader(), out_fbs.writer().any());
    defer std.testing.allocator.free(sid);

    const written = out_fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, written, "\x1b[2J") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "pong") != null);

    var session_dir = try std.fs.openDirAbsolute(sess_abs, .{});
    defer session_dir.close();

    var rdr = try core.session.ReplayReader.init(std.testing.allocator, session_dir, sid, .{});
    defer rdr.deinit();

    const ev0 = (try rdr.next()) orelse return error.TestUnexpectedResult;
    switch (ev0.data) {
        .prompt => |out| try std.testing.expectEqualStrings("ping", out.text),
        else => return error.TestUnexpectedResult,
    }
}

test "runtime tui reports error when no provider available" {
    // Skip if auth file exists (native provider would attempt real HTTP)
    const auth_res = core.providers.auth.load(std.testing.allocator);
    if (auth_res) |*r| {
        var result = r.*;
        result.deinit();
        return error.SkipZigTest;
    } else |_| {}

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("sess");
    const sess_abs = try tmp.dir.realpathAlloc(std.testing.allocator, "sess");
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
    var out_fbs = std.io.fixedBufferStream(&out_buf);

    const sid = try execWithIo(std.testing.allocator, cfg, eofReader(), out_fbs.writer().any());
    defer std.testing.allocator.free(sid);

    const written = out_fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, written, "provider_cmd missing") != null);
}

test "runtime tui consumes multiple prompts from input stream" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("sess");
    const sess_abs = try tmp.dir.realpathAlloc(std.testing.allocator, "sess");
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

    var in_fbs = std.io.fixedBufferStream("first\nsecond\n");
    var out_buf: [32768]u8 = undefined;
    var out_fbs = std.io.fixedBufferStream(&out_buf);

    const sid = try execWithIo(
        std.testing.allocator,
        cfg,
        in_fbs.reader().any(),
        out_fbs.writer().any(),
    );
    defer std.testing.allocator.free(sid);

    const written = out_fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, written, "u1") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "u2") != null);

    var session_dir = try std.fs.openDirAbsolute(sess_abs, .{});
    defer session_dir.close();
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
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 2), prompt_ct);
}

test "runtime tui rejects blank-only stdin input" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("sess");
    const sess_abs = try tmp.dir.realpathAlloc(std.testing.allocator, "sess");
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

    var in_fbs = std.io.fixedBufferStream("\n\r\n\n");
    var out_buf: [16384]u8 = undefined;
    var out_fbs = std.io.fixedBufferStream(&out_buf);

    try std.testing.expectError(
        error.EmptyPrompt,
        execWithIo(
            std.testing.allocator,
            cfg,
            in_fbs.reader().any(),
            out_fbs.writer().any(),
        ),
    );
}

test "runtime continue reuses latest session id and appends new turn" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("sess");
    const sess_abs = try tmp.dir.realpathAlloc(std.testing.allocator, "sess");
    defer std.testing.allocator.free(sess_abs);

    {
        const old_file = try tmp.dir.createFile("sess/100.jsonl", .{});
        defer old_file.close();
        const old_ev = try core.session.encodeEventAlloc(std.testing.allocator, .{
            .at_ms = 1,
            .data = .{ .prompt = .{ .text = "old-100" } },
        });
        defer std.testing.allocator.free(old_ev);
        try old_file.writeAll(old_ev);
        try old_file.writeAll("\n");
    }
    {
        const old_file = try tmp.dir.createFile("sess/200.jsonl", .{});
        defer old_file.close();
        const old_ev = try core.session.encodeEventAlloc(std.testing.allocator, .{
            .at_ms = 1,
            .data = .{ .prompt = .{ .text = "old-200" } },
        });
        defer std.testing.allocator.free(old_ev);
        try old_file.writeAll(old_ev);
        try old_file.writeAll("\n");
    }

    var cfg = cli.Run{
        .mode = .print,
        .prompt = "new-turn",
        .session = .cont,
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
    var out_fbs = std.io.fixedBufferStream(&out_buf);

    const sid = try execWithIo(std.testing.allocator, cfg, eofReader(), out_fbs.writer().any());
    defer std.testing.allocator.free(sid);
    try std.testing.expectEqualStrings("200", sid);

    var dir = try std.fs.openDirAbsolute(sess_abs, .{});
    defer dir.close();
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
            else => {},
        }
    }
    try std.testing.expect(saw_new);
}

test "runtime explicit session path resumes that session id" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("sess");
    const sess_abs = try tmp.dir.realpathAlloc(std.testing.allocator, "sess");
    defer std.testing.allocator.free(sess_abs);

    {
        const old_file = try tmp.dir.createFile("sess/sid-1.jsonl", .{});
        defer old_file.close();
        const old_ev = try core.session.encodeEventAlloc(std.testing.allocator, .{
            .at_ms = 1,
            .data = .{ .prompt = .{ .text = "old" } },
        });
        defer std.testing.allocator.free(old_ev);
        try old_file.writeAll(old_ev);
        try old_file.writeAll("\n");
    }

    const sid_path = try tmp.dir.realpathAlloc(std.testing.allocator, "sess/sid-1.jsonl");
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
    var out_fbs = std.io.fixedBufferStream(&out_buf);
    const sid = try execWithIo(std.testing.allocator, cfg, eofReader(), out_fbs.writer().any());
    defer std.testing.allocator.free(sid);
    try std.testing.expectEqualStrings("sid-1", sid);
}

test "runtime no session mode does not persist jsonl files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("sess");
    const sess_abs = try tmp.dir.realpathAlloc(std.testing.allocator, "sess");
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
    var out_fbs = std.io.fixedBufferStream(&out_buf);

    const sid = try execWithIo(std.testing.allocator, cfg, eofReader(), out_fbs.writer().any());
    defer std.testing.allocator.free(sid);

    var sess_dir = try std.fs.openDirAbsolute(sess_abs, .{ .iterate = true });
    defer sess_dir.close();
    var it = sess_dir.iterate();
    try std.testing.expect((try it.next()) == null);
}

test "runtime tool mask filters builtins used by loop registry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("sess");
    const sess_abs = try tmp.dir.realpathAlloc(std.testing.allocator, "sess");
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
    var out_fbs = std.io.fixedBufferStream(&out_buf);

    const sid = try execWithIo(
        std.testing.allocator,
        cfg,
        null,
        out_fbs.writer().any(),
    );
    defer std.testing.allocator.free(sid);

    const written = out_fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, written, "tool_result id=\"call-1\" is_err=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "tool-not-found:bash") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "stop reason=done") != null);
}

test "runtime json mode emits JSON lines for loop events" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("sess");
    const sess_abs = try tmp.dir.realpathAlloc(std.testing.allocator, "sess");
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
    var out_fbs = std.io.fixedBufferStream(&out_buf);

    const sid = try execWithIo(std.testing.allocator, cfg, eofReader(), out_fbs.writer().any());
    defer std.testing.allocator.free(sid);

    const written = out_fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"type\":\"session\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"type\":\"provider\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "pong") != null);
}

test "runtime rpc mode handles session model prompt and quit commands" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("sess");
    const sess_abs = try tmp.dir.realpathAlloc(std.testing.allocator, "sess");
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

    var in_fbs = std.io.fixedBufferStream(
        "{\"cmd\":\"session\"}\n" ++
            "{\"cmd\":\"tools\",\"arg\":\"read,write\"}\n" ++
            "{\"cmd\":\"model\",\"arg\":\"m2\"}\n" ++
            "{\"cmd\":\"provider\",\"arg\":\"p2\"}\n" ++
            "{\"cmd\":\"prompt\",\"text\":\"ping\"}\n" ++
            "{\"cmd\":\"session\"}\n" ++
            "{\"cmd\":\"quit\"}\n",
    );
    var out_buf: [32768]u8 = undefined;
    var out_fbs = std.io.fixedBufferStream(&out_buf);

    const sid = try execWithIo(
        std.testing.allocator,
        cfg,
        in_fbs.reader().any(),
        out_fbs.writer().any(),
    );
    defer std.testing.allocator.free(sid);

    const written = out_fbs.getWritten();
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

    try tmp.dir.makePath("sess");
    const sess_abs = try tmp.dir.realpathAlloc(std.testing.allocator, "sess");
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

    var in_fbs = std.io.fixedBufferStream("/help\n/session\n/provider p2\n/tools read\n/settings\n/new\n/quit\n");
    var out_buf: [32768]u8 = undefined;
    var out_fbs = std.io.fixedBufferStream(&out_buf);

    const sid = try execWithIo(
        std.testing.allocator,
        cfg,
        in_fbs.reader().any(),
        out_fbs.writer().any(),
    );
    defer std.testing.allocator.free(sid);

    const written = out_fbs.getWritten();
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

test "runtime tui bg command starts and lists background jobs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("sess");
    const sess_abs = try tmp.dir.realpathAlloc(std.testing.allocator, "sess");
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

    var in_fbs = std.io.fixedBufferStream("/bg run sleep 1\n/bg list\n/quit\n");
    var out_buf: [32768]u8 = undefined;
    var out_fbs = std.io.fixedBufferStream(&out_buf);

    const sid = try execWithIo(
        std.testing.allocator,
        cfg,
        in_fbs.reader().any(),
        out_fbs.writer().any(),
    );
    defer std.testing.allocator.free(sid);

    const written = out_fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, written, "bg started id=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "id pid state code log cmd") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "bg L1 R1 D0") != null);
}

test "runtime rpc accepts type envelope aliases and echoes ids" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("sess");
    const sess_abs = try tmp.dir.realpathAlloc(std.testing.allocator, "sess");
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

    var in_fbs = std.io.fixedBufferStream(
        "{\"id\":\"1\",\"type\":\"get_state\"}\n" ++
            "{\"id\":\"2\",\"type\":\"set_model\",\"provider\":\"p2\",\"model_id\":\"m2\"}\n" ++
            "{\"id\":\"3\",\"type\":\"get_commands\"}\n" ++
            "{\"id\":\"4\",\"type\":\"new_session\"}\n" ++
            "{\"id\":\"5\",\"type\":\"quit\"}\n",
    );
    var out_buf: [32768]u8 = undefined;
    var out_fbs = std.io.fixedBufferStream(&out_buf);

    const sid = try execWithIo(
        std.testing.allocator,
        cfg,
        in_fbs.reader().any(),
        out_fbs.writer().any(),
    );
    defer std.testing.allocator.free(sid);

    const written = out_fbs.getWritten();
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

    try tmp.dir.makePath("sess");
    const sess_abs = try tmp.dir.realpathAlloc(std.testing.allocator, "sess");
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

    var in_fbs = std.io.fixedBufferStream(
        "{\"id\":\"1\",\"cmd\":\"bg\",\"arg\":\"run sleep 1\"}\n" ++
            "{\"id\":\"2\",\"cmd\":\"bg\",\"arg\":\"list\"}\n" ++
            "{\"id\":\"3\",\"cmd\":\"bg\",\"arg\":\"stop 1\"}\n" ++
            "{\"id\":\"4\",\"cmd\":\"quit\"}\n",
    );
    var out_buf: [32768]u8 = undefined;
    var out_fbs = std.io.fixedBufferStream(&out_buf);

    const sid = try execWithIo(
        std.testing.allocator,
        cfg,
        in_fbs.reader().any(),
        out_fbs.writer().any(),
    );
    defer std.testing.allocator.free(sid);

    const written = out_fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"type\":\"rpc_bg\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "bg started id=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "id pid state code log cmd") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, written, "bg stop sent id=1") != null or
            std.mem.indexOf(u8, written, "bg already done id=1") != null,
    );
}

test "runtime bg command validates usage and missing ids" {
    var mgr = try bg.Mgr.init(std.testing.allocator);
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

test "runtime bg command run show list workflow" {
    var mgr = try bg.Mgr.init(std.testing.allocator);
    defer mgr.deinit();

    const started = try runBgCommand(std.testing.allocator, &mgr, "run sleep 1");
    defer std.testing.allocator.free(started);
    try std.testing.expect(std.mem.indexOf(u8, started, "bg started id=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, started, "pid=") != null);
    try std.testing.expect(std.mem.indexOf(u8, started, "log=/tmp/pz-bg-") != null);

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

    try tmp.dir.makePath("sess");
    const sess_abs = try tmp.dir.realpathAlloc(std.testing.allocator, "sess");
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

    var in_fbs = std.io.fixedBufferStream("/tools read\none\n/tools all\ntwo\n/quit\n");
    var out_buf: [65536]u8 = undefined;
    var out_fbs = std.io.fixedBufferStream(&out_buf);

    const sid = try execWithIo(
        std.testing.allocator,
        cfg,
        in_fbs.reader().any(),
        out_fbs.writer().any(),
    );
    defer std.testing.allocator.free(sid);

    const written = out_fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, written, "tools set to read") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "no-bash") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "has-bash") != null);
}

test "runtime rpc tools command updates tool availability per turn" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("sess");
    const sess_abs = try tmp.dir.realpathAlloc(std.testing.allocator, "sess");
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

    var in_fbs = std.io.fixedBufferStream(
        "{\"cmd\":\"tools\",\"arg\":\"read\"}\n" ++
            "{\"cmd\":\"prompt\",\"text\":\"one\"}\n" ++
            "{\"cmd\":\"tools\",\"arg\":\"all\"}\n" ++
            "{\"cmd\":\"prompt\",\"text\":\"two\"}\n" ++
            "{\"cmd\":\"quit\"}\n",
    );
    var out_buf: [65536]u8 = undefined;
    var out_fbs = std.io.fixedBufferStream(&out_buf);

    const sid = try execWithIo(
        std.testing.allocator,
        cfg,
        in_fbs.reader().any(),
        out_fbs.writer().any(),
    );
    defer std.testing.allocator.free(sid);

    const written = out_fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"cmd\":\"tools\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "no-bash") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "has-bash") != null);
}
