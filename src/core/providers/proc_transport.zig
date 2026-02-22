const std = @import("std");
const first = @import("first_provider.zig");

pub const Transport = struct {
    alloc: std.mem.Allocator,
    cmd: []u8,
    cwd: ?[]u8 = null,
    chunk_bytes: usize = 4096,

    pub const Init = struct {
        alloc: std.mem.Allocator,
        cmd: []const u8,
        cwd: ?[]const u8 = null,
        chunk_bytes: usize = 4096,
    };

    pub fn init(cfg: Init) !Transport {
        if (cfg.cmd.len == 0) return error.InvalidCommand;
        if (cfg.chunk_bytes == 0) return error.InvalidChunkSize;

        return .{
            .alloc = cfg.alloc,
            .cmd = try cfg.alloc.dupe(u8, cfg.cmd),
            .cwd = if (cfg.cwd) |cwd| try cfg.alloc.dupe(u8, cwd) else null,
            .chunk_bytes = cfg.chunk_bytes,
        };
    }

    pub fn deinit(self: *Transport) void {
        self.alloc.free(self.cmd);
        if (self.cwd) |cwd| self.alloc.free(cwd);
        self.* = undefined;
    }

    pub fn asRawTransport(self: *Transport) first.RawTransport {
        return first.RawTransport.from(Transport, self, Transport.start);
    }

    fn start(self: *Transport, req_wire: []const u8) !first.RawChunkStream {
        const stream = try self.alloc.create(ProcChunk);
        errdefer self.alloc.destroy(stream);

        stream.* = try ProcChunk.init(self.alloc, self.cmd, self.cwd, self.chunk_bytes, req_wire);
        return first.RawChunkStream.from(ProcChunk, stream, ProcChunk.next, ProcChunk.deinit);
    }
};

const ProcChunk = struct {
    alloc: std.mem.Allocator,
    child: std.process.Child,
    stdout: std.fs.File,
    buf: []u8,
    done: bool = false,

    fn init(
        alloc: std.mem.Allocator,
        cmd: []const u8,
        cwd: ?[]const u8,
        chunk_bytes: usize,
        req_wire: []const u8,
    ) !ProcChunk {
        const argv = [_][]const u8{
            "/bin/bash",
            "-lc",
            cmd,
        };

        var child = std.process.Child.init(argv[0..], alloc);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        child.cwd = cwd;

        child.spawn() catch |spawn_err| return mapProcErr(spawn_err);
        errdefer {
            killAndWait(&child) catch |err| {
                std.debug.print("warning: child cleanup failed: {s}\n", .{@errorName(err)});
            };
        }

        var stdin = child.stdin orelse return error.Closed;
        child.stdin = null;
        defer stdin.close();
        stdin.writeAll(req_wire) catch |write_err| {
            return mapIoErr(write_err);
        };

        const stdout = child.stdout orelse return error.Closed;
        child.stdout = null;

        const buf = alloc.alloc(u8, chunk_bytes) catch |alloc_err| {
            stdout.close();
            return alloc_err;
        };

        return .{
            .alloc = alloc,
            .child = child,
            .stdout = stdout,
            .buf = buf,
        };
    }

    fn next(self: *ProcChunk) anyerror!?[]const u8 {
        if (self.done) return null;

        const n = self.stdout.read(self.buf) catch |read_err| return mapIoErr(read_err);
        if (n != 0) return self.buf[0..n];

        self.stdout.close();

        const term = self.child.wait() catch |wait_err| return mapProcErr(wait_err);
        self.done = true;

        switch (term) {
            .Exited => |code| {
                if (code == 0) return null;
                return error.BadGateway;
            },
            .Signal, .Stopped, .Unknown => return error.BadGateway,
        }
    }

    fn deinit(self: *ProcChunk) void {
        if (!self.done) {
            self.stdout.close();
            killAndWait(&self.child) catch |err| {
                std.debug.print("warning: child cleanup failed: {s}\n", .{@errorName(err)});
            };
            self.done = true;
        }

        self.alloc.free(self.buf);
        const alloc = self.alloc;
        alloc.destroy(self);
    }
};

fn killAndWait(child: *std.process.Child) !void {
    _ = child.kill() catch |kill_err| switch (kill_err) {
        error.AlreadyTerminated => {
            _ = child.wait() catch |wait_err| return mapProcErr(wait_err);
            return;
        },
        else => return mapProcErr(kill_err),
    };
}

fn mapProcErr(err: anyerror) anyerror {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Closed,
    };
}

fn mapIoErr(err: anyerror) anyerror {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.WireBreak,
    };
}

test "proc transport streams stdout frames and exits cleanly" {
    var tr = try Transport.init(.{
        .alloc = std.testing.allocator,
        .cmd = "cat >/dev/null; printf 'text:ok\\nstop:done\\n'",
        .chunk_bytes = 5,
    });
    defer tr.deinit();

    var raw = try tr.asRawTransport().start("{\"model\":\"m\"}");
    defer raw.deinit();

    var out: [128]u8 = undefined;
    var at: usize = 0;
    while (try raw.next()) |chunk| {
        if (at + chunk.len > out.len) return error.TestUnexpectedResult;
        @memcpy(out[at .. at + chunk.len], chunk);
        at += chunk.len;
    }

    try std.testing.expectEqualStrings("text:ok\nstop:done\n", out[0..at]);
}

test "proc transport reports bad gateway on non-zero exit" {
    var tr = try Transport.init(.{
        .alloc = std.testing.allocator,
        .cmd = "cat >/dev/null; printf 'text:ok\\n'; exit 9",
    });
    defer tr.deinit();

    var raw = try tr.asRawTransport().start("{\"model\":\"m\"}");
    defer raw.deinit();

    _ = (try raw.next()) orelse return error.TestUnexpectedResult;
    try std.testing.expectError(error.BadGateway, raw.next());
}
