const std = @import("std");
const providers = @import("contract.zig");
const types = @import("types.zig");

pub const Err = types.Err;

pub const Parser = struct {
    buf: std.ArrayListUnmanaged(u8) = .{},
    saw_stop: bool = false,

    pub fn deinit(self: *Parser, alloc: std.mem.Allocator) void {
        self.buf.deinit(alloc);
    }

    pub fn feed(
        self: *Parser,
        alloc: std.mem.Allocator,
        evs: *std.ArrayListUnmanaged(providers.Ev),
        chunk: []const u8,
    ) Err!void {
        self.buf.appendSlice(alloc, chunk) catch return error.OutOfMemory;

        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, self.buf.items, start, '\n')) |nl| {
            const line = trimCr(self.buf.items[start..nl]);
            if (line.len > 0) {
                try parseLine(alloc, evs, line, &self.saw_stop);
            }
            start = nl + 1;
        }

        if (start == 0) return;
        const rem = self.buf.items[start..];
        std.mem.copyForwards(u8, self.buf.items[0..rem.len], rem);
        self.buf.items.len = rem.len;
    }

    pub fn finish(
        self: *Parser,
        alloc: std.mem.Allocator,
        evs: *std.ArrayListUnmanaged(providers.Ev),
    ) Err!void {
        if (self.buf.items.len > 0) {
            const line = trimCr(self.buf.items);
            if (line.len > 0) {
                try parseLine(alloc, evs, line, &self.saw_stop);
            }
            self.buf.items.len = 0;
        }

        if (!self.saw_stop) return error.MissingStop;
    }
};

fn trimCr(raw: []const u8) []const u8 {
    if (raw.len > 0 and raw[raw.len - 1] == '\r') return raw[0 .. raw.len - 1];
    return raw;
}

fn parseLine(
    alloc: std.mem.Allocator,
    evs: *std.ArrayListUnmanaged(providers.Ev),
    line: []const u8,
    saw_stop: *bool,
) Err!void {
    const sep = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadFrame;
    const tag = line[0..sep];
    const val = line[sep + 1 ..];

    if (std.mem.eql(u8, tag, "text")) {
        try appendEv(alloc, evs, .{ .text = try dup(alloc, val) });
        return;
    }
    if (std.mem.eql(u8, tag, "thinking")) {
        try appendEv(alloc, evs, .{ .thinking = try dup(alloc, val) });
        return;
    }
    if (std.mem.eql(u8, tag, "tool_call")) {
        const parts = try split3(val, '|');
        try appendEv(alloc, evs, .{
            .tool_call = .{
                .id = try dup(alloc, parts[0]),
                .name = try dup(alloc, parts[1]),
                .args = try dup(alloc, parts[2]),
            },
        });
        return;
    }
    if (std.mem.eql(u8, tag, "tool_result")) {
        const parts = try split3(val, '|');
        try appendEv(alloc, evs, .{
            .tool_result = .{
                .id = try dup(alloc, parts[0]),
                .out = try dup(alloc, parts[2]),
                .is_err = try parseBool(parts[1]),
            },
        });
        return;
    }
    if (std.mem.eql(u8, tag, "usage")) {
        try appendEv(alloc, evs, .{ .usage = try parseUsage(val) });
        return;
    }
    if (std.mem.eql(u8, tag, "stop")) {
        saw_stop.* = true;
        try appendEv(alloc, evs, .{ .stop = .{ .reason = try parseStop(val) } });
        return;
    }
    if (std.mem.eql(u8, tag, "err")) {
        try appendEv(alloc, evs, .{ .err = try dup(alloc, val) });
        return;
    }

    return error.UnknownTag;
}

fn appendEv(
    alloc: std.mem.Allocator,
    evs: *std.ArrayListUnmanaged(providers.Ev),
    ev: providers.Ev,
) Err!void {
    evs.append(alloc, ev) catch return error.OutOfMemory;
}

fn split3(raw: []const u8, sep: u8) Err![3][]const u8 {
    var out: [3][]const u8 = undefined;
    var idx: usize = 0;
    var from: usize = 0;
    while (idx < 2) : (idx += 1) {
        const at = std.mem.indexOfScalarPos(u8, raw, from, sep) orelse return error.BadFrame;
        out[idx] = raw[from..at];
        from = at + 1;
    }
    if (from > raw.len) return error.BadFrame;
    out[2] = raw[from..];
    return out;
}

fn parseBool(raw: []const u8) Err!bool {
    if (std.mem.eql(u8, raw, "0")) return false;
    if (std.mem.eql(u8, raw, "1")) return true;
    return error.BadFrame;
}

fn parseUsage(raw: []const u8) Err!providers.Usage {
    const parts = try split3(raw, ',');
    return .{
        .in_tok = try parseU64(parts[0]),
        .out_tok = try parseU64(parts[1]),
        .tot_tok = try parseU64(parts[2]),
    };
}

fn parseU64(raw: []const u8) Err!u64 {
    return std.fmt.parseUnsigned(u64, raw, 10) catch return error.InvalidUsage;
}

fn parseStop(raw: []const u8) Err!providers.StopReason {
    if (std.mem.eql(u8, raw, "done")) return .done;
    if (std.mem.eql(u8, raw, "max_out")) return .max_out;
    if (std.mem.eql(u8, raw, "tool")) return .tool;
    if (std.mem.eql(u8, raw, "canceled")) return .canceled;
    if (std.mem.eql(u8, raw, "err")) return .err;
    return error.UnknownStop;
}

fn dup(alloc: std.mem.Allocator, raw: []const u8) Err![]const u8 {
    return alloc.dupe(u8, raw) catch return error.OutOfMemory;
}

