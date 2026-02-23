const std = @import("std");
const tools = @import("mod.zig");
const read = @import("read.zig");
const write = @import("write.zig");
const bash = @import("bash.zig");
const edit = @import("edit.zig");
const grep = @import("grep.zig");
const find = @import("find.zig");
const ls = @import("ls.zig");

const default_max_bytes: usize = 64 * 1024;
pub const mask_read: u8 = 1 << 0;
pub const mask_write: u8 = 1 << 1;
pub const mask_bash: u8 = 1 << 2;
pub const mask_edit: u8 = 1 << 3;
pub const mask_grep: u8 = 1 << 4;
pub const mask_find: u8 = 1 << 5;
pub const mask_ls: u8 = 1 << 6;
pub const mask_ask: u8 = 1 << 7;
pub const mask_all: u8 =
    mask_read |
    mask_write |
    mask_bash |
    mask_edit |
    mask_grep |
    mask_find |
    mask_ls |
    mask_ask;

const read_params = [_]tools.Tool.Param{
    .{ .name = "path", .ty = .string, .required = true, .desc = "File path" },
    .{ .name = "from_line", .ty = .int, .required = false, .desc = "Start line (1-based)" },
    .{ .name = "to_line", .ty = .int, .required = false, .desc = "End line (inclusive)" },
};

const write_params = [_]tools.Tool.Param{
    .{ .name = "path", .ty = .string, .required = true, .desc = "File path" },
    .{ .name = "text", .ty = .string, .required = true, .desc = "Content to write" },
    .{ .name = "append", .ty = .bool, .required = false, .desc = "Append instead of truncating" },
};

const bash_params = [_]tools.Tool.Param{
    .{ .name = "cmd", .ty = .string, .required = true, .desc = "Shell command" },
    .{ .name = "cwd", .ty = .string, .required = false, .desc = "Working directory" },
    .{ .name = "env", .ty = .string, .required = false, .desc = "Environment variables (KEY=VALUE, one per line)" },
};

const edit_params = [_]tools.Tool.Param{
    .{ .name = "path", .ty = .string, .required = true, .desc = "File path" },
    .{ .name = "old", .ty = .string, .required = true, .desc = "Substring to replace" },
    .{ .name = "new", .ty = .string, .required = true, .desc = "Replacement text" },
    .{ .name = "all", .ty = .bool, .required = false, .desc = "Replace all matches" },
};

const grep_params = [_]tools.Tool.Param{
    .{ .name = "pattern", .ty = .string, .required = true, .desc = "Substring to match in file lines" },
    .{ .name = "path", .ty = .string, .required = false, .desc = "Root directory to search" },
    .{ .name = "ignore_case", .ty = .bool, .required = false, .desc = "Case-insensitive matching" },
    .{ .name = "max_results", .ty = .int, .required = false, .desc = "Maximum matches to return" },
};

const find_params = [_]tools.Tool.Param{
    .{ .name = "name", .ty = .string, .required = true, .desc = "Substring to match in entry names" },
    .{ .name = "path", .ty = .string, .required = false, .desc = "Root directory to walk" },
    .{ .name = "max_results", .ty = .int, .required = false, .desc = "Maximum paths to return" },
};

const ls_params = [_]tools.Tool.Param{
    .{ .name = "path", .ty = .string, .required = false, .desc = "Directory to list" },
    .{ .name = "all", .ty = .bool, .required = false, .desc = "Include hidden entries" },
};

const ask_schema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "questions": {
    \\      "type": "array",
    \\      "items": {
    \\        "type": "object",
    \\        "properties": {
    \\          "id": { "type": "string", "description": "Stable question id" },
    \\          "header": { "type": "string", "description": "Short title shown above the question" },
    \\          "question": { "type": "string", "description": "Question prompt text" },
    \\          "allow_other": { "type": "boolean", "description": "Include a Type something else option (default true)" },
    \\          "options": {
    \\            "type": "array",
    \\            "items": {
    \\              "type": "object",
    \\              "properties": {
    \\                "label": { "type": "string", "description": "Option label" },
    \\                "description": { "type": "string", "description": "Optional option detail text" }
    \\              },
    \\              "required": ["label"]
    \\            }
    \\          }
    \\        },
    \\        "required": ["id", "question", "options"]
    \\      }
    \\    }
    \\  },
    \\  "required": ["questions"]
    \\}
