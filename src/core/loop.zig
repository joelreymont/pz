const std = @import("std");
const providers = @import("providers/mod.zig");
const session = @import("session/mod.zig");
const tools = @import("tools/mod.zig");

pub const Err = error{
    EmptySessionId,
    EmptyPrompt,
    EmptyModel,
    InvalidMaxTurns,
    InvalidCompactEvery,
    ToolLoopLimit,
    InvalidToolArgs,
    OutOfMemory,
};

pub const ModeEv = union(enum) {
    replay: session.Event,
    session: session.Event,
    provider: providers.Ev,
    tool: tools.Event,
};

pub const ModeSink = struct {
    ctx: *anyopaque,
    vt: *const Vt,

    pub const Vt = struct {
        push: *const fn (ctx: *anyopaque, ev: ModeEv) anyerror!void,
    };

    pub fn from(
        comptime T: type,
        ctx: *T,
        comptime push_fn: fn (ctx: *T, ev: ModeEv) anyerror!void,
    ) ModeSink {
        const Wrap = struct {
            fn push(raw: *anyopaque, ev: ModeEv) anyerror!void {
                const typed: *T = @ptrCast(@alignCast(raw));
                return push_fn(typed, ev);
            }

            const vt = Vt{
                .push = @This().push,
            };
        };

        return .{
            .ctx = ctx,
            .vt = &Wrap.vt,
        };
    }

    pub fn push(self: ModeSink, ev: ModeEv) !void {
        return self.vt.push(self.ctx, ev);
    }
};

pub const TimeSrc = struct {
    ctx: *anyopaque,
    now_ms_fn: *const fn (ctx: *anyopaque) i64,

    pub fn from(
        comptime T: type,
        ctx: *T,
        comptime now_ms_fn: fn (ctx: *T) i64,
    ) TimeSrc {
        const Wrap = struct {
            fn nowMs(raw: *anyopaque) i64 {
                const typed: *T = @ptrCast(@alignCast(raw));
                return now_ms_fn(typed);
            }
        };

        return .{
            .ctx = ctx,
            .now_ms_fn = Wrap.nowMs,
        };
    }

    pub fn nowMs(self: TimeSrc) i64 {
        return self.now_ms_fn(self.ctx);
    }
};

pub const CancelSrc = struct {
    ctx: *anyopaque,
    is_canceled_fn: *const fn (ctx: *anyopaque) bool,

    pub fn from(
        comptime T: type,
        ctx: *T,
        comptime is_canceled_fn: fn (ctx: *T) bool,
    ) CancelSrc {
        const Wrap = struct {
            fn isCanceled(raw: *anyopaque) bool {
                const typed: *T = @ptrCast(@alignCast(raw));
                return is_canceled_fn(typed);
            }
        };

        return .{
            .ctx = ctx,
            .is_canceled_fn = Wrap.isCanceled,
        };
    }

    pub fn isCanceled(self: CancelSrc) bool {
        return self.is_canceled_fn(self.ctx);
    }
};

pub const Compactor = struct {
    ctx: *anyopaque,
    run_fn: *const fn (ctx: *anyopaque, sid: []const u8, at_ms: i64) anyerror!void,

    pub fn from(
        comptime T: type,
        ctx: *T,
        comptime run_fn: fn (ctx: *T, sid: []const u8, at_ms: i64) anyerror!void,
    ) Compactor {
        const Wrap = struct {
            fn run(raw: *anyopaque, sid: []const u8, at_ms: i64) anyerror!void {
                const typed: *T = @ptrCast(@alignCast(raw));
                return run_fn(typed, sid, at_ms);
            }
        };

        return .{
            .ctx = ctx,
            .run_fn = Wrap.run,
        };
    }

    pub fn run(self: Compactor, sid: []const u8, at_ms: i64) !void {
        return self.run_fn(self.ctx, sid, at_ms);
    }
};

const Stage = enum {
    replay_open,
    replay_next,
    mode_push,
    store_append,
    provider_start,
    stream_next,
    tool_run,
    compact,
};

pub const Opts = struct {
    alloc: std.mem.Allocator,
    sid: []const u8,
    prompt: []const u8,
    model: []const u8,
    provider_label: ?[]const u8 = null,
    provider: providers.Provider,
    store: session.SessionStore,
    reg: tools.Registry,
    mode: ModeSink,
    system_prompt: ?[]const u8 = null,
    provider_opts: providers.Opts = .{},
    max_turns: u16 = 0, // 0 = unlimited
    time: ?TimeSrc = null,
    cancel: ?CancelSrc = null,
    compactor: ?Compactor = null,
    compact_every: u32 = 0,
};

pub const RunOut = struct {
    turns: u16,
    tool_calls: u32,
};

const HistItem = struct {
    role: providers.Role,
    part: providers.Part,
};

