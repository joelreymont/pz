const std = @import("std");
const cli = @import("cli.zig");
const core = @import("../core/mod.zig");
const print_fmt = @import("../modes/print/format.zig");
const print_err = @import("../modes/print/errors.zig");
const tui_harness = @import("../modes/tui/harness.zig");
const tui_render = @import("../modes/tui/render.zig");
const tui_term = @import("../modes/tui/term.zig");
const tui_input = @import("../modes/tui/input.zig");
const tui_editor = @import("../modes/tui/editor.zig");
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

const missing_provider_msg = "provider_cmd missing; set --provider-cmd or PIZI_PROVIDER_CMD";

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

    var sid: []u8 = undefined;
    var session_dir_path: ?[]u8 = null;
    defer if (session_dir_path) |path| alloc.free(path);
    errdefer alloc.free(sid);

    var store: core.session.SessionStore = undefined;
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
        const session_dir = try std.fs.cwd().openDir(plan.dir_path, .{ .iterate = true });
        fs_store_impl = try core.session.fs_store.Store.init(.{
            .alloc = alloc,
            .dir = session_dir,
            .flush = .{ .always = {} },
            .replay = .{},
        });
        store = fs_store_impl.asSessionStore();
    }
    defer store.deinit();

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
            store,
            tools_rt.registry(),
            writer,
            sys_prompt,
        ),
        .json => try runJson(
            alloc,
            run_cmd,
            sid,
            provider,
            store,
            tools_rt.registry(),
            reader,
            writer,
            sys_prompt,
        ),
        .tui => try runTui(
            alloc,
            run_cmd,
            &sid,
            provider,
            store,
            &tools_rt,
            reader,
            writer,
            session_dir_path,
            run_cmd.no_session,
            sys_prompt,
        ),
        .rpc => try runRpc(
            alloc,
            run_cmd,
            &sid,
            provider,
            store,
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
    reg: core.tools.Registry,
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
        .reg = reg,
        .mode = mode,
        .system_prompt = sys_prompt,
        .provider_opts = run_cmd.thinking.toProviderOpts(),
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
    reg: core.tools.Registry,
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

    if (run_cmd.prompt) |prompt| {
        try runTuiTurn(
            alloc,
            sid,
            prompt,
            run_cmd.cfg.model,
            run_cmd.cfg.provider,
            provider,
            store,
            reg,
            mode,
            popts,
            sys_prompt,
        );
        return;
    }

    var turn_ct: usize = 0;
    while (try in.readUntilDelimiterOrEofAlloc(alloc, '\n', 64 * 1024)) |raw_line| {
        defer alloc.free(raw_line);

        var line = raw_line;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;

        try runTuiTurn(
            alloc,
            sid,
            trimmed,
            run_cmd.cfg.model,
            run_cmd.cfg.provider,
            provider,
            store,
            reg,
            mode,
            popts,
            sys_prompt,
        );
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
    sys_prompt: ?[]const u8,
) !void {
    var model: []const u8 = run_cmd.cfg.model;
    var model_owned: ?[]u8 = null;
    defer if (model_owned) |m| alloc.free(m);
    var provider_label: []const u8 = run_cmd.cfg.provider;
    var provider_owned: ?[]u8 = null;
    defer if (provider_owned) |p| alloc.free(p);

    const cwd_path = getCwd(alloc) catch "";
    defer if (cwd_path.len > 0) alloc.free(cwd_path);
    const branch = getGitBranch(alloc) catch "";
    defer if (branch.len > 0) alloc.free(branch);

    const tsz = tui_term.size(std.posix.STDOUT_FILENO) orelse tui_term.Size{ .w = 80, .h = 24 };
    var ui = try tui_harness.Ui.initFull(alloc, tsz.w, tsz.h, model, provider_label, cwd_path, branch);
    defer ui.deinit();
    ui.pn.ctx_limit = modelCtxWindow(model);

    _ = tui_term.installSigwinch();
    try tui_render.Renderer.setup(out);

    defer tui_render.Renderer.cleanup(out) catch {};

    var sink_impl = TuiSink{
        .ui = &ui,
        .out = out,
    };
    const mode = core.loop.ModeSink.from(TuiSink, &sink_impl, TuiSink.push);
    var thinking = run_cmd.thinking;
    var popts = thinking.toProviderOpts();
    ui.pn.thinking_label = thinkingLabel(thinking);

    try ui.draw(out);
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
            session_dir_path,
            no_session,
            init_cmd_fbs.writer().any(),
        );
        if (cmd == .clear) {
            ui.clearTranscript();
        }
        if (cmd == .copy) {
            copyLastResponse(alloc, &ui);
        }
        if (cmd == .cost) {
            showCost(alloc, &ui);
        }
        if (cmd == .handled or cmd == .clear or cmd == .copy or cmd == .cost) {
            const cmd_text = init_cmd_fbs.getWritten();
            if (cmd_text.len > 0) {
                try ui.tr.infoText(cmd_text);
                ui.tr.scrollToBottom();
            }
            try ui.setModel(model);
            try ui.setProvider(provider_label);
        }
        if (cmd == .unhandled) {
            try runTuiTurn(
                alloc,
                sid.*,
                prompt,
                model,
                provider_label,
                provider,
                store,
                tools_rt.registry(),
                mode,
                popts,
                sys_prompt,
            );
        } else {
            try ui.setModel(model);
            try ui.setProvider(provider_label);
            try ui.draw(out);
        }
        return;
    }

    const stdin_fd = std.posix.STDIN_FILENO;
    const is_tty = std.posix.isatty(stdin_fd);

    if (is_tty) {
        if (!tui_term.enableRaw(stdin_fd)) return error.TerminalSetupFailed;
        defer tui_term.restore(stdin_fd);

        var reader = tui_input.Reader.init(stdin_fd);

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
                    // Capture editor text before onKey clears it on submit
                    const snap = ui.editorText();
                    var pre: ?[]u8 = if (snap.len > 0) alloc.dupe(u8, snap) catch null else null;

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
                                session_dir_path,
                                no_session,
                                cmd_fbs.writer().any(),
                            );
                            if (cmd == .quit) return;
                            if (cmd == .clear) {
                                ui.clearTranscript();
                                try ui.draw(out);
                                continue;
                            }
                            if (cmd == .copy) {
                                copyLastResponse(alloc, &ui);
                                try ui.draw(out);
                                continue;
                            }
                            if (cmd == .cost) {
                                showCost(alloc, &ui);
                                try ui.draw(out);
                                continue;
                            }
                            if (cmd == .handled) {
                                const cmd_text = cmd_fbs.getWritten();
                                if (cmd_text.len > 0) {
                                    try ui.tr.infoText(cmd_text);
                                    ui.tr.scrollToBottom();
                                }
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

                            try runTuiTurn(
                                alloc,
                                sid.*,
                                prompt,
                                model,
                                provider_label,
                                provider,
                                store,
                                tools_rt.registry(),
                                mode,
                                popts,
                                sys_prompt,
                            );
                            try autoCompact(alloc, &ui, sid.*, session_dir_path, no_session);
                            try ui.draw(out);
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
                            try ui.draw(out);
                        },
                        .cycle_model => {
                            if (pre) |p| alloc.free(p);
                            model = try cycleModel(alloc, model, &model_owned);
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
                        .none => {
                            if (pre) |p| alloc.free(p);
                            try ui.draw(out);
                        },
                    }
                },
                .mouse => |mev| {
                    ui.onMouse(mev);
                    try ui.draw(out);
                },
                .resize => {
                    if (tui_term.size(std.posix.STDOUT_FILENO)) |sz| {
                        try ui.resize(sz.w, sz.h);
                        try ui.draw(out);
                    }
                },
                .none => {},
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
                session_dir_path,
                no_session,
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
                copyLastResponse(alloc, &ui);
                try ui.draw(out);
                cmd_ct += 1;
                continue;
            }
            if (cmd == .cost) {
                showCost(alloc, &ui);
                try ui.draw(out);
                cmd_ct += 1;
                continue;
            }
            if (cmd == .handled) {
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

            try runTuiTurn(
                alloc,
                sid.*,
                trimmed,
                model,
                provider_label,
                provider,
                store,
                tools_rt.registry(),
                mode,
                popts,
                sys_prompt,
            );
            try autoCompact(alloc, &ui, sid.*, session_dir_path, no_session);
            turn_ct += 1;
        }
        if (turn_ct == 0 and cmd_ct == 0) return error.EmptyPrompt;
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
    var model: []const u8 = run_cmd.cfg.model;
    var model_owned: ?[]u8 = null;
    defer if (model_owned) |m| alloc.free(m);
    var provider_label: []const u8 = run_cmd.cfg.provider;
    var provider_owned: ?[]u8 = null;
    defer if (provider_owned) |p| alloc.free(p);

    var sink_impl = JsonSink{
        .alloc = alloc,
        .out = out,
    };
    const mode = core.loop.ModeSink.from(JsonSink, &sink_impl, JsonSink.push);
    const popts = run_cmd.thinking.toProviderOpts();

    while (try in.readUntilDelimiterOrEofAlloc(alloc, '\n', 128 * 1024)) |raw_line| {
        defer alloc.free(raw_line);

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

        const RpcCmd = enum { prompt, model, provider, tools, new, @"resume", session, tree, fork, compact, help, commands, quit, exit };
        const rpc_map = std.StaticStringMap(RpcCmd).initComptime(.{
            .{ "prompt", .prompt },
            .{ "model", .model },
            .{ "provider", .provider },
            .{ "tools", .tools },
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
                try runTuiTurn(
                    alloc,
                    sid.*,
                    prompt,
                    model,
                    provider_label,
                    provider,
                    store,
                    tools_rt.registry(),
                    mode,
                    popts,
                    sys_prompt,
                );
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
                if (no_session or session_dir_path == null) {
                    try writeJsonLine(alloc, out, .{
                        .type = "rpc_error",
                        .id = req.id,
                        .cmd = raw_cmd,
                        .msg = "session_disabled",
                    });
                    continue;
                }
                const token = req.session_path orelse req.session orelse req.sid orelse req.arg;
                const next_sid = resolveResumeSid(alloc, session_dir_path.?, token) catch |err| {
                    try writeJsonLine(alloc, out, .{
                        .type = "rpc_error",
                        .id = req.id,
                        .cmd = raw_cmd,
                        .msg = @errorName(err),
                    });
                    continue;
                };
                alloc.free(sid.*);
                sid.* = next_sid;
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
                if (no_session or session_dir_path == null) {
                    try writeJsonLine(alloc, out, .{
                        .type = "rpc_error",
                        .id = req.id,
                        .cmd = raw_cmd,
                        .msg = "session_disabled",
                    });
                    continue;
                }
                const tree = try listSessionsAlloc(alloc, session_dir_path.?);
                defer alloc.free(tree);
                try writeJsonLine(alloc, out, .{
                    .type = "rpc_tree",
                    .id = req.id,
                    .sessions = tree,
                });
            },
            .fork => {
                if (no_session or session_dir_path == null) {
                    try writeJsonLine(alloc, out, .{
                        .type = "rpc_error",
                        .id = req.id,
                        .cmd = raw_cmd,
                        .msg = "session_disabled",
                    });
                    continue;
                }
                const next_sid = if (req.sid orelse req.arg) |raw| blk: {
                    try core.session.path.validateSid(raw);
                    break :blk try alloc.dupe(u8, raw);
                } else try newSid(alloc);
                errdefer alloc.free(next_sid);
                try forkSessionFile(session_dir_path.?, sid.*, next_sid);
                alloc.free(sid.*);
                sid.* = next_sid;
                try writeJsonLine(alloc, out, .{
                    .type = "rpc_ack",
                    .id = req.id,
                    .cmd = raw_cmd,
                    .sid = sid.*,
                });
            },
            .compact => {
                if (no_session or session_dir_path == null) {
                    try writeJsonLine(alloc, out, .{
                        .type = "rpc_error",
                        .id = req.id,
                        .cmd = raw_cmd,
                        .msg = "session_disabled",
                    });
                    continue;
                }
                var dir = try std.fs.cwd().openDir(session_dir_path.?, .{});
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
                    .commands = "prompt,model,provider,tools,new,resume,session,tree,fork,compact,quit",
                });
            },
            .commands => {
                const commands = [_][]const u8{
                    "prompt", "model", "provider", "tools", "new", "resume", "session", "tree", "fork", "compact", "help", "quit",
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
    session_dir_path: ?[]const u8,
    no_session: bool,
    out: std.Io.AnyWriter,
) !CmdRes {
    if (line.len == 0 or line[0] != '/') return .unhandled;

    const body = std.mem.trim(u8, line[1..], " \t");
    if (body.len == 0) return .handled;

    const sp = std.mem.indexOfAny(u8, body, " \t");
    const cmd = if (sp) |i| body[0..i] else body;
    const arg = if (sp) |i| std.mem.trim(u8, body[i + 1 ..], " \t") else "";

    const Cmd = enum { help, quit, exit, session, model, provider, tools, new, @"resume", tree, fork, compact, settings, hotkeys, login, logout, clear, cost, copy, name };
    const cmd_map = std.StaticStringMap(Cmd).initComptime(.{
        .{ "help", .help },
        .{ "quit", .quit },
        .{ "exit", .exit },
        .{ "session", .session },
        .{ "model", .model },
        .{ "provider", .provider },
        .{ "tools", .tools },
        .{ "new", .new },
        .{ "resume", .@"resume" },
        .{ "tree", .tree },
        .{ "fork", .fork },
        .{ "compact", .compact },
        .{ "settings", .settings },
        .{ "hotkeys", .hotkeys },
        .{ "login", .login },
        .{ "logout", .logout },
        .{ "clear", .clear },
        .{ "cost", .cost },
        .{ "copy", .copy },
        .{ "name", .name },
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
                \\  /model <id>        Set model
                \\  /provider <id>     Set/show provider
                \\  /tools [list|all]  Set/show tools
                \\  /clear             Clear transcript
                \\  /copy              Copy last response
                \\  /name <name>       Name session
                \\  /new               New session
                \\  /resume [id]       Resume session
                \\  /tree              List sessions
                \\  /fork [id]         Fork session
                \\  /compact           Compact session
                \\  /login             Login (OAuth)
                \\  /logout            Logout
                \\  /hotkeys           Keyboard shortcuts
                \\  /quit              Exit
                \\
            );
        },
        .quit, .exit => return .quit,
        .session => {
            const stats = try sessionStats(alloc, session_dir_path, sid.*, no_session);
            defer if (stats.path_owned) |path| alloc.free(path);
            try writeTextLine(
                alloc,
                out,
                "session sid={s} model={s} provider={s} file={s} bytes={d} lines={d}\n",
                .{ sid.*, model.*, provider.*, stats.path, stats.bytes, stats.lines },
            );
        },
        .model => {
            if (arg.len == 0) {
                try out.writeAll("error: missing model value\n");
                return .handled;
            }
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
        .new => {
            const next_sid = try newSid(alloc);
            alloc.free(sid.*);
            sid.* = next_sid;
            try writeTextLine(alloc, out, "new session {s}\n", .{sid.*});
        },
        .@"resume" => {
            if (no_session or session_dir_path == null) {
                try out.writeAll("error: session disabled\n");
                return .handled;
            }
            const tok = if (arg.len == 0) null else arg;
            const next_sid = resolveResumeSid(alloc, session_dir_path.?, tok) catch |err| {
                try writeTextLine(alloc, out, "error: resume failed ({s})\n", .{@errorName(err)});
                return .handled;
            };
            alloc.free(sid.*);
            sid.* = next_sid;
            try writeTextLine(alloc, out, "resumed session {s}\n", .{sid.*});
        },
        .tree => {
            if (no_session or session_dir_path == null) {
                try out.writeAll("error: session disabled\n");
                return .handled;
            }
            const tree = try listSessionsAlloc(alloc, session_dir_path.?);
            defer alloc.free(tree);
            try out.writeAll(tree);
            if (tree.len == 0 or tree[tree.len - 1] != '\n') try out.writeAll("\n");
        },
        .fork => {
            if (no_session or session_dir_path == null) {
                try out.writeAll("error: session disabled\n");
                return .handled;
            }
            const next_sid = if (arg.len != 0) blk: {
                try core.session.path.validateSid(arg);
                break :blk try alloc.dupe(u8, arg);
            } else try newSid(alloc);
            errdefer alloc.free(next_sid);
            try forkSessionFile(session_dir_path.?, sid.*, next_sid);
            alloc.free(sid.*);
            sid.* = next_sid;
            try writeTextLine(alloc, out, "forked session {s}\n", .{sid.*});
        },
        .compact => {
            if (no_session or session_dir_path == null) {
                try out.writeAll("error: session disabled\n");
                return .handled;
            }
            var dir = try std.fs.cwd().openDir(session_dir_path.?, .{});
            defer dir.close();
            const ck = try core.session.compactSession(alloc, dir, sid.*, std.time.milliTimestamp());
            try writeTextLine(alloc, out, "compacted in={d} out={d}\n", .{ ck.in_lines, ck.out_lines });
        },
        .settings => {
            const tool_csv = try toolMaskCsvAlloc(alloc, tools_rt.tool_mask);
            defer alloc.free(tool_csv);
            try writeTextLine(
                alloc,
                out,
                "settings model={s} provider={s} tools={s} sid={s} session_dir={s} no_session={any}\n",
                .{ model.*, provider.*, tool_csv, sid.*, session_dir_path orelse "", no_session },
            );
        },
        .hotkeys => {
            try out.writeAll(
                \\Keyboard shortcuts:
                \\  Enter          Submit message
                \\  ESC            Clear input / Cancel
                \\  Ctrl+C         Clear input / Quit
                \\  Ctrl+D         Quit (when input empty)
                \\  Shift+Tab      Cycle thinking level
                \\  Ctrl+P         Cycle model
                \\  Ctrl+O         Toggle tool output
                \\  Ctrl+T         Toggle thinking blocks
                \\  Scroll Up/Down Scroll transcript
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
        .login => try out.writeAll("Login via: ~/.pi/agent/auth.json (OAuth or API key)\n"),
        .logout => try out.writeAll("Remove auth: rm ~/.pi/agent/auth.json\n"),
    }
    return .handled;
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
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = try f.read(&buf);
        if (n == 0) break;
        lines += std.mem.count(u8, buf[0..n], "\n");
    }

    return .{
        .path = abs,
        .path_owned = abs,
        .bytes = st.size,
        .lines = lines,
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

    const src_path = try core.session.path.sidJsonlAlloc(std.heap.page_allocator, src_sid);
    defer std.heap.page_allocator.free(src_path);
    const dst_path = try core.session.path.sidJsonlAlloc(std.heap.page_allocator, dst_sid);
    defer std.heap.page_allocator.free(dst_path);

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
    // Return basename only
    if (std.mem.lastIndexOfScalar(u8, full, '/')) |i| {
        const base = try alloc.dupe(u8, full[i + 1 ..]);
        alloc.free(full);
        return base;
    }
    return full;
}

fn getGitBranch(alloc: std.mem.Allocator) ![]u8 {
    const head = std.fs.cwd().readFileAlloc(alloc, ".git/HEAD", 256) catch return error.NotFound;
    defer alloc.free(head);
    const prefix = "ref: refs/heads/";
    if (std.mem.startsWith(u8, head, prefix)) {
        const rest = std.mem.trimRight(u8, head[prefix.len..], "\n\r ");
        return try alloc.dupe(u8, rest);
    }
    // Detached HEAD — return short hash
    const trimmed = std.mem.trimRight(u8, head, "\n\r ");
    if (trimmed.len >= 8) return try alloc.dupe(u8, trimmed[0..8]);
    return error.NotFound;
}

fn modelCtxWindow(model: []const u8) u64 {
    const table = .{
        .{ "opus-4-6", 200000 },
        .{ "opus-4.6", 200000 },
        .{ "sonnet-4-6", 200000 },
        .{ "sonnet-4.6", 200000 },
        .{ "haiku-4-5", 200000 },
        .{ "haiku-4.5", 200000 },
        .{ "opus-4-", 200000 },
        .{ "sonnet-4-", 200000 },
        .{ "claude-3-5", 200000 },
        .{ "claude-3.5", 200000 },
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
    "claude-opus-4-6-20250219",
    "claude-sonnet-4-6-20250514",
    "claude-haiku-4-5-20251001",
};

fn cycleModel(alloc: std.mem.Allocator, cur: []const u8, model_owned: *?[]u8) ![]const u8 {
    var next_idx: usize = 0;
    for (model_cycle, 0..) |m, i| {
        if (std.mem.eql(u8, cur, m)) {
            next_idx = (i + 1) % model_cycle.len;
            break;
        }
    } else {
        // Current model not in list, pick first entry
        next_idx = 0;
    }
    const new = try alloc.dupe(u8, model_cycle[next_idx]);
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
    return switch (level) {
        .adaptive => "",
        .off => "think:off",
        .minimal => "think:min",
        .low => "think:low",
        .medium => "think:med",
        .high => "think:high",
        .xhigh => "think:xhigh",
    };
}

fn showCost(alloc: std.mem.Allocator, ui: *tui_harness.Ui) void {
    const u = ui.pn.usage;
    const msg = std.fmt.allocPrint(alloc, "tokens in={d} out={d} total={d}", .{
        u.in_tok, u.out_tok, u.tot_tok,
    }) catch return;
    defer alloc.free(msg);
    ui.tr.infoText(msg) catch {};
}

fn copyLastResponse(alloc: std.mem.Allocator, ui: *tui_harness.Ui) void {
    const text = ui.lastResponseText() orelse {
        ui.tr.infoText("[nothing to copy]") catch {};
        return;
    };
    const argv = [_][]const u8{"pbcopy"};
    var child = std.process.Child.init(argv[0..], alloc);
    child.stdin_behavior = .Pipe;
    child.spawn() catch {
        ui.tr.infoText("[copy failed: pbcopy not found]") catch {};
        return;
    };
    if (child.stdin) |*stdin| {
        stdin.writeAll(text) catch {};
        stdin.close();
        child.stdin = null;
    }
    _ = child.wait() catch {};
    ui.tr.infoText("[copied to clipboard]") catch {};
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
    const pct = ui.pn.usage.tot_tok * 100 / ui.pn.ctx_limit;
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

fn runTuiTurn(
    alloc: std.mem.Allocator,
    sid: []const u8,
    prompt: []const u8,
    model: []const u8,
    provider_label: []const u8,
    provider: core.providers.Provider,
    store: core.session.SessionStore,
    reg: core.tools.Registry,
    mode: core.loop.ModeSink,
    provider_opts: core.providers.Opts,
    system_prompt: ?[]const u8,
) !void {
    _ = try core.loop.run(.{
        .alloc = alloc,
        .sid = sid,
        .prompt = prompt,
        .model = model,
        .provider_label = provider_label,
        .provider = provider,
        .store = store,
        .reg = reg,
        .mode = mode,
        .system_prompt = system_prompt,
        .provider_opts = provider_opts,
    });
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

    const sid = try execWithIo(std.testing.allocator, cfg, null, out_fbs.writer().any());
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

    const sid = try execWithIo(std.testing.allocator, cfg, null, out_fbs.writer().any());
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

    const sid = try execWithIo(std.testing.allocator, cfg, null, out_fbs.writer().any());
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

    const sid = try execWithIo(std.testing.allocator, cfg, null, out_fbs.writer().any());
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

    const sid = try execWithIo(std.testing.allocator, cfg, null, out_fbs.writer().any());
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
    var out_buf: [2048]u8 = undefined;
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

    const sid = try execWithIo(std.testing.allocator, cfg, null, out_fbs.writer().any());
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
    const sid = try execWithIo(std.testing.allocator, cfg, null, out_fbs.writer().any());
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

    const sid = try execWithIo(std.testing.allocator, cfg, null, out_fbs.writer().any());
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

    const sid = try execWithIo(std.testing.allocator, cfg, null, out_fbs.writer().any());
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
    try std.testing.expect(std.mem.indexOf(u8, written, "file=") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "bytes=") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "lines=") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "settings model=") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "tools=read") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "new session") != null);
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