;

pub const AskHook = struct {
    ctx: *anyopaque,
    run_fn: *const fn (ctx: *anyopaque, args: tools.Call.AskArgs) anyerror![]u8,

    pub fn from(
        comptime T: type,
        ctx: *T,
        comptime run_fn: fn (ctx: *T, args: tools.Call.AskArgs) anyerror![]u8,
    ) AskHook {
        const Wrap = struct {
            fn call(raw: *anyopaque, args: tools.Call.AskArgs) anyerror![]u8 {
                const typed: *T = @ptrCast(@alignCast(raw));
                return run_fn(typed, args);
            }
        };
        return .{
            .ctx = ctx,
            .run_fn = Wrap.call,
        };
    }

    pub fn run(self: AskHook, args: tools.Call.AskArgs) ![]u8 {
        return self.run_fn(self.ctx, args);
    }
};

pub const Opts = struct {
    alloc: std.mem.Allocator,
    max_bytes: usize = default_max_bytes,
    tool_mask: u8 = mask_all,
    ask_hook: ?AskHook = null,
};

pub const Runtime = struct {
    alloc: std.mem.Allocator,
    max_bytes: usize,
    tool_mask: u8,
    ask_hook: ?AskHook,
    entries: [8]tools.Entry = undefined,
    selected: [8]tools.Entry = undefined,

    pub fn init(opts: Opts) Runtime {
        return .{
            .alloc = opts.alloc,
            .max_bytes = opts.max_bytes,
            .tool_mask = opts.tool_mask & mask_all,
            .ask_hook = opts.ask_hook,
        };
    }

    pub fn registry(self: *Runtime) tools.Registry {
        self.rebuildEntries();
        return tools.Registry.init(self.activeEntries());
    }

    pub fn deinitResult(self: Runtime, res: tools.Result) void {
        if (!res.out_owned) return;
        for (res.out) |out| {
            if (out.owned) self.alloc.free(out.chunk);
        }
        self.alloc.free(res.out);
    }

    fn rebuildEntries(self: *Runtime) void {
        self.entries = .{
            .{
                .name = "read",
                .kind = .read,
                .spec = .{
                    .kind = .read,
                    .desc = "Read file contents",
                    .params = read_params[0..],
                    .out = .{
                        .max_bytes = @intCast(self.max_bytes),
                        .stream = false,
                    },
                    .timeout_ms = 2000,
                    .destructive = false,
                },
                .dispatch = tools.Dispatch.from(Runtime, self, Runtime.runRead),
            },
            .{
                .name = "write",
                .kind = .write,
                .spec = .{
                    .kind = .write,
                    .desc = "Write file contents",
                    .params = write_params[0..],
                    .out = .{
                        .max_bytes = @intCast(self.max_bytes),
                        .stream = false,
                    },
                    .timeout_ms = 2000,
                    .destructive = true,
                },
                .dispatch = tools.Dispatch.from(Runtime, self, Runtime.runWrite),
            },
            .{
                .name = "bash",
                .kind = .bash,
                .spec = .{
                    .kind = .bash,
                    .desc = "Run bash command",
                    .params = bash_params[0..],
                    .out = .{
                        .max_bytes = @intCast(self.max_bytes),
                        .stream = true,
                    },
                    .timeout_ms = 30000,
                    .destructive = true,
                },
                .dispatch = tools.Dispatch.from(Runtime, self, Runtime.runBash),
            },
            .{
                .name = "edit",
                .kind = .edit,
                .spec = .{
                    .kind = .edit,
                    .desc = "Edit file by string replacement",
                    .params = edit_params[0..],
                    .out = .{
                        .max_bytes = @intCast(self.max_bytes),
                        .stream = false,
                    },
                    .timeout_ms = 2000,
                    .destructive = true,
                },
                .dispatch = tools.Dispatch.from(Runtime, self, Runtime.runEdit),
            },
            .{
                .name = "grep",
                .kind = .grep,
                .spec = .{
                    .kind = .grep,
                    .desc = "Search file contents recursively",
                    .params = grep_params[0..],
                    .out = .{
                        .max_bytes = @intCast(self.max_bytes),
                        .stream = false,
                    },
                    .timeout_ms = 10000,
                    .destructive = false,
                },
                .dispatch = tools.Dispatch.from(Runtime, self, Runtime.runGrep),
            },
            .{
                .name = "find",
                .kind = .find,
                .spec = .{
                    .kind = .find,
                    .desc = "Find files and directories by name",
                    .params = find_params[0..],
                    .out = .{
                        .max_bytes = @intCast(self.max_bytes),
                        .stream = false,
                    },
                    .timeout_ms = 10000,
                    .destructive = false,
                },
                .dispatch = tools.Dispatch.from(Runtime, self, Runtime.runFind),
            },
            .{
                .name = "ls",
                .kind = .ls,
                .spec = .{
                    .kind = .ls,
                    .desc = "List directory entries",
                    .params = ls_params[0..],
                    .out = .{
                        .max_bytes = @intCast(self.max_bytes),
                        .stream = false,
                    },
                    .timeout_ms = 2000,
                    .destructive = false,
                },
                .dispatch = tools.Dispatch.from(Runtime, self, Runtime.runLs),
            },
            .{
                .name = "ask",
                .kind = .ask,
                .spec = .{
                    .kind = .ask,
                    .desc = "Ask one or more questions to collect user decisions",
                    .params = &.{},
                    .schema_json = ask_schema,
                    .out = .{
                        .max_bytes = @intCast(self.max_bytes),
                        .stream = false,
                    },
                    .timeout_ms = 120000,
                    .destructive = false,
                },
                .dispatch = tools.Dispatch.from(Runtime, self, Runtime.runAsk),
            },
        };
    }

    fn activeEntries(self: *Runtime) []const tools.Entry {
        if (self.tool_mask == mask_all) return self.entries[0..];

        var len: usize = 0;
        if ((self.tool_mask & mask_read) != 0) {
            self.selected[len] = self.entries[0];
            len += 1;
        }
        if ((self.tool_mask & mask_write) != 0) {
            self.selected[len] = self.entries[1];
            len += 1;
        }
        if ((self.tool_mask & mask_bash) != 0) {
            self.selected[len] = self.entries[2];
            len += 1;
        }
        if ((self.tool_mask & mask_edit) != 0) {
            self.selected[len] = self.entries[3];
            len += 1;
        }
        if ((self.tool_mask & mask_grep) != 0) {
            self.selected[len] = self.entries[4];
            len += 1;
        }
        if ((self.tool_mask & mask_find) != 0) {
            self.selected[len] = self.entries[5];
            len += 1;
        }
        if ((self.tool_mask & mask_ls) != 0) {
            self.selected[len] = self.entries[6];
            len += 1;
        }
        if ((self.tool_mask & mask_ask) != 0) {
            self.selected[len] = self.entries[7];
            len += 1;
        }
        return self.selected[0..len];
    }

    fn runRead(self: *Runtime, call: tools.Call, sink: tools.Sink) !tools.Result {
        const h = read.Handler.init(.{
            .alloc = self.alloc,
            .max_bytes = self.max_bytes,
            .now_ms = call.at_ms,
        });
        return h.run(call, sink);
    }

    fn runWrite(_: *Runtime, call: tools.Call, sink: tools.Sink) !tools.Result {
        const h = write.Handler.init(.{
            .now_ms = call.at_ms,
        });
        return h.run(call, sink);
    }

    fn runBash(self: *Runtime, call: tools.Call, sink: tools.Sink) !tools.Result {
        const h = bash.Handler.init(.{
            .alloc = self.alloc,
            .max_bytes = self.max_bytes,
            .now_ms = call.at_ms,
        });
        return h.run(call, sink);
    }

    fn runEdit(self: *Runtime, call: tools.Call, sink: tools.Sink) !tools.Result {
        const h = edit.Handler.init(.{
            .alloc = self.alloc,
            .max_bytes = self.max_bytes,
            .now_ms = call.at_ms,
        });
        return h.run(call, sink);
    }

    fn runGrep(self: *Runtime, call: tools.Call, sink: tools.Sink) !tools.Result {
        const h = grep.Handler.init(.{
            .alloc = self.alloc,
            .max_bytes = self.max_bytes,
            .now_ms = call.at_ms,
        });
        return h.run(call, sink);
    }

    fn runFind(self: *Runtime, call: tools.Call, sink: tools.Sink) !tools.Result {
        const h = find.Handler.init(.{
            .alloc = self.alloc,
            .max_bytes = self.max_bytes,
            .now_ms = call.at_ms,
        });
        return h.run(call, sink);
    }

    fn runLs(self: *Runtime, call: tools.Call, sink: tools.Sink) !tools.Result {
        const h = ls.Handler.init(.{
            .alloc = self.alloc,
            .max_bytes = self.max_bytes,
            .now_ms = call.at_ms,
        });
        return h.run(call, sink);
    }

    fn runAsk(self: *Runtime, call: tools.Call, _: tools.Sink) !tools.Result {
        if (call.kind != .ask or std.meta.activeTag(call.args) != .ask) return error.InvalidArgs;
        if (call.args.ask.questions.len == 0) {
            return .{
                .call_id = call.id,
                .started_at_ms = call.at_ms,
                .ended_at_ms = call.at_ms,
                .out = &.{},
                .final = .{ .failed = .{
                    .kind = .invalid_args,
                    .msg = "ask tool requires at least one question",
                } },
            };
        }

        const hook = self.ask_hook orelse {
            return .{
                .call_id = call.id,
                .started_at_ms = call.at_ms,
                .ended_at_ms = call.at_ms,
                .out = &.{},
                .final = .{ .failed = .{
                    .kind = .invalid_args,
                    .msg = "ask tool requires interactive TUI mode",
                } },
            };
        };

        const out_text = hook.run(call.args.ask) catch |err| {
            return .{
                .call_id = call.id,
                .started_at_ms = call.at_ms,
                .ended_at_ms = call.at_ms,
                .out = &.{},
                .final = .{ .failed = .{
                    .kind = .io,
                    .msg = @errorName(err),
                } },
            };
        };
        errdefer self.alloc.free(out_text);

        const out = try self.alloc.alloc(tools.Output, 1);
        out[0] = .{
            .call_id = call.id,
            .seq = 0,
            .at_ms = call.at_ms,
            .stream = .stdout,
            .chunk = out_text,
            .owned = true,
            .truncated = false,
        };
        return .{
            .call_id = call.id,
            .started_at_ms = call.at_ms,
            .ended_at_ms = call.at_ms,
            .out = out,
            .out_owned = true,
            .final = .{ .ok = .{ .code = 0 } },
        };
    }
};