const Hist = struct {
    alloc: std.mem.Allocator,
    items: std.ArrayListUnmanaged(HistItem) = .{},

    fn deinit(self: *Hist) void {
        for (self.items.items) |it| {
            freePart(self.alloc, it.part);
        }
        self.items.deinit(self.alloc);
    }

    fn pushTextDup(self: *Hist, role: providers.Role, text: []const u8) !void {
        const owned = try self.alloc.dupe(u8, text);
        errdefer self.alloc.free(owned);

        try self.items.append(self.alloc, .{
            .role = role,
            .part = .{ .text = owned },
        });
    }

    fn pushToolCallDup(
        self: *Hist,
        role: providers.Role,
        tc: providers.ToolCall,
    ) !void {
        const id = try self.alloc.dupe(u8, tc.id);
        errdefer self.alloc.free(id);
        const name = try self.alloc.dupe(u8, tc.name);
        errdefer self.alloc.free(name);
        const args = try self.alloc.dupe(u8, tc.args);
        errdefer self.alloc.free(args);

        try self.items.append(self.alloc, .{
            .role = role,
            .part = .{ .tool_call = .{
                .id = id,
                .name = name,
                .args = args,
            } },
        });
    }

    fn pushToolResultDup(
        self: *Hist,
        role: providers.Role,
        tr: providers.ToolResult,
    ) !void {
        const id = try self.alloc.dupe(u8, tr.id);
        errdefer self.alloc.free(id);
        const out = try self.alloc.dupe(u8, tr.out);
        errdefer self.alloc.free(out);

        try self.items.append(self.alloc, .{
            .role = role,
            .part = .{ .tool_result = .{
                .id = id,
                .out = out,
                .is_err = tr.is_err,
            } },
        });
    }

    fn pushToolResultOwned(self: *Hist, tr: providers.ToolResult) !void {
        try self.items.append(self.alloc, .{
            .role = .tool,
            .part = .{ .tool_result = tr },
        });
    }

    fn appendFromSession(self: *Hist, ev: session.Event) !void {
        switch (ev.data) {
            .prompt => |prompt| try self.pushTextDup(.user, prompt.text),
            .text => |text| try self.pushTextDup(.assistant, text.text),
            .tool_call => |tc| try self.pushToolCallDup(.assistant, .{
                .id = tc.id,
                .name = tc.name,
                .args = tc.args,
            }),
            .tool_result => |tr| try self.pushToolResultDup(.tool, .{
                .id = tr.id,
                .out = tr.out,
                .is_err = tr.is_err,
            }),
            else => {},
        }
    }

    fn appendFromProvider(self: *Hist, ev: providers.Ev) !void {
        switch (ev) {
            .text => |text| try self.pushTextDup(.assistant, text),
            .tool_call => |tc| try self.pushToolCallDup(.assistant, tc),
            .tool_result => |tr| try self.pushToolResultDup(.tool, tr),
            else => {},
        }
    }
};

pub fn run(opts: Opts) (Err || anyerror)!RunOut {
    if (opts.sid.len == 0) return error.EmptySessionId;
    if (opts.prompt.len == 0) return error.EmptyPrompt;
    if (opts.model.len == 0) return error.EmptyModel;
    if (opts.compactor != null and opts.compact_every == 0) return error.InvalidCompactEvery;

    var hist = Hist{
        .alloc = opts.alloc,
    };
    defer hist.deinit();
    var append_ct: u64 = 0;

    {
        var replay = opts.store.replay(opts.sid) catch |replay_err| switch (replay_err) {
            error.FileNotFound, error.NotFound => null,
            else => return failWithReport(opts, .replay_open, replay_err),
        };
        if (replay) |*rdr| {
            defer rdr.deinit();
            while (rdr.next() catch |next_err| return failWithReport(opts, .replay_next, next_err)) |ev| {
                opts.mode.push(.{ .replay = ev }) catch |mode_err| {
                    return failWithReport(opts, .mode_push, mode_err);
                };
                hist.appendFromSession(ev) catch |hist_err| {
                    return failWithReport(opts, .replay_next, hist_err);
                };
            }
        }
    }

    const prompt_ev = session.Event{
        .at_ms = nowMs(opts),
        .data = .{ .prompt = .{ .text = opts.prompt } },
    };
    opts.store.append(opts.sid, prompt_ev) catch |append_err| {
        return failWithReport(opts, .store_append, append_err);
    };
    onSessionAppend(opts, &append_ct) catch |compact_err| {
        return failWithReport(opts, .compact, compact_err);
    };
    opts.mode.push(.{ .session = prompt_ev }) catch |mode_err| {
        return failWithReport(opts, .mode_push, mode_err);
    };
    hist.pushTextDup(.user, opts.prompt) catch |hist_err| {
        return failWithReport(opts, .store_append, hist_err);
    };

    // Cache tool schemas — registry is static across turns
    const req_tools = buildReqTools(opts.alloc, opts.reg) catch |tools_err| {
        return failWithReport(opts, .provider_start, tools_err);
    };
    defer {
        for (req_tools) |t| opts.alloc.free(t.schema);
        opts.alloc.free(req_tools);
    }

    var turns: u16 = 0;
    var tool_calls: u32 = 0;

    while (opts.max_turns == 0 or turns < opts.max_turns) : (turns +|= 1) {
        if (isCanceled(opts)) {
            emitCanceled(opts, &append_ct) catch |cancel_err| {
                return failWithReport(opts, .mode_push, cancel_err);
            };
            return .{
                .turns = turns,
                .tool_calls = tool_calls,
            };
        }

        var turn_arena = std.heap.ArenaAllocator.init(opts.alloc);
        defer turn_arena.deinit();
        const turn_alloc = turn_arena.allocator();

        const req_msgs = buildReqMsgs(turn_alloc, hist.items.items, opts.system_prompt) catch |msg_err| {
            return failWithReport(opts, .provider_start, msg_err);
        };

        var stream = opts.provider.start(.{
            .model = opts.model,
            .provider = opts.provider_label,
            .msgs = req_msgs,
            .tools = req_tools,
            .opts = opts.provider_opts,
        }) catch |start_err| {
            return failWithReport(opts, .provider_start, start_err);
        };
        defer stream.deinit();

        var saw_tool_call = false;
        while (stream.next() catch |next_err| return failWithReport(opts, .stream_next, next_err)) |ev| {
            if (isCanceled(opts)) {
                emitCanceled(opts, &append_ct) catch |cancel_err| {
                    return failWithReport(opts, .mode_push, cancel_err);
                };
                return .{
                    .turns = turns,
                    .tool_calls = tool_calls,
                };
            }

            opts.mode.push(.{ .provider = ev }) catch |mode_err| {
                return failWithReport(opts, .mode_push, mode_err);
            };

            const sess_ev = mapProviderEv(ev, nowMs(opts));
            opts.store.append(opts.sid, sess_ev) catch |append_err| {
                return failWithReport(opts, .store_append, append_err);
            };
            onSessionAppend(opts, &append_ct) catch |compact_err| {
                return failWithReport(opts, .compact, compact_err);
            };
            opts.mode.push(.{ .session = sess_ev }) catch |mode_err| {
                return failWithReport(opts, .mode_push, mode_err);
            };
            hist.appendFromProvider(ev) catch |hist_err| {
                return failWithReport(opts, .stream_next, hist_err);
            };

            switch (ev) {
                .tool_call => |tc| {
                    saw_tool_call = true;
                    tool_calls += 1;

                    const tr = runTool(opts, tc) catch |tool_err| {
                        return failWithReport(opts, .tool_run, tool_err);
                    };
                    hist.pushToolResultOwned(tr) catch |hist_err| {
                        return failWithReport(opts, .tool_run, hist_err);
                    };

                    const tr_ev: providers.Ev = .{
                        .tool_result = tr,
                    };
                    opts.mode.push(.{ .provider = tr_ev }) catch |mode_err| {
                        return failWithReport(opts, .mode_push, mode_err);
                    };

                    const tr_sess_ev = mapProviderEv(tr_ev, nowMs(opts));
                    opts.store.append(opts.sid, tr_sess_ev) catch |append_err| {
                        return failWithReport(opts, .store_append, append_err);
                    };
                    onSessionAppend(opts, &append_ct) catch |compact_err| {
                        return failWithReport(opts, .compact, compact_err);
                    };
                    opts.mode.push(.{ .session = tr_sess_ev }) catch |mode_err| {
                        return failWithReport(opts, .mode_push, mode_err);
                    };
                },
                else => {},
            }
        }

        if (!saw_tool_call) {
            return .{
                .turns = turns + 1,
                .tool_calls = tool_calls,
            };
        }
    }

    // max_turns > 0 and exhausted
    return .{
        .turns = turns,
        .tool_calls = tool_calls,
    };
}

