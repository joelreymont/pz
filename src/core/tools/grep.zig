const std = @import("std");
const tools = @import("mod.zig");

pub const Err = error{
    KindMismatch,
    InvalidArgs,
    NotFound,
    Denied,
    TooLarge,
    Io,
    OutOfMemory,
};

pub const Opts = struct {
    alloc: std.mem.Allocator,
    max_bytes: usize,
    now_ms: i64 = 0,
};

pub const Handler = struct {
    alloc: std.mem.Allocator,
    max_bytes: usize,
    now_ms: i64,

    pub fn init(opts: Opts) Handler {
        return .{
            .alloc = opts.alloc,
            .max_bytes = opts.max_bytes,
            .now_ms = opts.now_ms,
        };
    }

    pub fn run(self: Handler, call: tools.Call, _: tools.Sink) Err!tools.Result {
        if (call.kind != .grep) return error.KindMismatch;
        if (std.meta.activeTag(call.args) != .grep) return error.KindMismatch;

        const args = call.args.grep;
        if (args.path.len == 0) return error.InvalidArgs;
        if (args.pattern.len == 0) return error.InvalidArgs;
        if (args.max_results == 0) return error.InvalidArgs;

        var root = std.fs.cwd().openDir(args.path, .{ .iterate = true }) catch |open_err| {
            return mapFsErr(open_err);
        };
        defer root.close();

        var walk = root.walk(self.alloc) catch |walk_err| {
            return mapFsErr(walk_err);
        };
        defer walk.deinit();

        var acc = Acc.init(self.alloc, self.max_bytes);
        defer acc.deinit();

        var hit_ct: u32 = 0;
        while (walk.next() catch |next_err| return mapFsErr(next_err)) |ent| {
            if (hit_ct >= args.max_results) break;
            if (ent.kind != .file) continue;
            try grepFile(self, &root, ent.path, args, &hit_ct, &acc);
        }

        const data = acc.takeOwned() catch return error.OutOfMemory;
        errdefer self.alloc.free(data);

        const meta = tools.output.metaFor(self.max_bytes, acc.full_bytes);
        var meta_chunk: ?[]u8 = null;
        if (meta) |m| {
            meta_chunk = tools.output.metaJsonAlloc(self.alloc, .stdout, m) catch return error.OutOfMemory;
        }
        errdefer if (meta_chunk) |chunk| self.alloc.free(chunk);

        const out_len: usize = 1 + @as(usize, @intFromBool(meta_chunk != null));
        const out = self.alloc.alloc(tools.Output, out_len) catch return error.OutOfMemory;
        errdefer self.alloc.free(out);

        out[0] = .{
            .call_id = call.id,
            .seq = 0,
            .at_ms = self.now_ms,
            .stream = .stdout,
            .chunk = data,
            .owned = true,
            .truncated = meta != null,
        };

        if (meta_chunk) |chunk| {
            out[1] = .{
                .call_id = call.id,
                .seq = 1,
                .at_ms = self.now_ms,
                .stream = .meta,
                .chunk = chunk,
                .owned = true,
                .truncated = false,
            };
            meta_chunk = null;
        }

        return .{
            .call_id = call.id,
            .started_at_ms = self.now_ms,
            .ended_at_ms = self.now_ms,
            .out = out,
            .out_owned = true,
            .final = .{ .ok = .{ .code = 0 } },
        };
    }

    pub fn deinitResult(self: Handler, res: tools.Result) void {
        if (!res.out_owned) return;
        for (res.out) |out| {
            if (out.owned) self.alloc.free(out.chunk);
        }
        self.alloc.free(res.out);
    }
};

fn grepFile(
    self: Handler,
    root: *const std.fs.Dir,
    rel_path: []const u8,
    args: tools.Call.GrepArgs,
    hit_ct: *u32,
    acc: *Acc,
) Err!void {
    var file = root.openFile(rel_path, .{ .mode = .read_only }) catch |open_err| {
        return mapFsErr(open_err);
    };
    defer file.close();

    const full = file.readToEndAlloc(self.alloc, self.max_bytes) catch |read_err| switch (read_err) {
        error.FileTooBig => return error.TooLarge,
        else => return mapFsErr(read_err),
    };
    defer self.alloc.free(full);

    var line_no: u32 = 0;
    var it = std.mem.splitScalar(u8, full, '\n');
    while (hit_ct.* < args.max_results) {
        const raw_line = it.next() orelse break;
        line_no += 1;
        const line = trimLine(raw_line);
        if (!lineMatches(line, args.pattern, args.ignore_case)) continue;

        const row = std.fmt.allocPrint(self.alloc, "{s}:{d}:{s}\n", .{
            rel_path,
            line_no,
            line,
        }) catch return error.OutOfMemory;
        defer self.alloc.free(row);
        try acc.append(row);
        hit_ct.* += 1;
    }
}