pub fn maskForName(name: []const u8) ?u8 {
    const map = std.StaticStringMap(u8).initComptime(.{
        .{ "read", mask_read },
        .{ "write", mask_write },
        .{ "bash", mask_bash },
        .{ "edit", mask_edit },
        .{ "grep", mask_grep },
        .{ "find", mask_find },
        .{ "ls", mask_ls },
        .{ "ask", mask_ask },
    });
    return map.get(name);
}

test "builtin runtime registry exposes all core tools" {
    var rt = Runtime.init(.{
        .alloc = std.testing.allocator,
    });
    const reg = rt.registry();

    try std.testing.expect(reg.byName("read") != null);
    try std.testing.expect(reg.byName("write") != null);
    try std.testing.expect(reg.byName("bash") != null);
    try std.testing.expect(reg.byName("edit") != null);
    try std.testing.expect(reg.byName("grep") != null);
    try std.testing.expect(reg.byName("find") != null);
    try std.testing.expect(reg.byName("ls") != null);
    try std.testing.expect(reg.byName("ask") != null);

    try std.testing.expect(reg.byKind(.read) != null);
    try std.testing.expect(reg.byKind(.write) != null);
    try std.testing.expect(reg.byKind(.bash) != null);
    try std.testing.expect(reg.byKind(.edit) != null);
    try std.testing.expect(reg.byKind(.grep) != null);
    try std.testing.expect(reg.byKind(.find) != null);
    try std.testing.expect(reg.byKind(.ls) != null);
    try std.testing.expect(reg.byKind(.ask) != null);
}