fn isCanceled(opts: Opts) bool {
    if (opts.cancel) |cancel| return cancel.isCanceled();
    return false;
}

fn emitCanceled(opts: Opts, append_ct: *u64) !void {
    const pev: providers.Ev = .{
        .stop = .{
            .reason = .canceled,
        },
    };
    try opts.mode.push(.{ .provider = pev });

    const sev = mapProviderEv(pev, nowMs(opts));
    try opts.store.append(opts.sid, sev);
    try onSessionAppend(opts, append_ct);
    try opts.mode.push(.{ .session = sev });
}

fn onSessionAppend(opts: Opts, append_ct: *u64) !void {
    append_ct.* += 1;
    if (opts.compactor) |compactor| {
        if (opts.compact_every == 0) return error.InvalidCompactEvery;
        if (append_ct.* % opts.compact_every == 0) {
            try compactor.run(opts.sid, nowMs(opts));
        }
    }
}

fn failWithReport(opts: Opts, stage: Stage, cause: anyerror) anyerror {
    if (reportRuntimeErr(opts, stage, cause)) |_| {} else |report_err| return report_err;
    return cause;
}

fn reportRuntimeErr(opts: Opts, stage: Stage, cause: anyerror) !void {
    const msg = try std.fmt.allocPrint(opts.alloc, "runtime:{s}:{s}", .{
        @tagName(stage),
        @errorName(cause),
    });
    defer opts.alloc.free(msg);

    const ev = session.Event{
        .at_ms = nowMs(opts),
        .data = .{ .err = .{ .text = msg } },
    };
    try opts.store.append(opts.sid, ev);
    try opts.mode.push(.{ .session = ev });
}

fn nowMs(opts: Opts) i64 {
    if (opts.time) |time| return time.nowMs();
    return std.time.milliTimestamp();
}

fn freePart(alloc: std.mem.Allocator, part: providers.Part) void {
    switch (part) {
        .text => |text| alloc.free(text),
        .tool_call => |tc| {
            alloc.free(tc.id);
            alloc.free(tc.name);
            alloc.free(tc.args);
        },
        .tool_result => |tr| {
            alloc.free(tr.id);
            alloc.free(tr.out);
        },
    }
}

fn buildReqMsgs(
    alloc: std.mem.Allocator,
    hist: []const HistItem,
    system_prompt: ?[]const u8,
) ![]providers.Msg {
    const sys: usize = if (system_prompt != null) 1 else 0;
    const msgs = try alloc.alloc(providers.Msg, hist.len + sys);
    const parts = try alloc.alloc(providers.Part, hist.len + sys);

    if (system_prompt) |sp| {
        parts[0] = .{ .text = sp };
        msgs[0] = .{ .role = .system, .parts = parts[0..1] };
    }

    for (hist, 0..) |item, idx| {
        parts[sys + idx] = item.part;
        msgs[sys + idx] = .{
            .role = item.role,
            .parts = parts[sys + idx .. sys + idx + 1],
        };
    }

    return msgs;
}

fn buildReqTools(
    alloc: std.mem.Allocator,
    reg: tools.Registry,
) ![]providers.Tool {
    const out = try alloc.alloc(providers.Tool, reg.entries.len);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |t| alloc.free(t.schema);
        alloc.free(out);
    }
    for (reg.entries, out) |entry, *slot| {
        const schema = if (entry.spec.schema_json) |raw_schema|
            try alloc.dupe(u8, raw_schema)
        else
            try buildSchema(alloc, entry.spec.params);
        slot.* = .{
            .name = entry.name,
            .desc = entry.spec.desc,
            .schema = schema,
        };
        built += 1;
    }
    return out;
}

fn buildSchema(alloc: std.mem.Allocator, params: []const tools.Spec.Param) ![]const u8 {
    var buf: std.io.Writer.Allocating = .init(alloc);
    errdefer buf.deinit();

    var js: std.json.Stringify = .{
        .writer = &buf.writer,
        .options = .{},
    };

    try js.beginObject();
    try js.objectField("type");
    try js.write("object");

    try js.objectField("properties");
    try js.beginObject();
    for (params) |p| {
        try js.objectField(p.name);
        try js.beginObject();
        try js.objectField("type");
        try js.write(switch (p.ty) {
            .string => "string",
            .int => "integer",
            .bool => "boolean",
        });
        try js.objectField("description");
        try js.write(p.desc);
        try js.endObject();
    }
    try js.endObject();

    // Required array
    var has_req = false;
    for (params) |p| {
        if (p.required) {
            has_req = true;
            break;
        }
    }
    if (has_req) {
        try js.objectField("required");
        try js.beginArray();
        for (params) |p| {
            if (p.required) try js.write(p.name);
        }
        try js.endArray();
    }

    try js.endObject();

    return buf.toOwnedSlice() catch return error.OutOfMemory;
}