fn trimLine(raw: []const u8) []const u8 {
    if (raw.len == 0) return raw;
    if (raw[raw.len - 1] == '\r') return raw[0 .. raw.len - 1];
    return raw;
}

fn lineMatches(line: []const u8, pattern: []const u8, ignore_case: bool) bool {
    if (!ignore_case) return std.mem.indexOf(u8, line, pattern) != null;
    return containsAsciiFold(line, pattern);
}

fn containsAsciiFold(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > hay.len) return false;

    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (eqlAsciiFold(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn eqlAsciiFold(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (asciiLower(x) != asciiLower(y)) return false;
    }
    return true;
}

fn asciiLower(ch: u8) u8 {
    if (ch >= 'A' and ch <= 'Z') return ch + ('a' - 'A');
    return ch;
}

const Acc = struct {
    alloc: std.mem.Allocator,
    limit: usize,
    buf: std.ArrayList(u8) = .empty,
    full_bytes: usize = 0,

    fn init(alloc: std.mem.Allocator, limit: usize) Acc {
        return .{
            .alloc = alloc,
            .limit = limit,
        };
    }

    fn deinit(self: *Acc) void {
        self.buf.deinit(self.alloc);
        self.* = undefined;
    }

    fn append(self: *Acc, data: []const u8) !void {
        self.full_bytes = satAdd(self.full_bytes, data.len);
        if (self.buf.items.len >= self.limit) return;

        const keep = @min(data.len, self.limit - self.buf.items.len);
        if (keep == 0) return;
        try self.buf.appendSlice(self.alloc, data[0..keep]);
    }

    fn takeOwned(self: *Acc) ![]u8 {
        const out = try self.buf.toOwnedSlice(self.alloc);
        self.buf = .empty;
        return out;
    }
};

fn satAdd(a: usize, b: usize) usize {
    const sum, const ov = @addWithOverflow(a, b);
    if (ov == 0) return sum;
    return std.math.maxInt(usize);
}

fn mapFsErr(err: anyerror) Err {
    return switch (err) {
        error.FileNotFound => error.NotFound,
        error.AccessDenied, error.PermissionDenied => error.Denied,
        error.OutOfMemory => error.OutOfMemory,
        else => error.Io,
    };
}

test "grep handler finds matching lines with file and line numbers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("src");
    try tmp.dir.writeFile(.{ .sub_path = "src/a.txt", .data = "alpha\nbeta\n" });
    try tmp.dir.writeFile(.{ .sub_path = "src/b.txt", .data = "Beta\n" });

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, "src");
    defer std.testing.allocator.free(root);

    const SinkImpl = struct {
        fn push(_: *@This(), _: tools.Event) !void {}
    };
    var sink_impl = SinkImpl{};
    const sink = tools.Sink.from(SinkImpl, &sink_impl, SinkImpl.push);

    const handler = Handler.init(.{
        .alloc = std.testing.allocator,
        .max_bytes = 1024,
        .now_ms = 9,
    });
    const call: tools.Call = .{
        .id = "g1",
        .kind = .grep,
        .args = .{ .grep = .{
            .path = root,
            .pattern = "beta",
            .ignore_case = true,
        } },
        .src = .model,
        .at_ms = 0,
    };

    const res = try handler.run(call, sink);
    defer handler.deinitResult(res);

    try std.testing.expect(std.mem.indexOf(u8, res.out[0].chunk, "a.txt:2:beta\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out[0].chunk, "b.txt:1:Beta\n") != null);
}

test "grep handler validates args and missing roots" {
    const SinkImpl = struct {
        fn push(_: *@This(), _: tools.Event) !void {}
    };
    var sink_impl = SinkImpl{};
    const sink = tools.Sink.from(SinkImpl, &sink_impl, SinkImpl.push);

    const handler = Handler.init(.{
        .alloc = std.testing.allocator,
        .max_bytes = 64,
    });

    const bad: tools.Call = .{
        .id = "g2",
        .kind = .grep,
        .args = .{ .grep = .{ .path = ".", .pattern = "", .max_results = 1 } },
        .src = .model,
        .at_ms = 0,
    };
    try std.testing.expectError(error.InvalidArgs, handler.run(bad, sink));

    const missing: tools.Call = .{
        .id = "g3",
        .kind = .grep,
        .args = .{ .grep = .{ .path = "no-such-dir-9477", .pattern = "x" } },
        .src = .model,
        .at_ms = 0,
    };
    try std.testing.expectError(error.NotFound, handler.run(missing, sink));
}