test "builtin runtime uses call timestamp in result envelope" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "in.txt",
        .data = "abc\n",
    });
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "in.txt");
    defer std.testing.allocator.free(path);

    var rt = Runtime.init(.{
        .alloc = std.testing.allocator,
        .max_bytes = 1024,
    });
    const reg = rt.registry();
    const SinkImpl = struct {
        fn push(_: *@This(), _: tools.Event) !void {}
    };
    var sink_impl = SinkImpl{};
    const sink = tools.Sink.from(SinkImpl, &sink_impl, SinkImpl.push);

    const call: tools.Call = .{
        .id = "t1",
        .kind = .read,
        .args = .{ .read = .{
            .path = path,
        } },
        .src = .system,
        .at_ms = 12345,
    };

    const res = try reg.run("read", call, sink);
    defer rt.deinitResult(res);

    try std.testing.expectEqual(@as(i64, 12345), res.started_at_ms);
    try std.testing.expectEqual(@as(i64, 12345), res.ended_at_ms);
    try std.testing.expectEqual(@as(usize, 1), res.out.len);
    try std.testing.expectEqual(@as(i64, 12345), res.out[0].at_ms);
}

test "builtin runtime supports deterministic tool mask filtering" {
    var rt = Runtime.init(.{
        .alloc = std.testing.allocator,
        .tool_mask = mask_read | mask_bash,
    });
    const reg = rt.registry();

    try std.testing.expectEqual(@as(usize, 2), reg.entries.len);
    try std.testing.expectEqualStrings("read", reg.entries[0].name);
    try std.testing.expectEqualStrings("bash", reg.entries[1].name);
    try std.testing.expect(reg.byName("write") == null);
}

