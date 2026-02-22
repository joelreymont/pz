const std = @import("std");
const core = @import("../../core/mod.zig");

const ToolCallOut = struct {
    id: []const u8,
    name: []const u8,
    args: []const u8,
};

const ToolResultOut = struct {
    id: []const u8,
    out: []const u8,
    is_err: bool,
};

pub const Formatter = struct {
    alloc: std.mem.Allocator,
    out: std.Io.AnyWriter,
    verbose: bool = false,
    text_seen: bool = false,
    text_ended_nl: bool = false,
    thinking: std.ArrayListUnmanaged([]const u8) = .{},
    tool_calls: std.ArrayListUnmanaged(ToolCallOut) = .{},
    tool_results: std.ArrayListUnmanaged(ToolResultOut) = .{},
    errs: std.ArrayListUnmanaged([]const u8) = .{},
    usage: ?core.providers.Usage = null,
    stop: ?core.providers.StopReason = null,

    pub fn init(alloc: std.mem.Allocator, out: std.Io.AnyWriter) Formatter {
        return .{
            .alloc = alloc,
            .out = out,
        };
    }

    pub fn deinit(self: *Formatter) void {
        for (self.thinking.items) |text| self.alloc.free(text);
        self.thinking.deinit(self.alloc);

        for (self.tool_calls.items) |tc| {
            self.alloc.free(tc.id);
            self.alloc.free(tc.name);
            self.alloc.free(tc.args);
        }
        self.tool_calls.deinit(self.alloc);

        for (self.tool_results.items) |tr| {
            self.alloc.free(tr.id);
            self.alloc.free(tr.out);
        }
        self.tool_results.deinit(self.alloc);

        for (self.errs.items) |text| self.alloc.free(text);
        self.errs.deinit(self.alloc);
    }

    pub fn push(self: *Formatter, ev: core.providers.Ev) !void {
        switch (ev) {
            .text => |text| try self.pushText(text),
            .thinking => |text| try self.pushThinking(text),
            .tool_call => |tc| try self.pushToolCall(tc),
            .tool_result => |tr| try self.pushToolResult(tr),
            .usage => |usage| self.pushUsage(usage),
            .stop => |stop| self.pushStop(stop.reason),
            .err => |text| try self.pushErr(text),
        }
    }

    pub fn finish(self: *Formatter) !void {
        if (!self.verbose) {
            // Errors always shown even in non-verbose mode
            for (self.errs.items) |text| {
                try self.out.writeAll("err ");
                try writeQuoted(self.out, text);
                try self.out.writeByte('\n');
            }
            if (self.text_seen and !self.text_ended_nl) {
                try self.out.writeByte('\n');
            }
            return;
        }

        self.sortMeta();
        if (!self.hasMeta()) return;

        if (self.text_seen and !self.text_ended_nl) {
            try self.out.writeByte('\n');
        }

        for (self.thinking.items) |text| {
            try self.out.writeAll("thinking ");
            try writeQuoted(self.out, text);
            try self.out.writeByte('\n');
        }

        for (self.tool_calls.items) |tc| {
            try self.out.writeAll("tool_call id=");
            try writeQuoted(self.out, tc.id);
            try self.out.writeAll(" name=");
            try writeQuoted(self.out, tc.name);
            try self.out.writeAll(" args=");
            try writeQuoted(self.out, tc.args);
            try self.out.writeByte('\n');
        }

        for (self.tool_results.items) |tr| {
            try self.out.writeAll("tool_result id=");
            try writeQuoted(self.out, tr.id);
            try self.out.writeAll(" is_err=");
            try self.out.writeAll(if (tr.is_err) "true" else "false");
            try self.out.writeAll(" out=");
            try writeQuoted(self.out, tr.out);
            try self.out.writeByte('\n');
        }

        if (self.usage) |usage| {
            try self.out.print("usage in={d} out={d} total={d}\n", .{
                usage.in_tok,
                usage.out_tok,
                usage.tot_tok,
            });
        }

        if (self.stop) |reason| {
            try self.out.writeAll("stop reason=");
            try self.out.writeAll(stopName(reason));
            try self.out.writeByte('\n');
        }

        for (self.errs.items) |text| {
            try self.out.writeAll("err ");
            try writeQuoted(self.out, text);
            try self.out.writeByte('\n');
        }
    }

    fn pushText(self: *Formatter, text: []const u8) !void {
        if (text.len == 0) return;
        self.text_seen = true;
        self.text_ended_nl = text[text.len - 1] == '\n';
        try self.out.writeAll(text);
    }

    fn pushThinking(self: *Formatter, text: []const u8) !void {
        const dup = try self.alloc.dupe(u8, text);
        errdefer self.alloc.free(dup);
        try self.thinking.append(self.alloc, dup);
    }

    fn pushToolCall(self: *Formatter, tc: core.providers.ToolCall) !void {
        const id = try self.alloc.dupe(u8, tc.id);
        errdefer self.alloc.free(id);

        const name = try self.alloc.dupe(u8, tc.name);
        errdefer self.alloc.free(name);

        const args = try self.alloc.dupe(u8, tc.args);
        errdefer self.alloc.free(args);

        try self.tool_calls.append(self.alloc, .{
            .id = id,
            .name = name,
            .args = args,
        });
    }

    fn pushToolResult(self: *Formatter, tr: core.providers.ToolResult) !void {
        const id = try self.alloc.dupe(u8, tr.id);
        errdefer self.alloc.free(id);

        const out = try self.alloc.dupe(u8, tr.out);
        errdefer self.alloc.free(out);

        try self.tool_results.append(self.alloc, .{
            .id = id,
            .out = out,
            .is_err = tr.is_err,
        });
    }

    fn pushUsage(self: *Formatter, usage: core.providers.Usage) void {
        if (self.usage == null or usageLessThan(self.usage.?, usage)) {
            self.usage = usage;
        }
    }

    fn pushStop(self: *Formatter, reason: core.providers.StopReason) void {
        if (self.stop == null or stopRank(self.stop.?) < stopRank(reason)) {
            self.stop = reason;
        }
    }

    fn pushErr(self: *Formatter, text: []const u8) !void {
        const dup = try self.alloc.dupe(u8, text);
        errdefer self.alloc.free(dup);
        try self.errs.append(self.alloc, dup);
    }

    fn hasMeta(self: *const Formatter) bool {
        return self.thinking.items.len > 0 or
            self.tool_calls.items.len > 0 or
            self.tool_results.items.len > 0 or
            self.usage != null or
            self.stop != null or
            self.errs.items.len > 0;
    }

    fn sortMeta(self: *Formatter) void {
        std.sort.insertion([]const u8, self.thinking.items, {}, lessText);
        std.sort.insertion(ToolCallOut, self.tool_calls.items, {}, lessToolCall);
        std.sort.insertion(ToolResultOut, self.tool_results.items, {}, lessToolResult);
        std.sort.insertion([]const u8, self.errs.items, {}, lessText);
    }

    fn lessText(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.order(u8, a, b) == .lt;
    }

    fn lessToolCall(_: void, a: ToolCallOut, b: ToolCallOut) bool {
        return cmp3(a.id, b.id, a.name, b.name, a.args, b.args) == .lt;
    }

    fn lessToolResult(_: void, a: ToolResultOut, b: ToolResultOut) bool {
        const ord_id = std.mem.order(u8, a.id, b.id);
        if (ord_id != .eq) return ord_id == .lt;

        if (a.is_err != b.is_err) return !a.is_err;

        return std.mem.order(u8, a.out, b.out) == .lt;
    }
};

