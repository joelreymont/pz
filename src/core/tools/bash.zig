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
        if (call.kind != .bash) return error.KindMismatch;
        if (std.meta.activeTag(call.args) != .bash) return error.KindMismatch;

        const args = call.args.bash;
        if (args.cmd.len == 0) return error.InvalidArgs;

        if (args.cwd) |cwd| {
            if (cwd.len == 0) return error.InvalidArgs;
        }

        for (args.env) |kv| {
            if (!isValidEnv(kv.key, kv.val)) return error.InvalidArgs;
        }

        var env = std.process.getEnvMap(self.alloc) catch |env_err| {
            return mapEnvErr(env_err);
        };
        defer env.deinit();

        for (args.env) |kv| {
            env.put(kv.key, kv.val) catch |put_err| {
                return mapEnvErr(put_err);
            };
        }

        const argv = [_][]const u8{ "/bin/bash", "-lc", args.cmd };
        const run_res = try runChild(self, argv[0..], args.cwd, &env);

        var stdout_chunk = run_res.stdout.chunk;
        errdefer self.alloc.free(stdout_chunk);

        var stderr_chunk = run_res.stderr.chunk;
        errdefer self.alloc.free(stderr_chunk);

        const stdout_meta = tools.output.metaFor(self.max_bytes, run_res.stdout.full_bytes);
        const stderr_meta = tools.output.metaFor(self.max_bytes, run_res.stderr.full_bytes);

        var stdout_meta_chunk: ?[]u8 = null;
        if (stdout_meta) |meta| {
            stdout_meta_chunk = tools.output.metaJsonAlloc(self.alloc, .stdout, meta) catch {
                return error.OutOfMemory;
            };
        }
        errdefer if (stdout_meta_chunk) |chunk| self.alloc.free(chunk);

        var stderr_meta_chunk: ?[]u8 = null;
        if (stderr_meta) |meta| {
            stderr_meta_chunk = tools.output.metaJsonAlloc(self.alloc, .stderr, meta) catch {
                return error.OutOfMemory;
            };
        }
        errdefer if (stderr_meta_chunk) |chunk| self.alloc.free(chunk);

        const out_len =
            @as(usize, @intFromBool(run_res.stdout.full_bytes != 0)) +
            @as(usize, @intFromBool(run_res.stderr.full_bytes != 0)) +
            @as(usize, @intFromBool(stdout_meta_chunk != null)) +
            @as(usize, @intFromBool(stderr_meta_chunk != null));

        const out = self.alloc.alloc(tools.Output, out_len) catch {
            return error.OutOfMemory;
        };
        errdefer self.alloc.free(out);

        var idx: usize = 0;
        if (run_res.stdout.full_bytes != 0) {
            out[idx] = .{
                .call_id = call.id,
                .seq = @intCast(idx),
                .at_ms = self.now_ms,
                .stream = .stdout,
                .chunk = stdout_chunk,
                .owned = true,
                .truncated = stdout_meta != null,
            };
            idx += 1;
            stdout_chunk = &.{};

            if (stdout_meta_chunk) |chunk| {
                out[idx] = .{
                    .call_id = call.id,
                    .seq = @intCast(idx),
                    .at_ms = self.now_ms,
                    .stream = .meta,
                    .chunk = chunk,
                    .owned = true,
                    .truncated = false,
                };
                idx += 1;
                stdout_meta_chunk = null;
            }
        } else {
            self.alloc.free(stdout_chunk);
            stdout_chunk = &.{};
        }

        if (run_res.stderr.full_bytes != 0) {
            out[idx] = .{
                .call_id = call.id,
                .seq = @intCast(idx),
                .at_ms = self.now_ms,
                .stream = .stderr,
                .chunk = stderr_chunk,
                .owned = true,
                .truncated = stderr_meta != null,
            };
            idx += 1;
            stderr_chunk = &.{};

            if (stderr_meta_chunk) |chunk| {
                out[idx] = .{
                    .call_id = call.id,
                    .seq = @intCast(idx),
                    .at_ms = self.now_ms,
                    .stream = .meta,
                    .chunk = chunk,
                    .owned = true,
                    .truncated = false,
                };
                idx += 1;
                stderr_meta_chunk = null;
            }
        } else {
            self.alloc.free(stderr_chunk);
            stderr_chunk = &.{};
        }

        return .{
            .call_id = call.id,
            .started_at_ms = self.now_ms,
            .ended_at_ms = self.now_ms,
            .out = out,
            .out_owned = true,
            .final = termToFinal(run_res.term),
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

const Capture = struct {
    chunk: []u8,
    full_bytes: usize,
};

const RunOut = struct {
    stdout: Capture,
    stderr: Capture,
    term: std.process.Child.Term,
};

const CollectCtx = struct {
    alloc: std.mem.Allocator,
    file: std.fs.File,
    max_bytes: usize,
    buf: std.ArrayList(u8) = .empty,
    full_bytes: usize = 0,
    err: ?anyerror = null,

    fn run(self: *@This()) void {
        defer self.file.close();

        var keep = true;
        var scratch: [4096]u8 = undefined;
        while (true) {
            const n = self.file.read(&scratch) catch |read_err| {
                if (self.err == null) self.err = read_err;
                return;
            };
            if (n == 0) return;

            self.full_bytes = satAdd(self.full_bytes, n);

            if (keep and self.buf.items.len < self.max_bytes) {
                const keep_len = @min(n, self.max_bytes - self.buf.items.len);
                if (keep_len != 0) {
                    self.buf.appendSlice(self.alloc, scratch[0..keep_len]) catch |append_err| {
                        if (self.err == null) self.err = append_err;
                        keep = false;
                    };
                }
            }
        }
    }
};

fn runChild(
    self: Handler,
    argv: []const []const u8,
    cwd: ?[]const u8,
    env: *const std.process.EnvMap,
) Err!RunOut {
    var child = std.process.Child.init(argv, self.alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.cwd = cwd;
    child.env_map = env;

    child.spawn() catch |spawn_err| return mapProcErr(spawn_err);

    const stdout_file = child.stdout orelse return error.Io;
    const stderr_file = child.stderr orelse return error.Io;
    child.stdout = null;
    child.stderr = null;

    var stdout_ctx = CollectCtx{
        .alloc = self.alloc,
        .file = stdout_file,
        .max_bytes = self.max_bytes,
    };
    var stderr_ctx = CollectCtx{
        .alloc = self.alloc,
        .file = stderr_file,
        .max_bytes = self.max_bytes,
    };

    const stdout_thr = std.Thread.spawn(.{}, CollectCtx.run, .{&stdout_ctx}) catch |thr_err| {
        stdout_ctx.file.close();
        stderr_ctx.file.close();
        killAndWait(&child) catch |kill_err| {
            return kill_err;
        };
        return mapProcErr(thr_err);
    };

    const stderr_thr = std.Thread.spawn(.{}, CollectCtx.run, .{&stderr_ctx}) catch |thr_err| {
        stderr_ctx.file.close();
        killAndWait(&child) catch |kill_err| {
            stdout_thr.join();
            stdout_ctx.buf.deinit(self.alloc);
            stderr_ctx.buf.deinit(self.alloc);
            return kill_err;
        };
        stdout_thr.join();
        stdout_ctx.buf.deinit(self.alloc);
        stderr_ctx.buf.deinit(self.alloc);
        return mapProcErr(thr_err);
    };

    const term = child.wait() catch |wait_err| {
        killAndWait(&child) catch |kill_err| {
            stdout_thr.join();
            stderr_thr.join();
            stdout_ctx.buf.deinit(self.alloc);
            stderr_ctx.buf.deinit(self.alloc);
            return kill_err;
        };
        stdout_thr.join();
        stderr_thr.join();
        stdout_ctx.buf.deinit(self.alloc);
        stderr_ctx.buf.deinit(self.alloc);
        return mapProcErr(wait_err);
    };

    stdout_thr.join();
    stderr_thr.join();

    if (stdout_ctx.err) |collect_err| {
        stdout_ctx.buf.deinit(self.alloc);
        stderr_ctx.buf.deinit(self.alloc);
        return mapCollectErr(collect_err);
    }

    if (stderr_ctx.err) |collect_err| {
        stdout_ctx.buf.deinit(self.alloc);
        stderr_ctx.buf.deinit(self.alloc);
        return mapCollectErr(collect_err);
    }

    const stdout_chunk = stdout_ctx.buf.toOwnedSlice(self.alloc) catch {
        stdout_ctx.buf.deinit(self.alloc);
        stderr_ctx.buf.deinit(self.alloc);
        return error.OutOfMemory;
    };

    const stderr_chunk = stderr_ctx.buf.toOwnedSlice(self.alloc) catch {
        self.alloc.free(stdout_chunk);
        stderr_ctx.buf.deinit(self.alloc);
        return error.OutOfMemory;
    };

    return .{
        .stdout = .{
            .chunk = stdout_chunk,
            .full_bytes = stdout_ctx.full_bytes,
        },
        .stderr = .{
            .chunk = stderr_chunk,
            .full_bytes = stderr_ctx.full_bytes,
        },
        .term = term,
    };
}

fn killAndWait(child: *std.process.Child) Err!void {
    _ = child.kill() catch |kill_err| switch (kill_err) {
        error.AlreadyTerminated => {
            _ = child.wait() catch |wait_err| {
                return mapProcErr(wait_err);
            };
            return;
        },
        else => return mapProcErr(kill_err),
    };
}

fn satAdd(a: usize, b: usize) usize {
    const sum = @addWithOverflow(a, b);
    if (sum[1] == 0) return sum[0];
    return std.math.maxInt(usize);
}

fn isValidEnv(key: []const u8, val: []const u8) bool {
    if (key.len == 0) return false;
    if (std.mem.indexOfScalar(u8, key, '=')) |_| return false;
    if (std.mem.indexOfScalar(u8, key, 0)) |_| return false;
    if (std.mem.indexOfScalar(u8, val, 0)) |_| return false;
    return true;
}

fn mapEnvErr(err: anyerror) Err {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Io,
    };
}

fn mapProcErr(err: anyerror) Err {
    return switch (err) {
        error.FileNotFound,
        error.NotDir,
        => error.NotFound,
        error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => error.Denied,
        error.OutOfMemory => error.OutOfMemory,
        else => error.Io,
    };
}

fn mapCollectErr(err: anyerror) Err {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Io,
    };
}

