const std = @import("std");
const session = @import("mod.zig");

pub const Store = struct {
    pub fn init() Store {
        return .{};
    }

    pub fn asSessionStore(self: *Store) session.SessionStore {
        return session.SessionStore.from(
            Store,
            self,
            Store.append,
            Store.replay,
            Store.deinitStore,
        );
    }

    fn append(_: *Store, _: []const u8, _: session.Event) !void {}

    fn replay(_: *Store, _: []const u8) !session.Reader {
        return error.FileNotFound;
    }

    fn deinitStore(self: *Store) void {
        self.deinit();
    }

    pub fn deinit(_: *Store) void {}
};

test "null store append is no-op and replay behaves as missing session" {
    var store_impl = Store.init();
    var store = store_impl.asSessionStore();

    try store.append("sid", .{
        .at_ms = 1,
        .data = .{ .prompt = .{ .text = "hi" } },
    });
    try std.testing.expectError(error.FileNotFound, store.replay("sid"));

    store.deinit();
}
