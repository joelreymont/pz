const std = @import("std");
const schema = @import("schema.zig");
pub const writer = @import("writer.zig");
pub const reader = @import("reader.zig");
pub const fs_store = @import("fs_store.zig");
pub const null_store = @import("null_store.zig");
pub const selector = @import("selector.zig");
pub const path = @import("path.zig");
pub const compact = @import("compact.zig");
pub const retry_state = @import("retry_state.zig");
pub const regress = @import("regress.zig");
pub const golden = @import("golden.zig");

pub const Event = schema.Event;
pub const event_version = schema.version_current;
pub const encodeEventAlloc = schema.encodeAlloc;
pub const decodeEventSlice = schema.decodeSlice;
pub const Writer = writer.Writer;
pub const FlushPolicy = writer.FlushPolicy;
pub const ReplayReader = reader.ReplayReader;
pub const ReplayOpts = reader.Opts;
pub const FsStore = fs_store.Store;
pub const NullStore = null_store.Store;
pub const CompactCheckpoint = compact.Checkpoint;
pub const compactSession = compact.run;
pub const loadCompactCheckpoint = compact.loadCheckpoint;
pub const RetryState = retry_state.State;
pub const saveRetryState = retry_state.save;
pub const loadRetryState = retry_state.load;

pub const Reader = struct {
    ctx: *anyopaque,
    vt: *const Vt,

    pub const Vt = struct {
        next: *const fn (ctx: *anyopaque) anyerror!?Event,
        deinit: *const fn (ctx: *anyopaque) void,
    };

    pub fn from(
        comptime T: type,
        ctx: *T,
        comptime next_fn: fn (ctx: *T) anyerror!?Event,
        comptime deinit_fn: fn (ctx: *T) void,
    ) Reader {
        const Wrap = struct {
            fn next(raw: *anyopaque) anyerror!?Event {
                const typed: *T = @ptrCast(@alignCast(raw));
                return next_fn(typed);
            }

            fn deinit(raw: *anyopaque) void {
                const typed: *T = @ptrCast(@alignCast(raw));
                deinit_fn(typed);
            }

            const vt = Vt{
                .next = @This().next,
                .deinit = @This().deinit,
            };
        };

        return .{
            .ctx = ctx,
            .vt = &Wrap.vt,
        };
    }

    pub fn next(self: *Reader) !?Event {
        return self.vt.next(self.ctx);
    }

    pub fn deinit(self: *Reader) void {
        self.vt.deinit(self.ctx);
    }
};

pub const SessionStore = struct {
    ctx: *anyopaque,
    vt: *const Vt,

    pub const Vt = struct {
        append: *const fn (ctx: *anyopaque, sid: []const u8, ev: Event) anyerror!void,
        replay: *const fn (ctx: *anyopaque, sid: []const u8) anyerror!Reader,
        deinit: *const fn (ctx: *anyopaque) void,
    };

    pub fn from(
        comptime T: type,
        ctx: *T,
        comptime append_fn: fn (ctx: *T, sid: []const u8, ev: Event) anyerror!void,
        comptime replay_fn: fn (ctx: *T, sid: []const u8) anyerror!Reader,
        comptime deinit_fn: fn (ctx: *T) void,
    ) SessionStore {
        const Wrap = struct {
            fn append(raw: *anyopaque, sid: []const u8, ev: Event) anyerror!void {
                const typed: *T = @ptrCast(@alignCast(raw));
                return append_fn(typed, sid, ev);
            }

            fn replay(raw: *anyopaque, sid: []const u8) anyerror!Reader {
                const typed: *T = @ptrCast(@alignCast(raw));
                return replay_fn(typed, sid);
            }

            fn deinit(raw: *anyopaque) void {
                const typed: *T = @ptrCast(@alignCast(raw));
                deinit_fn(typed);
            }

            const vt = Vt{
                .append = @This().append,
                .replay = @This().replay,
                .deinit = @This().deinit,
            };
        };

        return .{
            .ctx = ctx,
            .vt = &Wrap.vt,
        };
    }

    pub fn append(self: SessionStore, sid: []const u8, ev: Event) !void {
        return self.vt.append(self.ctx, sid, ev);
    }

    pub fn replay(self: SessionStore, sid: []const u8) !Reader {
        return self.vt.replay(self.ctx, sid);
    }

    pub fn deinit(self: SessionStore) void {
        self.vt.deinit(self.ctx);
    }
};

pub const Store = SessionStore;

test "session store contract dispatches through vtable" {
    const ReaderImpl = struct {
        left: u8 = 0,

        fn next(self: *@This()) !?Event {
            if (self.left == 0) return null;
            self.left -= 1;
            return .{};
        }

        fn deinit(_: *@This()) void {}
    };

    const StoreImpl = struct {
        append_ct: usize = 0,
        replay_ct: usize = 0,
        deinit_ct: usize = 0,
        sid_len: usize = 0,
        rdr: ReaderImpl = .{},

        fn append(self: *@This(), sid: []const u8, _: Event) !void {
            self.append_ct += 1;
            self.sid_len = sid.len;
        }

        fn replay(self: *@This(), sid: []const u8) !Reader {
            self.replay_ct += 1;
            self.sid_len = sid.len;
            self.rdr.left = 1;
            return Reader.from(ReaderImpl, &self.rdr, ReaderImpl.next, ReaderImpl.deinit);
        }

        fn deinit(self: *@This()) void {
            self.deinit_ct += 1;
        }
    };

    var impl = StoreImpl{};
    var store = SessionStore.from(
        StoreImpl,
        &impl,
        StoreImpl.append,
        StoreImpl.replay,
        StoreImpl.deinit,
    );

    try store.append("abc", .{});
    var rdr = try store.replay("abc");
    defer rdr.deinit();

    try std.testing.expect((try rdr.next()) != null);
    try std.testing.expect((try rdr.next()) == null);
    try std.testing.expect(impl.append_ct == 1);
    try std.testing.expect(impl.replay_ct == 1);
    try std.testing.expect(impl.sid_len == 3);

    store.deinit();
    try std.testing.expect(impl.deinit_ct == 1);
}
