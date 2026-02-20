const std = @import("std");
const tools = @import("mod.zig");

fn noopSink() tools.Sink {
    const SinkImpl = struct {
        fn push(_: *@This(), _: tools.Event) !void {}
    };
    var sink_impl = SinkImpl{};
    return tools.Sink.from(SinkImpl, &sink_impl, SinkImpl.push);
}

fn expectResultEnvelope(call: tools.Call, res: tools.Result) !void {
    try std.testing.expectEqualStrings(call.id, res.call_id);
    try std.testing.expect(res.ended_at_ms >= res.started_at_ms);

    var expected_seq: u32 = 0;
    for (res.out) |out| {
        try std.testing.expectEqualStrings(call.id, out.call_id);
        try std.testing.expectEqual(expected_seq, out.seq);
        expected_seq += 1;
    }
}

test "tool contract handlers emit deterministic envelopes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);

    const in_path = try std.fs.path.join(std.testing.allocator, &.{ path, "in.txt" });
    defer std.testing.allocator.free(in_path);
    try tmp.dir.writeFile(.{
        .sub_path = "in.txt",
        .data = "a\nb\n",
    });

    const out_path = try std.fs.path.join(std.testing.allocator, &.{ path, "out.txt" });
    defer std.testing.allocator.free(out_path);
    try tmp.dir.writeFile(.{
        .sub_path = "out.txt",
        .data = "x",
    });

    const edit_path = try std.fs.path.join(std.testing.allocator, &.{ path, "edit.txt" });
    defer std.testing.allocator.free(edit_path);
    try tmp.dir.writeFile(.{
        .sub_path = "edit.txt",
        .data = "abc abc",
    });
    try tmp.dir.makePath("tree/sub");
    try tmp.dir.writeFile(.{
        .sub_path = "tree/sub/hit.txt",
        .data = "needle\n",
    });

    const sink = noopSink();

    const rd = @import("read.zig").Handler.init(.{
        .alloc = std.testing.allocator,
        .max_bytes = 4096,
        .now_ms = 11,
    });
    const rd_call: tools.Call = .{
        .id = "r1",
        .kind = .read,
        .args = .{ .read = .{
            .path = in_path,
        } },
        .src = .system,
        .at_ms = 0,
    };
    const rd_res = try rd.run(rd_call, sink);
    defer rd.deinitResult(rd_res);
    try expectResultEnvelope(rd_call, rd_res);

    const wr = @import("write.zig").Handler.init(.{
        .now_ms = 22,
    });
    const wr_call: tools.Call = .{
        .id = "w1",
        .kind = .write,
        .args = .{ .write = .{
            .path = out_path,
            .text = "ok",
            .append = false,
        } },
        .src = .system,
        .at_ms = 0,
    };
    const wr_res = try wr.run(wr_call, sink);
    try expectResultEnvelope(wr_call, wr_res);

    const ed = @import("edit.zig").Handler.init(.{
        .alloc = std.testing.allocator,
        .max_bytes = 4096,
        .now_ms = 33,
    });
    const ed_call: tools.Call = .{
        .id = "e1",
        .kind = .edit,
        .args = .{ .edit = .{
            .path = edit_path,
            .old = "abc",
            .new = "z",
            .all = false,
        } },
        .src = .system,
        .at_ms = 0,
    };
    const ed_res = try ed.run(ed_call, sink);
    try expectResultEnvelope(ed_call, ed_res);

    const sh = @import("bash.zig").Handler.init(.{
        .alloc = std.testing.allocator,
        .max_bytes = 4096,
        .now_ms = 44,
    });
    const sh_call: tools.Call = .{
        .id = "b1",
        .kind = .bash,
        .args = .{ .bash = .{
            .cmd = "printf out",
        } },
        .src = .system,
        .at_ms = 0,
    };
    const sh_res = try sh.run(sh_call, sink);
    defer sh.deinitResult(sh_res);
    try expectResultEnvelope(sh_call, sh_res);

    const ls_h = @import("ls.zig").Handler.init(.{
        .alloc = std.testing.allocator,
        .max_bytes = 4096,
        .now_ms = 66,
    });
    const ls_call: tools.Call = .{
        .id = "l1",
        .kind = .ls,
        .args = .{ .ls = .{
            .path = path,
        } },
        .src = .system,
        .at_ms = 0,
    };
    const ls_res = try ls_h.run(ls_call, sink);
    defer ls_h.deinitResult(ls_res);
    try expectResultEnvelope(ls_call, ls_res);

    const find_h = @import("find.zig").Handler.init(.{
        .alloc = std.testing.allocator,
        .max_bytes = 4096,
        .now_ms = 77,
    });
    const find_call: tools.Call = .{
        .id = "f1",
        .kind = .find,
        .args = .{ .find = .{
            .path = path,
            .name = "hit",
        } },
        .src = .system,
        .at_ms = 0,
    };
    const find_res = try find_h.run(find_call, sink);
    defer find_h.deinitResult(find_res);
    try expectResultEnvelope(find_call, find_res);

    const grep_h = @import("grep.zig").Handler.init(.{
        .alloc = std.testing.allocator,
        .max_bytes = 4096,
        .now_ms = 88,
    });
    const grep_call: tools.Call = .{
        .id = "g1",
        .kind = .grep,
        .args = .{ .grep = .{
            .path = path,
            .pattern = "needle",
        } },
        .src = .system,
        .at_ms = 0,
    };
    const grep_res = try grep_h.run(grep_call, sink);
    defer grep_h.deinitResult(grep_res);
    try expectResultEnvelope(grep_call, grep_res);
}

test "tool contract registry emits start output finish ordering" {
    const SinkImpl = struct {
        tags: [8]std.meta.Tag(tools.Event) = undefined,
        ct: usize = 0,

        fn push(self: *@This(), ev: tools.Event) !void {
            if (self.ct >= self.tags.len) return error.OutOfMemory;
            self.tags[self.ct] = std.meta.activeTag(ev);
            self.ct += 1;
        }
    };
    var sink_impl = SinkImpl{};
    const sink = tools.Sink.from(SinkImpl, &sink_impl, SinkImpl.push);

    const Wrap = struct {
        h: @import("bash.zig").Handler,

        fn run(self: *@This(), call: tools.Call, s: tools.Sink) !tools.Result {
            return self.h.run(call, s);
        }
    };
    var wrap = Wrap{
        .h = @import("bash.zig").Handler.init(.{
            .alloc = std.testing.allocator,
            .max_bytes = 4096,
            .now_ms = 55,
        }),
    };

    const entries = [_]tools.Entry{
        .{
            .name = "bash",
            .kind = .bash,
            .spec = .{
                .kind = .bash,
                .desc = "bash",
                .params = &.{},
                .out = .{
                    .max_bytes = 4096,
                    .stream = true,
                },
                .timeout_ms = 1000,
                .destructive = true,
            },
            .dispatch = tools.Dispatch.from(Wrap, &wrap, Wrap.run),
        },
    };
    const reg = tools.Registry.init(entries[0..]);

    const call: tools.Call = .{
        .id = "call-1",
        .kind = .bash,
        .args = .{ .bash = .{
            .cmd = "printf hi",
        } },
        .src = .model,
        .at_ms = 1,
    };
    const res = try reg.run("bash", call, sink);
    defer wrap.h.deinitResult(res);

    try std.testing.expect(sink_impl.ct >= 2);
    try std.testing.expect(sink_impl.tags[0] == .start);
    try std.testing.expect(sink_impl.tags[sink_impl.ct - 1] == .finish);
}