fn termToFinal(term: std.process.Child.Term) tools.Result.Final {
    return switch (term) {
        .Exited => |code| if (code == 0)
            .{ .ok = .{ .code = 0 } }
        else
            .{ .failed = .{
                .code = @as(i32, code),
                .kind = .exec,
                .msg = "bash exited non-zero",
            } },
        .Signal => .{ .failed = .{
            .code = null,
            .kind = .exec,
            .msg = "bash terminated by signal",
        } },
        .Stopped => .{ .failed = .{
            .code = null,
            .kind = .exec,
            .msg = "bash stopped",
        } },
        .Unknown => .{ .failed = .{
            .code = null,
            .kind = .exec,
            .msg = "bash terminated",
        } },
    };
}

test "bash handler captures stdout and stderr with deterministic timestamps" {
    const SinkImpl = struct {
        fn push(_: *@This(), _: tools.Event) !void {}
    };

    var sink_impl = SinkImpl{};
    const sink = tools.Sink.from(SinkImpl, &sink_impl, SinkImpl.push);

    const handler = Handler.init(.{
        .alloc = std.testing.allocator,
        .max_bytes = 1024,
        .now_ms = 99,
    });
    const call: tools.Call = .{
        .id = "b1",
        .kind = .bash,
        .args = .{ .bash = .{
            .cmd = "printf 'out'; printf 'err' 1>&2",
        } },
        .src = .system,
        .at_ms = 0,
    };

    const res = try handler.run(call, sink);
    defer handler.deinitResult(res);

    try std.testing.expectEqual(@as(i64, 99), res.started_at_ms);
    try std.testing.expectEqual(@as(i64, 99), res.ended_at_ms);
    try std.testing.expectEqual(@as(usize, 2), res.out.len);

    try std.testing.expectEqual(@as(u32, 0), res.out[0].seq);
    try std.testing.expectEqual(@as(i64, 99), res.out[0].at_ms);
    try std.testing.expect(res.out[0].stream == .stdout);
    try std.testing.expectEqualStrings("out", res.out[0].chunk);
    try std.testing.expect(!res.out[0].truncated);

    try std.testing.expectEqual(@as(u32, 1), res.out[1].seq);
    try std.testing.expectEqual(@as(i64, 99), res.out[1].at_ms);
    try std.testing.expect(res.out[1].stream == .stderr);
    try std.testing.expectEqualStrings("err", res.out[1].chunk);
    try std.testing.expect(!res.out[1].truncated);

    switch (res.final) {
        .ok => |ok| try std.testing.expectEqual(@as(i32, 0), ok.code),
        else => return error.TestUnexpectedResult,
    }
}