fn cmp3(a0: []const u8, b0: []const u8, a1: []const u8, b1: []const u8, a2: []const u8, b2: []const u8) std.math.Order {
    const ord0 = std.mem.order(u8, a0, b0);
    if (ord0 != .eq) return ord0;

    const ord1 = std.mem.order(u8, a1, b1);
    if (ord1 != .eq) return ord1;

    return std.mem.order(u8, a2, b2);
}

fn usageLessThan(curr: core.providers.Usage, next: core.providers.Usage) bool {
    if (curr.tot_tok != next.tot_tok) return curr.tot_tok < next.tot_tok;
    if (curr.out_tok != next.out_tok) return curr.out_tok < next.out_tok;
    return curr.in_tok < next.in_tok;
}

fn stopRank(reason: core.providers.StopReason) u8 {
    return switch (reason) {
        .done => 0,
        .tool => 1,
        .max_out => 2,
        .canceled => 3,
        .err => 4,
    };
}

fn stopName(reason: core.providers.StopReason) []const u8 {
    return switch (reason) {
        .done => "done",
        .max_out => "max_out",
        .tool => "tool",
        .canceled => "canceled",
        .err => "err",
    };
}

fn writeQuoted(out: std.Io.AnyWriter, raw: []const u8) !void {
    try out.writeByte('"');
    for (raw) |ch| {
        switch (ch) {
            '"' => try out.writeAll("\\\""),
            '\\' => try out.writeAll("\\\\"),
            '\n' => try out.writeAll("\\n"),
            '\r' => try out.writeAll("\\r"),
            '\t' => try out.writeAll("\\t"),
            else => {
                if (ch < 0x20) {
                    try out.writeAll("\\u00");
                    try out.writeByte(hexNibble(ch >> 4));
                    try out.writeByte(hexNibble(ch & 0x0f));
                } else {
                    try out.writeByte(ch);
                }
            },
        }
    }
    try out.writeByte('"');
}

