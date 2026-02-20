const std = @import("std");

pub fn bind(
    comptime Kind: type,
    comptime Spec: type,
    comptime Call: type,
    comptime Event: type,
    comptime Result: type,
) type {
    comptime {
        if (!@hasField(Call, "kind")) {
            @compileError("registry call type must define `kind`");
        }

        const probe: Call = undefined;
        if (@TypeOf(probe.kind) != Kind) {
            @compileError("registry call.kind must match registry kind type");
        }
    }

    return struct {
        pub const Err = error{
            NotFound,
            KindMismatch,
        };

        pub const Sink = struct {
            ctx: *anyopaque,
            vt: *const Vt,

            pub const Vt = struct {
                push: *const fn (ctx: *anyopaque, ev: Event) anyerror!void,
            };

            pub fn from(
                comptime T: type,
                ctx: *T,
                comptime push_fn: fn (ctx: *T, ev: Event) anyerror!void,
            ) Sink {
                const Wrap = struct {
                    fn push(raw: *anyopaque, ev: Event) anyerror!void {
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

            pub fn push(self: Sink, ev: Event) !void {
                return self.vt.push(self.ctx, ev);
            }
        };

        pub const Dispatch = struct {
            ctx: *anyopaque,
            vt: *const Vt,

            pub const Vt = struct {
                run: *const fn (ctx: *anyopaque, call: Call, sink: Sink) anyerror!Result,
            };

            pub fn from(
                comptime T: type,
                ctx: *T,
                comptime run_fn: fn (ctx: *T, call: Call, sink: Sink) anyerror!Result,
            ) Dispatch {
                const Wrap = struct {
                    fn run(raw: *anyopaque, call: Call, sink: Sink) anyerror!Result {
                        const typed: *T = @ptrCast(@alignCast(raw));
                        return run_fn(typed, call, sink);
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

            pub fn run(self: Dispatch, call: Call, sink: Sink) !Result {
                return self.vt.run(self.ctx, call, sink);
            }
        };

        pub const Entry = struct {
            name: []const u8,
            kind: Kind,
            spec: Spec,
            dispatch: Dispatch,
        };

        pub const Registry = struct {
            entries: []const Entry,

            pub fn init(entries: []const Entry) Registry {
                return .{
                    .entries = entries,
                };
            }

            pub fn byName(self: Registry, name: []const u8) ?*const Entry {
                for (self.entries) |*entry| {
                    if (std.mem.eql(u8, entry.name, name)) return entry;
                }
                return null;
            }

            pub fn byKind(self: Registry, kind: Kind) ?*const Entry {
                for (self.entries) |*entry| {
                    if (entry.kind == kind) return entry;
                }
                return null;
            }

            pub fn run(
                self: Registry,
                name: []const u8,
                call: Call,
                sink: Sink,
            ) (Err || anyerror)!Result {
                const entry = self.byName(name) orelse return Err.NotFound;
                if (call.kind != entry.kind) return Err.KindMismatch;
                return entry.dispatch.run(call, sink);
            }
        };
    };
}

const TKind = enum {
    read,
    write,
};

const TSpec = struct {
    timeout_ms: u32 = 0,
};

const TCall = struct {
    kind: TKind,
    value: i32,
};

const TEv = struct {
    id: u8,
};

const TResult = struct {
    code: i32,
};

const TReg = bind(TKind, TSpec, TCall, TEv, TResult);

test "registry lookup resolves by name and kind" {
    const DispatchImpl = struct {
        fn run(_: *@This(), call: TCall, _: TReg.Sink) !TResult {
            return .{ .code = call.value };
        }
    };

    var read_impl = DispatchImpl{};
    var write_impl = DispatchImpl{};
    const entries = [_]TReg.Entry{
        .{
            .name = "read",
            .kind = .read,
            .spec = .{ .timeout_ms = 10 },
            .dispatch = TReg.Dispatch.from(DispatchImpl, &read_impl, DispatchImpl.run),
        },
        .{
            .name = "write",
            .kind = .write,
            .spec = .{ .timeout_ms = 20 },
            .dispatch = TReg.Dispatch.from(DispatchImpl, &write_impl, DispatchImpl.run),
        },
    };
    const reg = TReg.Registry.init(entries[0..]);

    const read = reg.byName("read") orelse return error.TestUnexpectedResult;
    const write = reg.byKind(.write) orelse return error.TestUnexpectedResult;

    try std.testing.expect(read.kind == .read);
    try std.testing.expect(write.kind == .write);
    try std.testing.expectEqualStrings("write", write.name);
    try std.testing.expect(reg.byName("missing") == null);
}

test "registry run dispatches to named handler" {
    const SinkImpl = struct {
        ct: usize = 0,
        last: u8 = 0,

        fn push(self: *@This(), ev: TEv) !void {
            self.ct += 1;
            self.last = ev.id;
        }
    };

    const DispatchImpl = struct {
        ct: usize = 0,
        add: i32,
        ev_id: u8,

        fn run(self: *@This(), call: TCall, sink: TReg.Sink) !TResult {
            self.ct += 1;
            try sink.push(.{ .id = self.ev_id });
            return .{ .code = call.value + self.add };
        }
    };

    var sink_impl = SinkImpl{};
    const sink = TReg.Sink.from(SinkImpl, &sink_impl, SinkImpl.push);

    var read_impl = DispatchImpl{ .add = 10, .ev_id = 1 };
    var write_impl = DispatchImpl{ .add = 20, .ev_id = 2 };
    const entries = [_]TReg.Entry{
        .{
            .name = "read",
            .kind = .read,
            .spec = .{},
            .dispatch = TReg.Dispatch.from(DispatchImpl, &read_impl, DispatchImpl.run),
        },
        .{
            .name = "write",
            .kind = .write,
            .spec = .{},
            .dispatch = TReg.Dispatch.from(DispatchImpl, &write_impl, DispatchImpl.run),
        },
    };
    const reg = TReg.Registry.init(entries[0..]);

    const res = try reg.run("write", .{ .kind = .write, .value = 7 }, sink);
    try std.testing.expectEqual(@as(i32, 27), res.code);
    try std.testing.expectEqual(@as(usize, 0), read_impl.ct);
    try std.testing.expectEqual(@as(usize, 1), write_impl.ct);
    try std.testing.expectEqual(@as(usize, 1), sink_impl.ct);
    try std.testing.expectEqual(@as(u8, 2), sink_impl.last);

    try std.testing.expectError(
        TReg.Err.NotFound,
        reg.run("missing", .{ .kind = .read, .value = 1 }, sink),
    );
    try std.testing.expectError(
        TReg.Err.KindMismatch,
        reg.run("read", .{ .kind = .write, .value = 1 }, sink),
    );
    try std.testing.expectEqual(@as(usize, 0), read_impl.ct);
}