test "bash handler applies explicit env variables" {
    const SinkImpl = struct {
        fn push(_: *@This(), _: tools.Event) !void {}
    };

    var sink_impl = SinkImpl{};
    const sink = tools.Sink.from(SinkImpl, &sink_impl, SinkImpl.push);

    const env = [_]tools.Call.Env{
        .{
            .key = "PZ_BASH_ENV",
            .val = "ok",
        },
    };
    const handler = Handler.init(.{
        .alloc = std.testing.allocator,
        .max_bytes = 128,
    });
    const call: tools.Call = .{
        .id = "b2",
        .kind = .bash,
        .args = .{ .bash = .{
            .cmd = "printf '%s' \"$PZ_BASH_ENV\"",
            .env = env[0..],
        } },
        .src = .model,
        .at_ms = 0,
    };

    const res = try handler.run(call, sink);
    defer handler.deinitResult(res);

    try std.testing.expectEqual(@as(usize, 1), res.out.len);
    try std.testing.expect(res.out[0].stream == .stdout);
    try std.testing.expectEqualStrings("ok", res.out[0].chunk);
}

test "bash handler returns failed final on non-zero exit" {
    const SinkImpl = struct {
        fn push(_: *@This(), _: tools.Event) !void {}
    };

    var sink_impl = SinkImpl{};
    const sink = tools.Sink.from(SinkImpl, &sink_impl, SinkImpl.push);

    const handler = Handler.init(.{
        .alloc = std.testing.allocator,
        .max_bytes = 1024,
    });
    const call: tools.Call = .{
        .id = "b3",
        .kind = .bash,
        .args = .{ .bash = .{
            .cmd = "printf 'fail' 1>&2; exit 7",
        } },
        .src = .model,
        .at_ms = 0,
    };

    const res = try handler.run(call, sink);
    defer handler.deinitResult(res);

    try std.testing.expectEqual(@as(usize, 1), res.out.len);
    try std.testing.expect(res.out[0].stream == .stderr);
    try std.testing.expectEqualStrings("fail", res.out[0].chunk);

    switch (res.final) {
        .failed => |failed| {
            try std.testing.expectEqual(@as(?i32, 7), failed.code);
            try std.testing.expect(failed.kind == .exec);
            try std.testing.expectEqualStrings("bash exited non-zero", failed.msg);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "bash handler returns invalid args on empty command" {
    const SinkImpl = struct {
        fn push(_: *@This(), _: tools.Event) !void {}
    };

    var sink_impl = SinkImpl{};
    const sink = tools.Sink.from(SinkImpl, &sink_impl, SinkImpl.push);

    const handler = Handler.init(.{
        .alloc = std.testing.allocator,
        .max_bytes = 128,
    });
    const call: tools.Call = .{
        .id = "b4",
        .kind = .bash,
        .args = .{ .bash = .{
            .cmd = "",
        } },
        .src = .system,
        .at_ms = 0,
    };

    try std.testing.expectError(error.InvalidArgs, handler.run(call, sink));
}

test "bash handler returns invalid args on bad env key" {
    const SinkImpl = struct {
        fn push(_: *@This(), _: tools.Event) !void {}
    };

    var sink_impl = SinkImpl{};
    const sink = tools.Sink.from(SinkImpl, &sink_impl, SinkImpl.push);

    const env = [_]tools.Call.Env{
        .{
            .key = "BAD=KEY",
            .val = "x",
        },
    };
    const handler = Handler.init(.{
        .alloc = std.testing.allocator,
        .max_bytes = 128,
    });
    const call: tools.Call = .{
        .id = "b5",
        .kind = .bash,
        .args = .{ .bash = .{
            .cmd = "true",
            .env = env[0..],
        } },
        .src = .system,
        .at_ms = 0,
    };

    try std.testing.expectError(error.InvalidArgs, handler.run(call, sink));
}

test "bash handler returns not found for missing cwd" {
    const SinkImpl = struct {
        fn push(_: *@This(), _: tools.Event) !void {}
    };

    var sink_impl = SinkImpl{};
    const sink = tools.Sink.from(SinkImpl, &sink_impl, SinkImpl.push);

    const handler = Handler.init(.{
        .alloc = std.testing.allocator,
        .max_bytes = 128,
    });
    const call: tools.Call = .{
        .id = "b6",
        .kind = .bash,
        .args = .{ .bash = .{
            .cmd = "printf x",
            .cwd = "/tmp/this-dir-should-not-exist-79a1f55a",
        } },
        .src = .model,
        .at_ms = 0,
    };

    try std.testing.expectError(error.NotFound, handler.run(call, sink));
}

test "bash handler truncates oversized output and emits metadata" {
    const SinkImpl = struct {
        fn push(_: *@This(), _: tools.Event) !void {}
    };

    var sink_impl = SinkImpl{};
    const sink = tools.Sink.from(SinkImpl, &sink_impl, SinkImpl.push);

    const handler = Handler.init(.{
        .alloc = std.testing.allocator,
        .max_bytes = 3,
    });
    const call: tools.Call = .{
        .id = "b7",
        .kind = .bash,
        .args = .{ .bash = .{
            .cmd = "printf 'abcd'",
        } },
        .src = .model,
        .at_ms = 0,
    };

    const res = try handler.run(call, sink);
    defer handler.deinitResult(res);

    try std.testing.expectEqual(@as(usize, 2), res.out.len);

    try std.testing.expectEqual(@as(u32, 0), res.out[0].seq);
    try std.testing.expect(res.out[0].stream == .stdout);
    try std.testing.expectEqualStrings("abc", res.out[0].chunk);
    try std.testing.expect(res.out[0].truncated);

    try std.testing.expectEqual(@as(u32, 1), res.out[1].seq);
    try std.testing.expect(res.out[1].stream == .meta);
    try std.testing.expectEqualStrings(
        "{\"type\":\"trunc\",\"stream\":\"stdout\",\"limit_bytes\":3,\"full_bytes\":4,\"kept_bytes\":3,\"dropped_bytes\":1}",
        res.out[1].chunk,
    );

    switch (res.final) {
        .ok => |ok| try std.testing.expectEqual(@as(i32, 0), ok.code),
        else => return error.TestUnexpectedResult,
    }
}

test "bash handler returns kind mismatch for wrong call kind" {
    const SinkImpl = struct {
        fn push(_: *@This(), _: tools.Event) !void {}
    };

    var sink_impl = SinkImpl{};
    const sink = tools.Sink.from(SinkImpl, &sink_impl, SinkImpl.push);

    const handler = Handler.init(.{
        .alloc = std.testing.allocator,
        .max_bytes = 128,
    });
    const call: tools.Call = .{
        .id = "b8",
        .kind = .read,
        .args = .{ .read = .{
            .path = "x",
        } },
        .src = .model,
        .at_ms = 0,
    };

    try std.testing.expectError(error.KindMismatch, handler.run(call, sink));
}