fn runTool(opts: Opts, tc: providers.ToolCall) (Err || anyerror)!providers.ToolResult {
    const entry = opts.reg.byName(tc.name) orelse {
        return .{
            .id = try opts.alloc.dupe(u8, tc.id),
            .out = try std.fmt.allocPrint(opts.alloc, "tool-not-found:{s}", .{tc.name}),
            .is_err = true,
        };
    };

    const at_ms = nowMs(opts);
    var parse_arena = std.heap.ArenaAllocator.init(opts.alloc);
    defer parse_arena.deinit();

    const parsed_args = parseCallArgs(parse_arena.allocator(), entry.kind, tc.args) catch {
        return .{
            .id = try opts.alloc.dupe(u8, tc.id),
            .out = try std.fmt.allocPrint(opts.alloc, "invalid tool arguments for {s}", .{tc.name}),
            .is_err = true,
        };
    };

    const call: tools.Call = .{
        .id = tc.id,
        .kind = entry.kind,
        .args = parsed_args,
        .src = .model,
        .at_ms = at_ms,
    };

    var mode_sink = ToolModeSink{
        .mode = opts.mode,
    };
    const sink = tools.Sink.from(ToolModeSink, &mode_sink, ToolModeSink.push);

    const run_res = opts.reg.run(entry.name, call, sink) catch |run_err| {
        const fail = tools.Result{
            .call_id = call.id,
            .started_at_ms = at_ms,
            .ended_at_ms = at_ms,
            .out = &.{},
            .final = .{ .failed = .{
                .kind = .internal,
                .msg = @errorName(run_err),
            } },
        };
        try sink.push(.{
            .finish = fail,
        });

        return .{
            .id = try opts.alloc.dupe(u8, tc.id),
            .out = try std.fmt.allocPrint(opts.alloc, "tool-failed:{s}", .{@errorName(run_err)}),
            .is_err = true,
        };
    };
    defer freeToolOut(opts.alloc, run_res);

    const out = try resultOut(opts.alloc, run_res);
    return .{
        .id = try opts.alloc.dupe(u8, tc.id),
        .out = out,
        .is_err = switch (run_res.final) {
            .ok => false,
            else => true,
        },
    };
}

const ToolModeSink = struct {
    mode: ModeSink,

    fn push(self: *ToolModeSink, ev: tools.Event) !void {
        return self.mode.push(.{
            .tool = ev,
        });
    }
};

fn resultOut(alloc: std.mem.Allocator, res: tools.Result) ![]const u8 {
    return switch (res.final) {
        .ok => joinChunks(alloc, res.out),
        .failed => |failed| try alloc.dupe(u8, failed.msg),
        .cancelled => |cancelled| try std.fmt.allocPrint(alloc, "cancelled:{s}", .{
            @tagName(cancelled.reason),
        }),
        .timed_out => |timed_out| try std.fmt.allocPrint(alloc, "timed-out:{d}", .{
            timed_out.limit_ms,
        }),
    };
}

fn freeToolOut(alloc: std.mem.Allocator, res: tools.Result) void {
    if (!res.out_owned) return;
    for (res.out) |chunk| {
        if (chunk.owned) alloc.free(chunk.chunk);
    }
    alloc.free(res.out);
}

fn joinChunks(alloc: std.mem.Allocator, out: []const tools.Output) ![]const u8 {
    var total: usize = 0;
    for (out) |chunk| total += chunk.chunk.len;

    const buf = try alloc.alloc(u8, total);
    var at: usize = 0;
    for (out) |chunk| {
        std.mem.copyForwards(u8, buf[at .. at + chunk.chunk.len], chunk.chunk);
        at += chunk.chunk.len;
    }
    return buf;
}

fn parseCallArgs(
    alloc: std.mem.Allocator,
    kind: tools.Kind,
    raw: []const u8,
) (Err || anyerror)!tools.Call.Args {
    return switch (kind) {
        .read => .{
            .read = try parseArgs(tools.Call.ReadArgs, alloc, raw),
        },
        .write => .{
            .write = try parseArgs(tools.Call.WriteArgs, alloc, raw),
        },
        .bash => .{
            .bash = try parseArgs(tools.Call.BashArgs, alloc, raw),
        },
        .edit => .{
            .edit = try parseArgs(tools.Call.EditArgs, alloc, raw),
        },
        .grep => .{
            .grep = try parseArgs(tools.Call.GrepArgs, alloc, raw),
        },
        .find => .{
            .find = try parseArgs(tools.Call.FindArgs, alloc, raw),
        },
        .ls => .{
            .ls = try parseArgs(tools.Call.LsArgs, alloc, raw),
        },
        .ask => .{
            .ask = try parseArgs(tools.Call.AskArgs, alloc, raw),
        },
    };
}

fn parseArgs(
    comptime T: type,
    alloc: std.mem.Allocator,
    raw: []const u8,
) (Err || anyerror)!T {
    return std.json.parseFromSliceLeaky(T, alloc, raw, .{
        .ignore_unknown_fields = true,
    }) catch |parse_err| switch (parse_err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidToolArgs,
    };
}

