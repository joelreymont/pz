const std = @import("std");
const core = @import("../../core/mod.zig");
const contract = @import("../contract.zig");
const format = @import("format.zig");
const run_err = @import("errors.zig");

pub const model_default = "default";

pub fn exec(run_ctx: contract.RunCtx) run_err.Err!void {
    var out = std.fs.File.stdout().deprecatedWriter();
    return execWithWriter(run_ctx, out.any());
}

pub fn execWithWriter(run_ctx: contract.RunCtx, out: std.Io.AnyWriter) run_err.Err!void {
    var formatter = format.Formatter.init(run_ctx.alloc, out);
    defer formatter.deinit();

    run_ctx.store.append(run_ctx.sid, .{
        .at_ms = std.time.milliTimestamp(),
        .data = .{ .prompt = .{ .text = run_ctx.prompt } },
    }) catch return error.PromptWrite;

    const parts = [_]core.providers.Part{
        .{ .text = run_ctx.prompt },
    };
    const msgs = [_]core.providers.Msg{
        .{
            .role = .user,
            .parts = parts[0..],
        },
    };

    var stream = run_ctx.provider.start(.{
        .model = model_default,
        .msgs = msgs[0..],
    }) catch return error.ProviderStart;
    defer stream.deinit();

    var stop_reason: ?core.providers.StopReason = null;
    while (true) {
        const ev = (stream.next() catch return error.StreamRead) orelse break;

        switch (ev) {
            .stop => |stop| {
                stop_reason = run_err.mergeStop(stop_reason, stop.reason);
            },
            else => {},
        }

        formatter.push(ev) catch return error.OutputFormat;
        run_ctx.store.append(run_ctx.sid, mapEvent(ev)) catch return error.EventWrite;
    }

    formatter.finish() catch return error.OutputFlush;

    if (stop_reason) |reason| {
        if (run_err.mapStop(reason)) |mapped| return mapped;
    }
}