const ParseRes = struct {
    arena: std.heap.ArenaAllocator,
    evs: []providers.Ev,

    fn deinit(self: *ParseRes) void {
        self.arena.deinit();
    }
};

fn parseChunks(alloc: std.mem.Allocator, chunks: []const []const u8) Err!ParseRes {
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();

    const ar = arena.allocator();

    var p = Parser{};
    defer p.deinit(ar);

    var evs: std.ArrayListUnmanaged(providers.Ev) = .{};
    errdefer evs.deinit(ar);

    for (chunks) |chunk| {
        try p.feed(ar, &evs, chunk);
    }
    try p.finish(ar, &evs);

    return .{
        .arena = arena,
        .evs = evs.toOwnedSlice(ar) catch return error.OutOfMemory,
    };
}

test "parser normalizes chunked frames and preserves order" {
    const chunks = [_][]const u8{
        "text:he",
        "llo\r\nthinking:plan\n",
        "tool_call:id-1|read|{\"path\":\"a\"}\n",
        "stop:done\n",
    };

    var out = try parseChunks(std.testing.allocator, chunks[0..]);
    defer out.deinit();

    try std.testing.expectEqual(@as(usize, 4), out.evs.len);

    switch (out.evs[0]) {
        .text => |txt| try std.testing.expectEqualStrings("hello", txt),
        else => return error.TestUnexpectedResult,
    }
    switch (out.evs[1]) {
        .thinking => |txt| try std.testing.expectEqualStrings("plan", txt),
        else => return error.TestUnexpectedResult,
    }
    switch (out.evs[2]) {
        .tool_call => |tc| {
            try std.testing.expectEqualStrings("id-1", tc.id);
            try std.testing.expectEqualStrings("read", tc.name);
            try std.testing.expectEqualStrings("{\"path\":\"a\"}", tc.args);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (out.evs[3]) {
        .stop => |stop| try std.testing.expect(stop.reason == .done),
        else => return error.TestUnexpectedResult,
    }
}

test "parser handles tool_result usage and err frames" {
    const chunks = [_][]const u8{
        "tool_result:call-7|1|stderr\nusage:3,5,8\nerr:oops\nstop:err",
    };

    var out = try parseChunks(std.testing.allocator, chunks[0..]);
    defer out.deinit();

    try std.testing.expectEqual(@as(usize, 4), out.evs.len);

    switch (out.evs[0]) {
        .tool_result => |res| {
            try std.testing.expectEqualStrings("call-7", res.id);
            try std.testing.expect(res.is_err);
            try std.testing.expectEqualStrings("stderr", res.out);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (out.evs[1]) {
        .usage => |usage| {
            try std.testing.expectEqual(@as(u64, 3), usage.in_tok);
            try std.testing.expectEqual(@as(u64, 5), usage.out_tok);
            try std.testing.expectEqual(@as(u64, 8), usage.tot_tok);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (out.evs[2]) {
        .err => |txt| try std.testing.expectEqualStrings("oops", txt),
        else => return error.TestUnexpectedResult,
    }
    switch (out.evs[3]) {
        .stop => |stop| try std.testing.expect(stop.reason == .err),
        else => return error.TestUnexpectedResult,
    }
}

test "parser rejects malformed frames and missing stop" {
    const bad_chunks = [_][]const u8{"bad-frame\n"};
    try std.testing.expectError(error.BadFrame, parseChunks(std.testing.allocator, bad_chunks[0..]));

    const no_stop = [_][]const u8{"text:ok\n"};
    try std.testing.expectError(error.MissingStop, parseChunks(std.testing.allocator, no_stop[0..]));

    const bad_usage = [_][]const u8{"usage:1,2,nope\nstop:done\n"};
    try std.testing.expectError(error.InvalidUsage, parseChunks(std.testing.allocator, bad_usage[0..]));
}

fn splitWithSeed(alloc: std.mem.Allocator, raw: []const u8, seed: u64) ![][]const u8 {
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();

    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer out.deinit(alloc);

    var at: usize = 0;
    while (at < raw.len) {
        const rem = raw.len - at;
        const n = rnd.intRangeAtMost(usize, 1, @min(rem, 7));
        try out.append(alloc, raw[at .. at + n]);
        at += n;
    }
    return try out.toOwnedSlice(alloc);
}

fn eventJson(alloc: std.mem.Allocator, ev: providers.Ev) ![]u8 {
    return std.json.Stringify.valueAlloc(alloc, ev, .{});
}

test "parser property random chunk boundaries preserve parsed stream" {
    const payload =
        \\text:alpha
        \\thinking:beta
        \\tool_call:id-1|read|{"path":"a.txt"}
        \\tool_result:id-1|0|ok
        \\usage:3,5,8
        \\err:oops
        \\stop:done
        \\
    ;

    const base_chunks = [_][]const u8{payload};
    var baseline = try parseChunks(std.testing.allocator, base_chunks[0..]);
    defer baseline.deinit();

    var seed: u64 = 1;
    while (seed <= 96) : (seed += 1) {
        const chunks = try splitWithSeed(std.testing.allocator, payload, seed);
        defer std.testing.allocator.free(chunks);

        var out = try parseChunks(std.testing.allocator, chunks);
        defer out.deinit();

        try std.testing.expectEqual(baseline.evs.len, out.evs.len);
        for (baseline.evs, out.evs) |lhs, rhs| {
            const lhs_json = try eventJson(std.testing.allocator, lhs);
            defer std.testing.allocator.free(lhs_json);
            const rhs_json = try eventJson(std.testing.allocator, rhs);
            defer std.testing.allocator.free(rhs_json);
            try std.testing.expectEqualStrings(lhs_json, rhs_json);
        }
    }
}