fn mapProviderEv(ev: providers.Ev, at_ms: i64) session.Event {
    return .{
        .at_ms = at_ms,
        .data = switch (ev) {
            .text => |text| .{ .text = .{ .text = text } },
            .thinking => |text| .{ .thinking = .{ .text = text } },
            .tool_call => |tc| .{ .tool_call = .{
                .id = tc.id,
                .name = tc.name,
                .args = tc.args,
            } },
            .tool_result => |tr| .{ .tool_result = .{
                .id = tr.id,
                .out = tr.out,
                .is_err = tr.is_err,
            } },
            .usage => |usage| .{ .usage = .{
                .in_tok = usage.in_tok,
                .out_tok = usage.out_tok,
                .tot_tok = usage.tot_tok,
            } },
            .stop => |stop| .{ .stop = .{
                .reason = switch (stop.reason) {
                    .done => .done,
                    .max_out => .max_out,
                    .tool => .tool,
                    .canceled => .canceled,
                    .err => .err,
                },
            } },
            .err => |text| .{ .err = .{ .text = text } },
        },
    };
}

fn expectMsgText(msg: providers.Msg, role: providers.Role, text: []const u8) !void {
    try std.testing.expect(msg.role == role);
    try std.testing.expectEqual(@as(usize, 1), msg.parts.len);
    switch (msg.parts[0]) {
        .text => |got| try std.testing.expectEqualStrings(text, got),
        else => return error.TestUnexpectedResult,
    }
}

fn hasToolResult(req: providers.Req, id: []const u8, out: []const u8) bool {
    for (req.msgs) |msg| {
        for (msg.parts) |part| {
            switch (part) {
                .tool_result => |tr| {
                    if (std.mem.eql(u8, tr.id, id) and std.mem.eql(u8, tr.out, out)) return true;
                },
                else => {},
            }
        }
    }
    return false;
}