fn hexNibble(n: u8) u8 {
    return "0123456789abcdef"[n];
}

fn expectFormatted(evs: []const core.providers.Ev, want: []const u8) !void {
    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var formatter = Formatter.init(std.testing.allocator, fbs.writer().any());
    formatter.verbose = true; // tests check full diagnostic output
    defer formatter.deinit();

    for (evs) |ev| try formatter.push(ev);
    try formatter.finish();

    try std.testing.expectEqualStrings(want, fbs.getWritten());
}

test "formatter emits deterministic canonical output" {
    const evs_a = [_]core.providers.Ev{
        .{ .text = "out-a" },
        .{ .thinking = "z-think" },
        .{ .tool_result = .{ .id = "call-2", .out = "res-z", .is_err = true } },
        .{ .tool_call = .{ .id = "call-2", .name = "write", .args = "{\"path\":\"b\"}" } },
        .{ .usage = .{ .in_tok = 2, .out_tok = 3, .tot_tok = 5 } },
        .{ .err = "z-err" },
        .{ .stop = .{ .reason = .done } },
        .{ .tool_call = .{ .id = "call-1", .name = "read", .args = "{\"path\":\"a\"}" } },
        .{ .thinking = "a-think" },
        .{ .tool_result = .{ .id = "call-1", .out = "res-a", .is_err = false } },
        .{ .usage = .{ .in_tok = 1, .out_tok = 1, .tot_tok = 2 } },
        .{ .err = "a-err" },
        .{ .stop = .{ .reason = .err } },
    };

    const evs_b = [_]core.providers.Ev{
        .{ .err = "a-err" },
        .{ .stop = .{ .reason = .err } },
        .{ .tool_result = .{ .id = "call-1", .out = "res-a", .is_err = false } },
        .{ .thinking = "a-think" },
        .{ .tool_call = .{ .id = "call-1", .name = "read", .args = "{\"path\":\"a\"}" } },
        .{ .err = "z-err" },
        .{ .usage = .{ .in_tok = 1, .out_tok = 1, .tot_tok = 2 } },
        .{ .tool_call = .{ .id = "call-2", .name = "write", .args = "{\"path\":\"b\"}" } },
        .{ .text = "out-a" },
        .{ .stop = .{ .reason = .done } },
        .{ .tool_result = .{ .id = "call-2", .out = "res-z", .is_err = true } },
        .{ .thinking = "z-think" },
        .{ .usage = .{ .in_tok = 2, .out_tok = 3, .tot_tok = 5 } },
    };

    const want =
        "out-a\n" ++
        "thinking \"a-think\"\n" ++
        "thinking \"z-think\"\n" ++
        "tool_call id=\"call-1\" name=\"read\" args=\"{\\\"path\\\":\\\"a\\\"}\"\n" ++
        "tool_call id=\"call-2\" name=\"write\" args=\"{\\\"path\\\":\\\"b\\\"}\"\n" ++
        "tool_result id=\"call-1\" is_err=false out=\"res-a\"\n" ++
        "tool_result id=\"call-2\" is_err=true out=\"res-z\"\n" ++
        "usage in=2 out=3 total=5\n" ++
        "stop reason=err\n" ++
        "err \"a-err\"\n" ++
        "err \"z-err\"\n";

    try expectFormatted(evs_a[0..], want);
    try expectFormatted(evs_b[0..], want);
}

test "formatter preserves plain text output when metadata is absent" {
    const evs = [_]core.providers.Ev{
        .{ .text = "out-" },
        .{ .text = "a" },
    };
    try expectFormatted(evs[0..], "out-a");
}

test "formatter escapes control characters in quoted fields" {
    const evs = [_]core.providers.Ev{
        .{ .err = "a\tb\n\"c\"\\d\x01" },
    };

    try expectFormatted(evs[0..], "err \"a\\tb\\n\\\"c\\\"\\\\d\\u0001\"\n");
}