test "ask tool requires interactive hook" {
    var rt = Runtime.init(.{
        .alloc = std.testing.allocator,
        .tool_mask = mask_ask,
    });
    const reg = rt.registry();

    const SinkImpl = struct {
        fn push(_: *@This(), _: tools.Event) !void {}
    };
    var sink_impl = SinkImpl{};
    const sink = tools.Sink.from(SinkImpl, &sink_impl, SinkImpl.push);

    const opts = [_]tools.Call.AskArgs.Option{
        .{ .label = "A" },
        .{ .label = "B" },
    };
    const qs = [_]tools.Call.AskArgs.Question{
        .{
            .id = "scope",
            .question = "Pick one",
            .options = opts[0..],
        },
    };
    const call: tools.Call = .{
        .id = "ask-1",
        .kind = .ask,
        .args = .{ .ask = .{ .questions = qs[0..] } },
        .src = .model,
        .at_ms = 1,
    };

    const res = try reg.run("ask", call, sink);
    defer rt.deinitResult(res);
    switch (res.final) {
        .failed => |f| try std.testing.expectEqualStrings("ask tool requires interactive TUI mode", f.msg),
        else => return error.TestUnexpectedResult,
    }
}

test "ask tool rejects empty question list" {
    var rt = Runtime.init(.{
        .alloc = std.testing.allocator,
        .tool_mask = mask_ask,
    });
    const reg = rt.registry();

    const SinkImpl = struct {
        fn push(_: *@This(), _: tools.Event) !void {}
    };
    var sink_impl = SinkImpl{};
    const sink = tools.Sink.from(SinkImpl, &sink_impl, SinkImpl.push);

    const call: tools.Call = .{
        .id = "ask-empty",
        .kind = .ask,
        .args = .{ .ask = .{ .questions = &.{} } },
        .src = .model,
        .at_ms = 7,
    };
    const res = try reg.run("ask", call, sink);
    defer rt.deinitResult(res);
    switch (res.final) {
        .failed => |f| try std.testing.expectEqualStrings("ask tool requires at least one question", f.msg),
        else => return error.TestUnexpectedResult,
    }
}