test "loop smoke composes replay provider tool and mode" {
    const ReaderImpl = struct {
        evs: []const session.Event = &.{},
        idx: usize = 0,

        fn next(self: *@This()) !?session.Event {
            if (self.idx >= self.evs.len) return null;
            const ev = self.evs[self.idx];
            self.idx += 1;
            return ev;
        }

        fn deinit(_: *@This()) void {}
    };

    const StoreImpl = struct {
        append_ct: usize = 0,
        tool_result_ct: usize = 0,
        tool_result_out: [64]u8 = [_]u8{0} ** 64,
        tool_result_len: usize = 0,
        replay_evs: []const session.Event = &.{},
        replay_sid: []const u8 = "",
        append_sid: []const u8 = "",
        rdr: ReaderImpl = .{},

        fn append(self: *@This(), sid: []const u8, ev: session.Event) !void {
            self.append_ct += 1;
            self.append_sid = sid;

            switch (ev.data) {
                .tool_result => |tr| {
                    self.tool_result_ct += 1;
                    if (tr.out.len > self.tool_result_out.len) return error.TestUnexpectedResult;
                    std.mem.copyForwards(u8, self.tool_result_out[0..tr.out.len], tr.out);
                    self.tool_result_len = tr.out.len;
                },
                else => {},
            }
        }

        fn replay(self: *@This(), sid: []const u8) !session.Reader {
            self.replay_sid = sid;
            self.rdr = .{
                .evs = self.replay_evs,
                .idx = 0,
            };
            return session.Reader.from(
                ReaderImpl,
                &self.rdr,
                ReaderImpl.next,
                ReaderImpl.deinit,
            );
        }

        fn deinit(_: *@This()) void {}
    };

    const StreamImpl = struct {
        evs: []const providers.Ev = &.{},
        idx: usize = 0,
        deinit_ct: usize = 0,

        fn next(self: *@This()) !?providers.Ev {
            if (self.idx >= self.evs.len) return null;
            const ev = self.evs[self.idx];
            self.idx += 1;
            return ev;
        }

        fn deinit(self: *@This()) void {
            self.deinit_ct += 1;
        }
    };

    const ProviderImpl = struct {
        start_ct: usize = 0,
        turn1: []const providers.Ev,
        turn2: []const providers.Ev,
        stream: StreamImpl = .{},

        fn start(self: *@This(), req: providers.Req) !providers.Stream {
            self.start_ct += 1;
            try std.testing.expectEqual(@as(usize, 1), req.tools.len);
            try std.testing.expectEqualStrings("read", req.tools[0].name);

            switch (self.start_ct) {
                1 => {
                    try std.testing.expectEqual(@as(usize, 2), req.msgs.len);
                    try expectMsgText(req.msgs[0], .user, "prev");
                    try expectMsgText(req.msgs[1], .user, "ship-it");
                    self.stream.evs = self.turn1;
                    self.stream.idx = 0;
                },
                2 => {
                    try std.testing.expect(hasToolResult(req, "call-1", "tool-ok"));
                    self.stream.evs = self.turn2;
                    self.stream.idx = 0;
                },
                else => return error.TestUnexpectedResult,
            }

            return providers.Stream.from(
                StreamImpl,
                &self.stream,
                StreamImpl.next,
                StreamImpl.deinit,
            );
        }
    };

    const DispatchImpl = struct {
        run_ct: usize = 0,
        out: [1]tools.Output = undefined,

        fn run(self: *@This(), call: tools.Call, _: tools.Sink) !tools.Result {
            self.run_ct += 1;
            try std.testing.expect(call.kind == .read);
            try std.testing.expect(std.meta.activeTag(call.args) == .read);
            try std.testing.expectEqualStrings("a.txt", call.args.read.path);

            self.out[0] = .{
                .call_id = call.id,
                .seq = 0,
                .at_ms = call.at_ms,
                .stream = .stdout,
                .chunk = "tool-ok",
                .truncated = false,
            };

            return .{
                .call_id = call.id,
                .started_at_ms = call.at_ms,
                .ended_at_ms = call.at_ms,
                .out = self.out[0..],
                .final = .{ .ok = .{ .code = 0 } },
            };
        }
    };

    const ModeImpl = struct {
        replay_ct: usize = 0,
        session_ct: usize = 0,
        provider_ct: usize = 0,
        provider_tool_result_ct: usize = 0,
        tool_start_ct: usize = 0,
        tool_output_ct: usize = 0,
        tool_finish_ct: usize = 0,

        fn push(self: *@This(), ev: ModeEv) !void {
            switch (ev) {
                .replay => self.replay_ct += 1,
                .session => self.session_ct += 1,
                .provider => |pev| {
                    self.provider_ct += 1;
                    switch (pev) {
                        .tool_result => |tr| {
                            self.provider_tool_result_ct += 1;
                            try std.testing.expectEqualStrings("tool-ok", tr.out);
                        },
                        else => {},
                    }
                },
                .tool => |tev| switch (tev) {
                    .start => self.tool_start_ct += 1,
                    .output => |out| {
                        self.tool_output_ct += 1;
                        try std.testing.expectEqualStrings("tool-ok", out.chunk);
                    },
                    .finish => self.tool_finish_ct += 1,
                },
            }
        }
    };

    const ClockImpl = struct {
        now_ms: i64 = 900,

        fn nowMs(self: *@This()) i64 {
            return self.now_ms;
        }
    };

    const replay = [_]session.Event{
        .{
            .at_ms = 1,
            .data = .{ .prompt = .{ .text = "prev" } },
        },
    };

    const turn1 = [_]providers.Ev{
        .{ .text = "draft" },
        .{ .tool_call = .{
            .id = "call-1",
            .name = "read",
            .args = "{\"path\":\"a.txt\"}",
        } },
        .{ .stop = .{
            .reason = .tool,
        } },
    };
    const turn2 = [_]providers.Ev{
        .{ .text = "final" },
        .{ .stop = .{
            .reason = .done,
        } },
    };

    var provider_impl = ProviderImpl{
        .turn1 = turn1[0..],
        .turn2 = turn2[0..],
    };
    const provider = providers.Provider.from(
        ProviderImpl,
        &provider_impl,
        ProviderImpl.start,
    );

    var store_impl = StoreImpl{
        .replay_evs = replay[0..],
    };
    const store = session.SessionStore.from(
        StoreImpl,
        &store_impl,
        StoreImpl.append,
        StoreImpl.replay,
        StoreImpl.deinit,
    );

    var dispatch_impl = DispatchImpl{};
    const entries = [_]tools.Entry{
        .{
            .name = "read",
            .kind = .read,
            .spec = .{
                .kind = .read,
                .desc = "read file",
                .params = &.{},
                .out = .{
                    .max_bytes = 4096,
                    .stream = false,
                },
                .timeout_ms = 1000,
                .destructive = false,
            },
            .dispatch = tools.Dispatch.from(
                DispatchImpl,
                &dispatch_impl,
                DispatchImpl.run,
            ),
        },
    };
    const reg = tools.Registry.init(entries[0..]);

    var mode_impl = ModeImpl{};
    const mode = ModeSink.from(
        ModeImpl,
        &mode_impl,
        ModeImpl.push,
    );

    var clock_impl = ClockImpl{};
    const out = try run(.{
        .alloc = std.testing.allocator,
        .sid = "sid-1",
        .prompt = "ship-it",
        .model = "m1",
        .provider = provider,
        .store = store,
        .reg = reg,
        .mode = mode,
        .max_turns = 4,
        .time = TimeSrc.from(ClockImpl, &clock_impl, ClockImpl.nowMs),
    });

    try std.testing.expectEqual(@as(u16, 2), out.turns);
    try std.testing.expectEqual(@as(u32, 1), out.tool_calls);
    try std.testing.expectEqual(@as(usize, 2), provider_impl.start_ct);
    try std.testing.expectEqual(@as(usize, 2), provider_impl.stream.deinit_ct);
    try std.testing.expectEqual(@as(usize, 1), dispatch_impl.run_ct);

    try std.testing.expectEqual(@as(usize, 7), store_impl.append_ct);
    try std.testing.expectEqualStrings("sid-1", store_impl.replay_sid);
    try std.testing.expectEqualStrings("sid-1", store_impl.append_sid);
    try std.testing.expectEqual(@as(usize, 1), store_impl.tool_result_ct);
    try std.testing.expectEqualStrings("tool-ok", store_impl.tool_result_out[0..store_impl.tool_result_len]);

    try std.testing.expectEqual(@as(usize, 1), mode_impl.replay_ct);
    try std.testing.expectEqual(@as(usize, 7), mode_impl.session_ct);
    try std.testing.expectEqual(@as(usize, 6), mode_impl.provider_ct);
    try std.testing.expectEqual(@as(usize, 1), mode_impl.provider_tool_result_ct);
    try std.testing.expectEqual(@as(usize, 1), mode_impl.tool_start_ct);
    try std.testing.expectEqual(@as(usize, 1), mode_impl.tool_output_ct);
    try std.testing.expectEqual(@as(usize, 1), mode_impl.tool_finish_ct);
}

