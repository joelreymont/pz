const std = @import("std");
const core = @import("../core/mod.zig");

pub const RunCtx = struct {
    alloc: std.mem.Allocator,
    provider: core.providers.Provider,
    store: core.session.SessionStore,
    sid: []const u8,
    prompt: []const u8,
};

pub const Mode = struct {
    ctx: *anyopaque,
    vt: *const Vt,

    pub const Vt = struct {
        run: *const fn (ctx: *anyopaque, run_ctx: RunCtx) anyerror!void,
    };

    pub fn from(
        comptime T: type,
        ctx: *T,
        comptime run_fn: fn (ctx: *T, run_ctx: RunCtx) anyerror!void,
    ) Mode {
        const Wrap = struct {
            fn run(raw: *anyopaque, run_ctx: RunCtx) anyerror!void {
                const typed: *T = @ptrCast(@alignCast(raw));
                return run_fn(typed, run_ctx);
            }

            const vt = Vt{
                .run = @This().run,
            };
        };

        return .{
            .ctx = ctx,
            .vt = &Wrap.vt,
        };
    }

    pub fn run(self: Mode, run_ctx: RunCtx) !void {
        return self.vt.run(self.ctx, run_ctx);
    }
};

test "mode contract is usable with core contracts" {
    const StreamImpl = struct {
        fn next(_: *@This()) !?core.providers.Ev {
            return null;
        }

        fn deinit(_: *@This()) void {}
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
        left: u8 = 0,

        fn next(self: *@This()) !?core.session.Event {
            if (self.left == 0) return null;
            self.left -= 1;
            return .{};
        }

        fn deinit(_: *@This()) void {}
    };

    const StoreImpl = struct {
        append_ct: usize = 0,
        replay_ct: usize = 0,
        rdr: ReaderImpl = .{},

        fn append(self: *@This(), _: []const u8, _: core.session.Event) !void {
            self.append_ct += 1;
        }

        fn replay(self: *@This(), _: []const u8) !core.session.Reader {
            self.replay_ct += 1;
            self.rdr.left = 1;
            return core.session.Reader.from(
                ReaderImpl,
                &self.rdr,
                ReaderImpl.next,
                ReaderImpl.deinit,
            );
        }

        fn deinit(_: *@This()) void {}
    };

    const ModeImpl = struct {
        run_ct: usize = 0,

        fn run(self: *@This(), run_ctx: RunCtx) !void {
            self.run_ct += 1;
            _ = run_ctx.alloc;
            _ = run_ctx.prompt;

            try run_ctx.store.append(run_ctx.sid, .{});
            var rdr = try run_ctx.store.replay(run_ctx.sid);
            defer rdr.deinit();
            _ = try rdr.next();

            var stream = try run_ctx.provider.start(.{
                .model = "stub",
                .msgs = &.{},
            });
            defer stream.deinit();
            _ = try stream.next();
        }
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

    var mode_impl = ModeImpl{};
    const mode = Mode.from(ModeImpl, &mode_impl, ModeImpl.run);
    try mode.run(.{
        .alloc = std.testing.allocator,
        .provider = provider,
        .store = store,
        .sid = "s1",
        .prompt = "p",
    });

    try std.testing.expect(mode_impl.run_ct == 1);
    try std.testing.expect(store_impl.append_ct == 1);
    try std.testing.expect(store_impl.replay_ct == 1);
}