fn mapEvent(ev: core.providers.Ev) core.session.Event {
    return .{
        .at_ms = std.time.milliTimestamp(),
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

test "exec runs prompt path and persists mapped provider events" {
    const StreamImpl = struct {
        idx: usize = 0,
        deinit_ct: usize = 0,
        evs: []const core.providers.Ev,

        fn next(self: *@This()) !?core.providers.Ev {
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
        model: []const u8 = "",
        msg_ct: usize = 0,
        part_ct: usize = 0,
        role: core.providers.Role = .assistant,
        prompt: []const u8 = "",
        stream: StreamImpl,

        fn start(self: *@This(), req: core.providers.Req) !core.providers.Stream {
            self.start_ct += 1;
            self.model = req.model;
            self.msg_ct = req.msgs.len;

            if (req.msgs.len > 0) {
                const msg = req.msgs[0];
                self.role = msg.role;
                self.part_ct = msg.parts.len;
                if (msg.parts.len > 0) {
                    switch (msg.parts[0]) {
                        .text => |text| self.prompt = text,
                        else => return error.BadPromptPart,
                    }
                }
            }

            return core.providers.Stream.from(
                StreamImpl,
                &self.stream,
                StreamImpl.next,
                StreamImpl.deinit,
            );
        }
    };

    const ReaderImpl = struct {
        fn next(_: *@This()) !?core.session.Event {
            return null;
        }

        fn deinit(_: *@This()) void {}
    };

    const StoreImpl = struct {
        append_ct: usize = 0,
        replay_ct: usize = 0,
        deinit_ct: usize = 0,
        sid: []const u8 = "",
        evs: [16]core.session.Event = undefined,
        len: usize = 0,
        rdr: ReaderImpl = .{},

        fn append(self: *@This(), sid: []const u8, ev: core.session.Event) !void {
            if (self.len >= self.evs.len) return error.StoreFull;
            self.append_ct += 1;
            self.sid = sid;
            self.evs[self.len] = ev;
            self.len += 1;
        }

        fn replay(self: *@This(), _: []const u8) !core.session.Reader {
            self.replay_ct += 1;
            return core.session.Reader.from(
                ReaderImpl,
                &self.rdr,
                ReaderImpl.next,
                ReaderImpl.deinit,
            );
        }

        fn deinit(self: *@This()) void {
            self.deinit_ct += 1;
        }
    };

    const in_evs = [_]core.providers.Ev{
        .{ .text = "out-a" },
        .{ .thinking = "think-a" },
        .{ .tool_call = .{
            .id = "call-1",
            .name = "read",
            .args = "{\"path\":\"x\"}",
        } },
        .{ .tool_result = .{
            .id = "call-1",
            .out = "ok",
            .is_err = false,
        } },
        .{ .usage = .{
            .in_tok = 5,
            .out_tok = 7,
            .tot_tok = 12,
        } },
        .{ .stop = .{
            .reason = .done,
        } },
        .{ .err = "warn-a" },
    };

    var provider_impl = ProviderImpl{
        .stream = .{
            .evs = in_evs[0..],
        },
    };
    const provider = core.providers.Provider.from(
        ProviderImpl,
        &provider_impl,
        ProviderImpl.start,
    );

    var store_impl = StoreImpl{};
    const store = core.session.SessionStore.from(
        StoreImpl,
        &store_impl,
        StoreImpl.append,
        StoreImpl.replay,
        StoreImpl.deinit,
    );

    var out_buf: [512]u8 = undefined;
    var out_fbs = std.io.fixedBufferStream(&out_buf);

    try execWithWriter(.{
        .alloc = std.testing.allocator,
        .provider = provider,
        .store = store,
        .sid = "sid-1",
        .prompt = "ship-it",
    }, out_fbs.writer().any());

    try std.testing.expectEqual(@as(usize, 1), provider_impl.start_ct);
    try std.testing.expectEqualStrings(model_default, provider_impl.model);
    try std.testing.expectEqual(@as(usize, 1), provider_impl.msg_ct);
    try std.testing.expectEqual(@as(usize, 1), provider_impl.part_ct);
    try std.testing.expectEqual(core.providers.Role.user, provider_impl.role);
    try std.testing.expectEqualStrings("ship-it", provider_impl.prompt);
    try std.testing.expectEqual(@as(usize, 1), provider_impl.stream.deinit_ct);

    try std.testing.expectEqual(@as(usize, 0), store_impl.replay_ct);
    try std.testing.expectEqual(@as(usize, 8), store_impl.append_ct);
    try std.testing.expectEqual(@as(usize, 8), store_impl.len);
    try std.testing.expectEqualStrings("sid-1", store_impl.sid);

    switch (store_impl.evs[0].data) {
        .prompt => |out| try std.testing.expectEqualStrings("ship-it", out.text),
        else => try std.testing.expect(false),
    }
    switch (store_impl.evs[1].data) {
        .text => |out| try std.testing.expectEqualStrings("out-a", out.text),
        else => try std.testing.expect(false),
    }
    switch (store_impl.evs[2].data) {
        .thinking => |out| try std.testing.expectEqualStrings("think-a", out.text),
        else => try std.testing.expect(false),
    }
    switch (store_impl.evs[3].data) {
        .tool_call => |out| {
            try std.testing.expectEqualStrings("call-1", out.id);
            try std.testing.expectEqualStrings("read", out.name);
            try std.testing.expectEqualStrings("{\"path\":\"x\"}", out.args);
        },
        else => try std.testing.expect(false),
    }
    switch (store_impl.evs[4].data) {
        .tool_result => |out| {
            try std.testing.expectEqualStrings("call-1", out.id);
            try std.testing.expectEqualStrings("ok", out.out);
            try std.testing.expect(!out.is_err);
        },
        else => try std.testing.expect(false),
    }
    switch (store_impl.evs[5].data) {
        .usage => |out| {
            try std.testing.expectEqual(@as(u64, 5), out.in_tok);
            try std.testing.expectEqual(@as(u64, 7), out.out_tok);
            try std.testing.expectEqual(@as(u64, 12), out.tot_tok);
        },
        else => try std.testing.expect(false),
    }
    switch (store_impl.evs[6].data) {
        .stop => |out| try std.testing.expectEqual(core.session.Event.StopReason.done, out.reason),
        else => try std.testing.expect(false),
    }
    switch (store_impl.evs[7].data) {
        .err => |out| try std.testing.expectEqualStrings("warn-a", out.text),
        else => try std.testing.expect(false),
    }

    const want_out =
        "out-a\n" ++
        "thinking \"think-a\"\n" ++
        "tool_call id=\"call-1\" name=\"read\" args=\"{\\\"path\\\":\\\"x\\\"}\"\n" ++
        "tool_result id=\"call-1\" is_err=false out=\"ok\"\n" ++
        "usage in=5 out=7 total=12\n" ++
        "stop reason=done\n" ++
        "err \"warn-a\"\n";
    try std.testing.expectEqualStrings(want_out, out_fbs.getWritten());
}

test "exec deinit stream and maps stream next error to typed print error" {
    const StreamImpl = struct {
        idx: usize = 0,
        fail_at: usize = 0,
        deinit_ct: usize = 0,

        fn next(self: *@This()) !?core.providers.Ev {
            if (self.idx == self.fail_at) return error.StreamFail;
            self.idx += 1;
            return .{ .text = "nope" };
        }

        fn deinit(self: *@This()) void {
            self.deinit_ct += 1;
        }
    };

    const ProviderImpl = struct {
        stream: StreamImpl = .{},

        fn start(self: *@This(), _: core.providers.Req) !core.providers.Stream {
            return core.providers.Stream.from(
                StreamImpl,
                &self.stream,
                StreamImpl.next,
                StreamImpl.deinit,
            );
        }
    };

    const ReaderImpl = struct {
        fn next(_: *@This()) !?core.session.Event {
            return null;
        }

        fn deinit(_: *@This()) void {}
    };

    const StoreImpl = struct {
        append_ct: usize = 0,
        evs: [2]core.session.Event = undefined,
        rdr: ReaderImpl = .{},

        fn append(self: *@This(), _: []const u8, ev: core.session.Event) !void {
            if (self.append_ct >= self.evs.len) return error.StoreFull;
            self.evs[self.append_ct] = ev;
            self.append_ct += 1;
        }

        fn replay(self: *@This(), _: []const u8) !core.session.Reader {
            return core.session.Reader.from(
                ReaderImpl,
                &self.rdr,
                ReaderImpl.next,
                ReaderImpl.deinit,
            );
        }

        fn deinit(_: *@This()) void {}
    };

    var provider_impl = ProviderImpl{};
    const provider = core.providers.Provider.from(
        ProviderImpl,
        &provider_impl,
        ProviderImpl.start,
    );

    var store_impl = StoreImpl{};
    const store = core.session.SessionStore.from(
        StoreImpl,
        &store_impl,
        StoreImpl.append,
        StoreImpl.replay,
        StoreImpl.deinit,
    );

    var out_buf: [32]u8 = undefined;
    var out_fbs = std.io.fixedBufferStream(&out_buf);

    try std.testing.expectError(error.StreamRead, execWithWriter(.{
        .alloc = std.testing.allocator,
        .provider = provider,
        .store = store,
        .sid = "sid-2",
        .prompt = "prompt-2",
    }, out_fbs.writer().any()));

    try std.testing.expectEqual(@as(usize, 1), provider_impl.stream.deinit_ct);
    try std.testing.expectEqual(@as(usize, 1), store_impl.append_ct);
    switch (store_impl.evs[0].data) {
        .prompt => |out| try std.testing.expectEqualStrings("prompt-2", out.text),
        else => try std.testing.expect(false),
    }
    try std.testing.expectEqualStrings("", out_fbs.getWritten());
}

test "exec maps max_out stop reason to deterministic typed error" {
    const StreamImpl = struct {
        idx: usize = 0,
        deinit_ct: usize = 0,
        evs: []const core.providers.Ev,

        fn next(self: *@This()) !?core.providers.Ev {
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
        stream: StreamImpl,

        fn start(self: *@This(), _: core.providers.Req) !core.providers.Stream {
            return core.providers.Stream.from(
                StreamImpl,
                &self.stream,
                StreamImpl.next,
                StreamImpl.deinit,
            );
        }
    };

    const ReaderImpl = struct {
        fn next(_: *@This()) !?core.session.Event {
            return null;
        }

        fn deinit(_: *@This()) void {}
    };

    const StoreImpl = struct {
        append_ct: usize = 0,
        evs: [4]core.session.Event = undefined,
        rdr: ReaderImpl = .{},

        fn append(self: *@This(), _: []const u8, ev: core.session.Event) !void {
            if (self.append_ct >= self.evs.len) return error.StoreFull;
            self.evs[self.append_ct] = ev;
            self.append_ct += 1;
        }

        fn replay(self: *@This(), _: []const u8) !core.session.Reader {
            return core.session.Reader.from(
                ReaderImpl,
                &self.rdr,
                ReaderImpl.next,
                ReaderImpl.deinit,
            );
        }

        fn deinit(_: *@This()) void {}
    };

    const in_evs = [_]core.providers.Ev{
        .{ .text = "out-z" },
        .{ .stop = .{ .reason = .max_out } },
    };

    var provider_impl = ProviderImpl{
        .stream = .{
            .evs = in_evs[0..],
        },
    };
    const provider = core.providers.Provider.from(
        ProviderImpl,
        &provider_impl,
        ProviderImpl.start,
    );

    var store_impl = StoreImpl{};
    const store = core.session.SessionStore.from(
        StoreImpl,
        &store_impl,
        StoreImpl.append,
        StoreImpl.replay,
        StoreImpl.deinit,
    );

    var out_buf: [128]u8 = undefined;
    var out_fbs = std.io.fixedBufferStream(&out_buf);

    try std.testing.expectError(error.StopMaxOut, execWithWriter(.{
        .alloc = std.testing.allocator,
        .provider = provider,
        .store = store,
        .sid = "sid-3",
        .prompt = "prompt-3",
    }, out_fbs.writer().any()));

    try std.testing.expectEqual(@as(usize, 1), provider_impl.stream.deinit_ct);
    try std.testing.expectEqual(@as(usize, 3), store_impl.append_ct);
    try std.testing.expectEqualStrings("out-z\nstop reason=max_out\n", out_fbs.getWritten());
}

test "exec chooses highest stop reason deterministically" {
    const StreamImpl = struct {
        idx: usize = 0,
        deinit_ct: usize = 0,
        evs: []const core.providers.Ev,

        fn next(self: *@This()) !?core.providers.Ev {
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
        stream: StreamImpl,

        fn start(self: *@This(), _: core.providers.Req) !core.providers.Stream {
            return core.providers.Stream.from(
                StreamImpl,
                &self.stream,
                StreamImpl.next,
                StreamImpl.deinit,
            );
        }
    };

    const ReaderImpl = struct {
        fn next(_: *@This()) !?core.session.Event {
            return null;
        }

        fn deinit(_: *@This()) void {}
    };

    const StoreImpl = struct {
        append_ct: usize = 0,
        evs: [4]core.session.Event = undefined,
        rdr: ReaderImpl = .{},

        fn append(self: *@This(), _: []const u8, ev: core.session.Event) !void {
            if (self.append_ct >= self.evs.len) return error.StoreFull;
            self.evs[self.append_ct] = ev;
            self.append_ct += 1;
        }

        fn replay(self: *@This(), _: []const u8) !core.session.Reader {
            return core.session.Reader.from(
                ReaderImpl,
                &self.rdr,
                ReaderImpl.next,
                ReaderImpl.deinit,
            );
        }

        fn deinit(_: *@This()) void {}
    };

    const in_evs = [_]core.providers.Ev{
        .{ .stop = .{ .reason = .done } },
        .{ .stop = .{ .reason = .err } },
    };

    var provider_impl = ProviderImpl{
        .stream = .{
            .evs = in_evs[0..],
        },
    };
    const provider = core.providers.Provider.from(
        ProviderImpl,
        &provider_impl,
        ProviderImpl.start,
    );

    var store_impl = StoreImpl{};
    const store = core.session.SessionStore.from(
        StoreImpl,
        &store_impl,
        StoreImpl.append,
        StoreImpl.replay,
        StoreImpl.deinit,
    );

    var out_buf: [128]u8 = undefined;
    var out_fbs = std.io.fixedBufferStream(&out_buf);

    try std.testing.expectError(error.StopErr, execWithWriter(.{
        .alloc = std.testing.allocator,
        .provider = provider,
        .store = store,
        .sid = "sid-4",
        .prompt = "prompt-4",
    }, out_fbs.writer().any()));

    try std.testing.expectEqual(@as(usize, 1), provider_impl.stream.deinit_ct);
    try std.testing.expectEqual(@as(usize, 3), store_impl.append_ct);
    try std.testing.expectEqualStrings("stop reason=err\n", out_fbs.getWritten());
}