test "ask tool uses hook output" {
    const AskImpl = struct {
        alloc: std.mem.Allocator,
        seen: usize = 0,

        fn run(self: *@This(), args: tools.Call.AskArgs) ![]u8 {
            self.seen += args.questions.len;
            return self.alloc.dupe(u8, "{\"cancelled\":false,\"answers\":[{\"id\":\"scope\",\"answer\":\"A\",\"index\":0}]}");
        }
    };

    var impl = AskImpl{ .alloc = std.testing.allocator };
    var rt = Runtime.init(.{
        .alloc = std.testing.allocator,
        .tool_mask = mask_ask,
        .ask_hook = AskHook.from(AskImpl, &impl, AskImpl.run),
    });
    const reg = rt.registry();

    const SinkImpl = struct {
        fn push(_: *@This(), _: tools.Event) !void {}
    };
    var sink_impl = SinkImpl{};
    const sink = tools.Sink.from(SinkImpl, &sink_impl, SinkImpl.push);

    const opts = [_]tools.Call.AskArgs.Option{
        .{ .label = "A" },
        .{ .label = "B" },
    };
    const qs = [_]tools.Call.AskArgs.Question{
        .{
            .id = "scope",
            .question = "Pick one",
            .options = opts[0..],
        },
    };
    const call: tools.Call = .{
        .id = "ask-2",
        .kind = .ask,
        .args = .{ .ask = .{ .questions = qs[0..] } },
        .src = .model,
        .at_ms = 2,
    };

    const res = try reg.run("ask", call, sink);
    defer rt.deinitResult(res);
    switch (res.final) {
        .ok => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 1), impl.seen);
    try std.testing.expectEqual(@as(usize, 1), res.out.len);
    try std.testing.expectEqualStrings(
        "{\"cancelled\":false,\"answers\":[{\"id\":\"scope\",\"answer\":\"A\",\"index\":0}]}",
        res.out[0].chunk,
    );
}

test "ask tool reports hook failure" {
    const AskImpl = struct {
        fn run(_: *@This(), _: tools.Call.AskArgs) ![]u8 {
            return error.BadInput;
        }
    };

    var impl = AskImpl{};
    var rt = Runtime.init(.{
        .alloc = std.testing.allocator,
        .tool_mask = mask_ask,
        .ask_hook = AskHook.from(AskImpl, &impl, AskImpl.run),
    });
    const reg = rt.registry();

    const SinkImpl = struct {
        fn push(_: *@This(), _: tools.Event) !void {}
    };
    var sink_impl = SinkImpl{};
    const sink = tools.Sink.from(SinkImpl, &sink_impl, SinkImpl.push);

    const opts = [_]tools.Call.AskArgs.Option{
        .{ .label = "A" },
        .{ .label = "B" },
    };
    const qs = [_]tools.Call.AskArgs.Question{
        .{
            .id = "scope",
            .question = "Pick one",
            .options = opts[0..],
        },
    };
    const call: tools.Call = .{
        .id = "ask-fail",
        .kind = .ask,
        .args = .{ .ask = .{ .questions = qs[0..] } },
        .src = .model,
        .at_ms = 8,
    };
    const res = try reg.run("ask", call, sink);
    defer rt.deinitResult(res);
    switch (res.final) {
        .failed => |f| try std.testing.expectEqualStrings("BadInput", f.msg),
        else => return error.TestUnexpectedResult,
    }
}

test "maskForName validates builtin tool names" {
    try std.testing.expect(maskForName("read") != null);
    try std.testing.expect(maskForName("write") != null);
    try std.testing.expect(maskForName("bash") != null);
    try std.testing.expect(maskForName("edit") != null);
    try std.testing.expect(maskForName("grep") != null);
    try std.testing.expect(maskForName("find") != null);
    try std.testing.expect(maskForName("ls") != null);
    try std.testing.expect(maskForName("ask") != null);
    try std.testing.expect(maskForName("wat") == null);
}