test "loop smoke finishes single turn with no tools" {
    const ReaderImpl = struct {
        fn next(_: *@This()) !?session.Event {
            return null;
        }

        fn deinit(_: *@This()) void {}
    };

    const StoreImpl = struct {
        append_ct: usize = 0,
        rdr: ReaderImpl = .{},

        fn append(self: *@This(), _: []const u8, _: session.Event) !void {
            self.append_ct += 1;
        }

        fn replay(self: *@This(), _: []const u8) !session.Reader {
            return session.Reader.from(
                ReaderImpl,
                &self.rdr,
                ReaderImpl.next,
                ReaderImpl.deinit,
            );
        }

        fn deinit(_: *@This()) void {}
    };

    const StreamImpl = struct {
        idx: usize = 0,
        evs: []const providers.Ev,
        deinit_ct: usize = 0,

        fn next(self: *@This()) !?providers.Ev {
            if (self.idx >= self.evs.len) return null;
            const ev = self.evs[self.idx];
            self.idx += 1;
            return ev;
        }

        fn deinit(self: *@This()) void {
            self.deinit_ct += 1;
        }
    };

    const ProviderImpl = struct {
        start_ct: usize = 0,
        stream: StreamImpl,

        fn start(self: *@This(), req: providers.Req) !providers.Stream {
            self.start_ct += 1;
            try std.testing.expectEqual(@as(usize, 1), req.msgs.len);
            try expectMsgText(req.msgs[0], .user, "hello");
            try std.testing.expectEqual(@as(usize, 0), req.tools.len);

            self.stream.idx = 0;
            return providers.Stream.from(
                StreamImpl,
                &self.stream,
                StreamImpl.next,
                StreamImpl.deinit,
            );
        }
    };

    const ModeImpl = struct {
        replay_ct: usize = 0,
        session_ct: usize = 0,
        provider_ct: usize = 0,
        tool_ct: usize = 0,

        fn push(self: *@This(), ev: ModeEv) !void {
            switch (ev) {
                .replay => self.replay_ct += 1,
                .session => self.session_ct += 1,
                .provider => self.provider_ct += 1,
                .tool => self.tool_ct += 1,
            }
        }
    };

    const evs = [_]providers.Ev{
        .{ .text = "done" },
        .{ .stop = .{
            .reason = .done,
        } },
    };
    var provider_impl = ProviderImpl{
        .stream = .{
            .evs = evs[0..],
        },
    };
    const provider = providers.Provider.from(
        ProviderImpl,
        &provider_impl,
        ProviderImpl.start,
    );

    var store_impl = StoreImpl{};
    const store = session.SessionStore.from(
        StoreImpl,
        &store_impl,
        StoreImpl.append,
        StoreImpl.replay,
        StoreImpl.deinit,
    );

    const reg = tools.Registry.init(&.{});

    var mode_impl = ModeImpl{};
    const mode = ModeSink.from(
        ModeImpl,
        &mode_impl,
        ModeImpl.push,
    );

    const out = try run(.{
        .alloc = std.testing.allocator,
        .sid = "sid-2",
        .prompt = "hello",
        .model = "m2",
        .provider = provider,
        .store = store,
        .reg = reg,
        .mode = mode,
    });

    try std.testing.expectEqual(@as(u16, 1), out.turns);
    try std.testing.expectEqual(@as(u32, 0), out.tool_calls);
    try std.testing.expectEqual(@as(usize, 1), provider_impl.start_ct);
    try std.testing.expectEqual(@as(usize, 1), provider_impl.stream.deinit_ct);
    try std.testing.expectEqual(@as(usize, 3), store_impl.append_ct);
    try std.testing.expectEqual(@as(usize, 0), mode_impl.replay_ct);
    try std.testing.expectEqual(@as(usize, 3), mode_impl.session_ct);
    try std.testing.expectEqual(@as(usize, 2), mode_impl.provider_ct);
    try std.testing.expectEqual(@as(usize, 0), mode_impl.tool_ct);
}

test "loop cancellation emits canceled stop and exits early" {
    const ReaderImpl = struct {
        fn next(_: *@This()) !?session.Event {
            return null;
        }

        fn deinit(_: *@This()) void {}
    };

    const StoreImpl = struct {
        append_ct: usize = 0,
        canceled_ct: usize = 0,
        rdr: ReaderImpl = .{},

        fn append(self: *@This(), _: []const u8, ev: session.Event) !void {
            self.append_ct += 1;
            if (ev.data == .stop and ev.data.stop.reason == .canceled) self.canceled_ct += 1;
        }

        fn replay(self: *@This(), _: []const u8) !session.Reader {
            return session.Reader.from(
                ReaderImpl,
                &self.rdr,
                ReaderImpl.next,
                ReaderImpl.deinit,
            );
        }

        fn deinit(_: *@This()) void {}
    };

    const StreamImpl = struct {
        evs: []const providers.Ev,
        idx: usize = 0,

        fn next(self: *@This()) !?providers.Ev {
            if (self.idx >= self.evs.len) return null;
            const ev = self.evs[self.idx];
            self.idx += 1;
            return ev;
        }

        fn deinit(_: *@This()) void {}
    };

    const ProviderImpl = struct {
        stream: StreamImpl,

        fn start(self: *@This(), _: providers.Req) !providers.Stream {
            self.stream.idx = 0;
            return providers.Stream.from(
                StreamImpl,
                &self.stream,
                StreamImpl.next,
                StreamImpl.deinit,
            );
        }
    };

    const ModeImpl = struct {
        provider_canceled_ct: usize = 0,

        fn push(self: *@This(), ev: ModeEv) !void {
            switch (ev) {
                .provider => |pev| {
                    if (pev == .stop and pev.stop.reason == .canceled) self.provider_canceled_ct += 1;
                },
                else => {},
            }
        }
    };

    const CancelImpl = struct {
        fn isCanceled(_: *@This()) bool {
            return true;
        }
    };

    const evs = [_]providers.Ev{
        .{ .text = "ignored" },
        .{ .stop = .{ .reason = .done } },
    };
    var provider_impl = ProviderImpl{
        .stream = .{
            .evs = evs[0..],
        },
    };
    const provider = providers.Provider.from(
        ProviderImpl,
        &provider_impl,
        ProviderImpl.start,
    );

    var store_impl = StoreImpl{};
    const store = session.SessionStore.from(
        StoreImpl,
        &store_impl,
        StoreImpl.append,
        StoreImpl.replay,
        StoreImpl.deinit,
    );

    var mode_impl = ModeImpl{};
    const mode = ModeSink.from(ModeImpl, &mode_impl, ModeImpl.push);

    var cancel_impl = CancelImpl{};
    const cancel = CancelSrc.from(CancelImpl, &cancel_impl, CancelImpl.isCanceled);

    const out = try run(.{
        .alloc = std.testing.allocator,
        .sid = "sid-cancel",
        .prompt = "hello",
        .model = "m",
        .provider = provider,
        .store = store,
        .reg = tools.Registry.init(&.{}),
        .mode = mode,
        .cancel = cancel,
    });

    try std.testing.expectEqual(@as(u16, 0), out.turns);
    try std.testing.expectEqual(@as(u32, 0), out.tool_calls);
    try std.testing.expectEqual(@as(usize, 1), store_impl.canceled_ct);
    try std.testing.expectEqual(@as(usize, 1), mode_impl.provider_canceled_ct);
}

test "loop compaction trigger runs at configured append cadence" {
    const ReaderImpl = struct {
        fn next(_: *@This()) !?session.Event {
            return null;
        }

        fn deinit(_: *@This()) void {}
    };

    const StoreImpl = struct {
        append_ct: usize = 0,
        rdr: ReaderImpl = .{},

        fn append(self: *@This(), _: []const u8, _: session.Event) !void {
            self.append_ct += 1;
        }

        fn replay(self: *@This(), _: []const u8) !session.Reader {
            return session.Reader.from(
                ReaderImpl,
                &self.rdr,
                ReaderImpl.next,
                ReaderImpl.deinit,
            );
        }

        fn deinit(_: *@This()) void {}
    };

    const StreamImpl = struct {
        evs: []const providers.Ev,
        idx: usize = 0,

        fn next(self: *@This()) !?providers.Ev {
            if (self.idx >= self.evs.len) return null;
            const ev = self.evs[self.idx];
            self.idx += 1;
            return ev;
        }

        fn deinit(_: *@This()) void {}
    };

    const ProviderImpl = struct {
        stream: StreamImpl,

        fn start(self: *@This(), _: providers.Req) !providers.Stream {
            self.stream.idx = 0;
            return providers.Stream.from(
                StreamImpl,
                &self.stream,
                StreamImpl.next,
                StreamImpl.deinit,
            );
        }
    };

    const ModeImpl = struct {
        fn push(_: *@This(), _: ModeEv) !void {}
    };

    const CompactorImpl = struct {
        run_ct: usize = 0,
        sid: []const u8 = "",

        fn run(self: *@This(), sid: []const u8, _: i64) !void {
            self.run_ct += 1;
            self.sid = sid;
        }
    };

    const evs = [_]providers.Ev{
        .{ .text = "a" },
        .{ .stop = .{ .reason = .done } },
    };
    var provider_impl = ProviderImpl{
        .stream = .{
            .evs = evs[0..],
        },
    };
    const provider = providers.Provider.from(
        ProviderImpl,
        &provider_impl,
        ProviderImpl.start,
    );

    var store_impl = StoreImpl{};
    const store = session.SessionStore.from(
        StoreImpl,
        &store_impl,
        StoreImpl.append,
        StoreImpl.replay,
        StoreImpl.deinit,
    );

    var mode_impl = ModeImpl{};
    const mode = ModeSink.from(ModeImpl, &mode_impl, ModeImpl.push);

    var comp_impl = CompactorImpl{};
    const comp = Compactor.from(CompactorImpl, &comp_impl, CompactorImpl.run);

    const out = try run(.{
        .alloc = std.testing.allocator,
        .sid = "sid-comp",
        .prompt = "hello",
        .model = "m",
        .provider = provider,
        .store = store,
        .reg = tools.Registry.init(&.{}),
        .mode = mode,
        .compactor = comp,
        .compact_every = 2,
    });

    try std.testing.expectEqual(@as(u16, 1), out.turns);
    try std.testing.expectEqual(@as(usize, 1), comp_impl.run_ct);
    try std.testing.expectEqualStrings("sid-comp", comp_impl.sid);
}

test "loop unified runtime error reporting appends stage-tagged error event" {
    const StartErr = error{StartBoom};

    const ReaderImpl = struct {
        fn next(_: *@This()) !?session.Event {
            return null;
        }

        fn deinit(_: *@This()) void {}
    };

    const StoreImpl = struct {
        append_ct: usize = 0,
        err_ct: usize = 0,
        last_err: [128]u8 = [_]u8{0} ** 128,
        last_err_len: usize = 0,
        rdr: ReaderImpl = .{},

        fn append(self: *@This(), _: []const u8, ev: session.Event) !void {
            self.append_ct += 1;
            if (ev.data == .err) {
                self.err_ct += 1;
                const msg = ev.data.err.text;
                if (msg.len > self.last_err.len) return error.TestUnexpectedResult;
                std.mem.copyForwards(u8, self.last_err[0..msg.len], msg);
                self.last_err_len = msg.len;
            }
        }

        fn replay(self: *@This(), _: []const u8) !session.Reader {
            return session.Reader.from(
                ReaderImpl,
                &self.rdr,
                ReaderImpl.next,
                ReaderImpl.deinit,
            );
        }

        fn deinit(_: *@This()) void {}
    };

    const ProviderImpl = struct {
        fn start(_: *@This(), _: providers.Req) StartErr!providers.Stream {
            return error.StartBoom;
        }
    };

    const ModeImpl = struct {
        fn push(_: *@This(), _: ModeEv) !void {}
    };

    var provider_impl = ProviderImpl{};
    const provider = providers.Provider.from(
        ProviderImpl,
        &provider_impl,
        ProviderImpl.start,
    );

    var store_impl = StoreImpl{};
    const store = session.SessionStore.from(
        StoreImpl,
        &store_impl,
        StoreImpl.append,
        StoreImpl.replay,
        StoreImpl.deinit,
    );

    var mode_impl = ModeImpl{};
    const mode = ModeSink.from(ModeImpl, &mode_impl, ModeImpl.push);

    try std.testing.expectError(error.StartBoom, run(.{
        .alloc = std.testing.allocator,
        .sid = "sid-err",
        .prompt = "hello",
        .model = "m",
        .provider = provider,
        .store = store,
        .reg = tools.Registry.init(&.{}),
        .mode = mode,
    }));

    try std.testing.expectEqual(@as(usize, 1), store_impl.err_ct);
    const last = store_impl.last_err[0..store_impl.last_err_len];
    try std.testing.expect(std.mem.indexOf(u8, last, "runtime:provider_start:StartBoom") != null);
}
