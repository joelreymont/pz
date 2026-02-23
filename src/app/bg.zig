const std = @import("std");

pub const State = enum {
    running,
    exited,
    signaled,
    stopped,
    unknown,
    wait_err,
};

pub fn stateName(st: State) []const u8 {
    return switch (st) {
        .running => "running",
        .exited => "exited",
        .signaled => "signaled",
        .stopped => "stopped",
        .unknown => "unknown",
        .wait_err => "wait_err",
    };
}

pub const StopRes = enum {
    sent,
    already_done,
    not_found,
};

pub const View = struct {
    id: u64,
    pid: i32,
    cmd: []u8,
    log_path: []u8,
    state: State,
    code: ?i32,
    started_at_ms: i64,
    ended_at_ms: ?i64,
    err_name: ?[]const u8,
};

pub fn deinitViews(alloc: std.mem.Allocator, views: []View) void {
    for (views) |v| {
        alloc.free(v.cmd);
        alloc.free(v.log_path);
    }
    alloc.free(views);
}

pub fn deinitView(alloc: std.mem.Allocator, v: View) void {
    alloc.free(v.cmd);
    alloc.free(v.log_path);
}

const WaitCtx = struct {
    mgr: *Mgr,
    job_id: u64,
    child: std.process.Child,
};

const Job = struct {
    id: u64,
    pid: i32,
    cmd: []u8,
    log_path: []u8,
    state: State = .running,
    code: ?i32 = null,
    started_at_ms: i64,
    ended_at_ms: ?i64 = null,
    err_name: ?[]const u8 = null,
    thr: ?std.Thread = null,
    ctx: *WaitCtx,
};

pub const Mgr = struct {
    alloc: std.mem.Allocator,
    mu: std.Thread.Mutex = .{},
    jobs: std.ArrayListUnmanaged(Job) = .empty,
    done: std.ArrayListUnmanaged(u64) = .empty,
    next_id: u64 = 1,
    wake_r: std.posix.fd_t,
    wake_w: std.posix.fd_t,

    pub fn init(alloc: std.mem.Allocator) !Mgr {
        const pipe = try std.posix.pipe2(.{
            .NONBLOCK = true,
            .CLOEXEC = true,
        });
        return .{
            .alloc = alloc,
            .wake_r = pipe[0],
            .wake_w = pipe[1],
        };
    }

    pub fn deinit(self: *Mgr) void {
        self.mu.lock();
        for (self.jobs.items) |job| {
            if (job.state == .running) {
                _ = std.posix.kill(@as(std.posix.pid_t, @intCast(job.pid)), std.posix.SIG.KILL) catch {};
            }
        }
        self.mu.unlock();

        var i: usize = 0;
        while (true) : (i += 1) {
            var thr: ?std.Thread = null;

            self.mu.lock();
            if (i >= self.jobs.items.len) {
                self.mu.unlock();
                break;
            }
            thr = self.jobs.items[i].thr;
            self.jobs.items[i].thr = null;
            self.mu.unlock();

            if (thr) |t| t.join();
        }

        self.mu.lock();
        for (self.jobs.items) |job| {
            self.alloc.destroy(job.ctx);
            self.alloc.free(job.cmd);
            self.alloc.free(job.log_path);
        }
        self.jobs.deinit(self.alloc);
        self.done.deinit(self.alloc);
        self.mu.unlock();

        std.posix.close(self.wake_r);
        std.posix.close(self.wake_w);
        self.* = undefined;
    }

    pub fn wakeFd(self: *const Mgr) std.posix.fd_t {
        return self.wake_r;
    }

    pub fn start(self: *Mgr, cmd_raw: []const u8, cwd: ?[]const u8) !u64 {
        const cmd = std.mem.trim(u8, cmd_raw, " \t");
        if (cmd.len == 0) return error.InvalidArgs;

        const id = blk: {
            self.mu.lock();
            defer self.mu.unlock();
            const out = self.next_id;
            self.next_id +%= 1;
            break :blk out;
        };

        const log_path = try self.mkLogPath(id);
        errdefer self.alloc.free(log_path);

        const cmd_dup = try self.alloc.dupe(u8, cmd);
        errdefer self.alloc.free(cmd_dup);

        var env = try std.process.getEnvMap(self.alloc);
        defer env.deinit();
        try env.put("PZ_BG_LOG", log_path);

        const wrapped = try std.fmt.allocPrint(self.alloc, "({s}) >\"${{PZ_BG_LOG}}\" 2>&1", .{cmd});
        defer self.alloc.free(wrapped);

        const argv = [_][]const u8{
            "/bin/bash",
            "-lc",
            wrapped,
        };

        var child = std.process.Child.init(argv[0..], self.alloc);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        child.cwd = cwd;
        child.env_map = &env;
        try child.spawn();

        const ctx = try self.alloc.create(WaitCtx);
        errdefer self.alloc.destroy(ctx);
        ctx.* = .{
            .mgr = self,
            .job_id = id,
            .child = child,
        };

        const pid: i32 = @intCast(child.id);
        const started_at_ms = std.time.milliTimestamp();

        self.mu.lock();
        const idx = self.jobs.items.len;
        self.jobs.append(self.alloc, .{
            .id = id,
            .pid = pid,
            .cmd = cmd_dup,
            .log_path = log_path,
            .state = .running,
            .code = null,
            .started_at_ms = started_at_ms,
            .ended_at_ms = null,
            .err_name = null,
            .thr = null,
            .ctx = ctx,
        }) catch |append_err| {
            self.mu.unlock();
            _ = child.kill() catch {};
            _ = child.wait() catch {};
            self.alloc.destroy(ctx);
            self.alloc.free(cmd_dup);
            self.alloc.free(log_path);
            return append_err;
        };
        self.mu.unlock();

        const thr = std.Thread.spawn(.{}, waitThread, .{ctx}) catch |spawn_err| {
            _ = child.kill() catch {};
            _ = child.wait() catch {};

            self.mu.lock();
            if (idx < self.jobs.items.len and self.jobs.items[idx].id == id) {
                const removed = self.jobs.orderedRemove(idx);
                self.mu.unlock();
                self.alloc.destroy(removed.ctx);
                self.alloc.free(removed.cmd);
                self.alloc.free(removed.log_path);
            } else {
                self.mu.unlock();
            }
            return spawn_err;
        };

        self.mu.lock();
        if (idx < self.jobs.items.len and self.jobs.items[idx].id == id) {
            self.jobs.items[idx].thr = thr;
        } else {
            self.mu.unlock();
            thr.join();
            return error.InternalError;
        }
        self.mu.unlock();

        return id;
    }

    pub fn stop(self: *Mgr, id: u64) !StopRes {
        self.mu.lock();
        const idx = self.findIdxLocked(id) orelse {
            self.mu.unlock();
            return .not_found;
        };
        const job = self.jobs.items[idx];
        if (job.state != .running) {
            self.mu.unlock();
            return .already_done;
        }
        const pid: std.posix.pid_t = @intCast(job.pid);
        self.mu.unlock();

        std.posix.kill(pid, std.posix.SIG.TERM) catch |err| switch (err) {
            error.ProcessNotFound => return .already_done,
            else => return err,
        };
        return .sent;
    }

    pub fn list(self: *Mgr, alloc: std.mem.Allocator) ![]View {
        self.mu.lock();
        defer self.mu.unlock();

        const out = try alloc.alloc(View, self.jobs.items.len);
        errdefer alloc.free(out);

        var i: usize = 0;
        errdefer {
            var j: usize = 0;
            while (j < i) : (j += 1) {
                alloc.free(out[j].cmd);
                alloc.free(out[j].log_path);
            }
            alloc.free(out);
        }

        for (self.jobs.items) |job| {
            out[i] = try copyJob(alloc, job);
            i += 1;
        }
        return out;
    }

    pub fn view(self: *Mgr, alloc: std.mem.Allocator, id: u64) !?View {
        self.mu.lock();
        defer self.mu.unlock();

        const idx = self.findIdxLocked(id) orelse return null;
        return try copyJob(alloc, self.jobs.items[idx]);
    }

    pub fn drainDone(self: *Mgr, alloc: std.mem.Allocator) ![]View {
        self.mu.lock();
        const ids = try alloc.alloc(u64, self.done.items.len);
        for (self.done.items, 0..) |id, i| ids[i] = id;
        self.done.clearRetainingCapacity();
        self.mu.unlock();
        defer alloc.free(ids);

        const out = try alloc.alloc(View, ids.len);
        errdefer alloc.free(out);

        var i: usize = 0;
        errdefer {
            var j: usize = 0;
            while (j < i) : (j += 1) {
                alloc.free(out[j].cmd);
                alloc.free(out[j].log_path);
            }
            alloc.free(out);
        }

        for (ids) |id| {
            const v = (try self.view(alloc, id)) orelse return error.InternalError;
            out[i] = v;
            i += 1;
        }
        return out;
    }

    fn waitThread(ctx: *WaitCtx) void {
        const wait_term = ctx.child.wait();
        const ended_at_ms = std.time.milliTimestamp();
        ctx.mgr.onExit(ctx.job_id, ended_at_ms, wait_term);
    }

    fn onExit(self: *Mgr, id: u64, ended_at_ms: i64, wait_term: anyerror!std.process.Child.Term) void {
        self.mu.lock();
        defer self.mu.unlock();

        const idx = self.findIdxLocked(id) orelse return;
        var job = &self.jobs.items[idx];
        job.ended_at_ms = ended_at_ms;

        if (wait_term) |term| {
            switch (term) {
                .Exited => |code| {
                    job.state = .exited;
                    job.code = @as(i32, code);
                    job.err_name = null;
                },
                .Signal => |sig| {
                    job.state = .signaled;
                    job.code = @intCast(sig);
                    job.err_name = null;
                },
                .Stopped => |sig| {
                    job.state = .stopped;
                    job.code = @intCast(sig);
                    job.err_name = null;
                },
                .Unknown => |sig| {
                    job.state = .unknown;
                    job.code = @intCast(sig);
                    job.err_name = null;
                },
            }
        } else |wait_err| {
            job.state = .wait_err;
            job.code = null;
            job.err_name = @errorName(wait_err);
        }

        self.done.append(self.alloc, job.id) catch {};
        const b = [_]u8{1};
        _ = std.posix.write(self.wake_w, &b) catch {};
    }

    fn findIdxLocked(self: *Mgr, id: u64) ?usize {
        for (self.jobs.items, 0..) |job, i| {
            if (job.id == id) return i;
        }
        return null;
    }

    fn mkLogPath(self: *Mgr, id: u64) ![]u8 {
        var n: u32 = 0;
        while (n < 64) : (n += 1) {
            const ts = std.time.milliTimestamp();
            const path = try std.fmt.allocPrint(self.alloc, "/tmp/pz-bg-{d}-{d}-{d}.log", .{
                std.c.getpid(),
                id,
                ts + @as(i64, n),
            });

            const f = std.fs.createFileAbsolute(path, .{
                .read = true,
                .exclusive = true,
            }) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    self.alloc.free(path);
                    continue;
                },
                else => {
                    self.alloc.free(path);
                    return err;
                },
            };
            f.close();
            return path;
        }
        return error.PathAlreadyExists;
    }
};

fn copyJob(alloc: std.mem.Allocator, job: Job) !View {
    return .{
        .id = job.id,
        .pid = job.pid,
        .cmd = try alloc.dupe(u8, job.cmd),
        .log_path = try alloc.dupe(u8, job.log_path),
        .state = job.state,
        .code = job.code,
        .started_at_ms = job.started_at_ms,
        .ended_at_ms = job.ended_at_ms,
        .err_name = job.err_name,
    };
}

fn waitWake(fd: std.posix.fd_t, timeout_ms: i32) !bool {
    var fds = [1]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const n = try std.posix.poll(&fds, timeout_ms);
    if (n <= 0) return false;
    return (fds[0].revents & std.posix.POLL.IN) != 0;
}

const DoneSnap = struct {
    id: u64,
    state: []const u8,
    code: ?i32,
    cmd: []const u8,
    has_log: bool,
    has_out: bool,
    has_err: bool,
};

const JobSnap = struct {
    id: u64,
    state: []const u8,
    code: ?i32,
    cmd: []const u8,
    has_log: bool,
};

fn toJobSnap(v: View) JobSnap {
    return .{
        .id = v.id,
        .state = stateName(v.state),
        .code = v.code,
        .cmd = v.cmd,
        .has_log = v.log_path.len > 0,
    };
}

test "bg manager rejects empty command" {
    var mgr = try Mgr.init(std.testing.allocator);
    defer mgr.deinit();
    try std.testing.expectError(error.InvalidArgs, mgr.start("", null));
    try std.testing.expectError(error.InvalidArgs, mgr.start("   ", null));
}

test "bg manager captures stdout+stderr and reports completion" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};

    var mgr = try Mgr.init(std.testing.allocator);
    defer mgr.deinit();

    _ = try mgr.start("printf 'out'; printf 'err' 1>&2", null);
    const woke = try waitWake(mgr.wakeFd(), 5000);
    try std.testing.expect(woke);

    const done = try mgr.drainDone(std.testing.allocator);
    defer deinitViews(std.testing.allocator, done);

    try std.testing.expectEqual(@as(usize, 1), done.len);

    const f = try std.fs.openFileAbsolute(done[0].log_path, .{ .mode = .read_only });
    defer f.close();
    const out = try f.readToEndAlloc(std.testing.allocator, 1024);
    defer std.testing.allocator.free(out);

    const snap = DoneSnap{
        .id = done[0].id,
        .state = stateName(done[0].state),
        .code = done[0].code,
        .cmd = done[0].cmd,
        .has_log = done[0].log_path.len > 0,
        .has_out = std.mem.indexOf(u8, out, "out") != null,
        .has_err = std.mem.indexOf(u8, out, "err") != null,
    };
    try oh.snap(@src(),
        \\app.bg.DoneSnap
        \\  .id: u64 = 1
        \\  .state: []const u8
        \\    "exited"
        \\  .code: ?i32
        \\    0
        \\  .cmd: []const u8
        \\    "printf 'out'; printf 'err' 1>&2"
        \\  .has_log: bool = true
        \\  .has_out: bool = true
        \\  .has_err: bool = true
    ).expectEqual(snap);
}

test "bg manager supports multiple concurrent jobs" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};

    var mgr = try Mgr.init(std.testing.allocator);
    defer mgr.deinit();

    _ = try mgr.start("sleep 1", null);
    _ = try mgr.start("sleep 1", null);

    const jobs = try mgr.list(std.testing.allocator);
    defer deinitViews(std.testing.allocator, jobs);

    try std.testing.expectEqual(@as(usize, 2), jobs.len);
    const snaps = [_]JobSnap{
        toJobSnap(jobs[0]),
        toJobSnap(jobs[1]),
    };
    try oh.snap(@src(),
        \\[2]app.bg.JobSnap
        \\  [0]: app.bg.JobSnap
        \\    .id: u64 = 1
        \\    .state: []const u8
        \\      "running"
        \\    .code: ?i32
        \\      null
        \\    .cmd: []const u8
        \\      "sleep 1"
        \\    .has_log: bool = true
        \\  [1]: app.bg.JobSnap
        \\    .id: u64 = 2
        \\    .state: []const u8
        \\      "running"
        \\    .code: ?i32
        \\      null
        \\    .cmd: []const u8
        \\      "sleep 1"
        \\    .has_log: bool = true
    ).expectEqual(snaps);
}

test "bg manager records non-zero exit code" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};

    var mgr = try Mgr.init(std.testing.allocator);
    defer mgr.deinit();

    _ = try mgr.start("printf 'bad'; exit 7", null);
    const woke = try waitWake(mgr.wakeFd(), 5000);
    try std.testing.expect(woke);

    const done = try mgr.drainDone(std.testing.allocator);
    defer deinitViews(std.testing.allocator, done);
    try std.testing.expectEqual(@as(usize, 1), done.len);

    const snap = toJobSnap(done[0]);
    try oh.snap(@src(),
        \\app.bg.JobSnap
        \\  .id: u64 = 1
        \\  .state: []const u8
        \\    "exited"
        \\  .code: ?i32
        \\    7
        \\  .cmd: []const u8
        \\    "printf 'bad'; exit 7"
        \\  .has_log: bool = true
    ).expectEqual(snap);
}

test "bg manager view handles missing ids" {
    var mgr = try Mgr.init(std.testing.allocator);
    defer mgr.deinit();

    try std.testing.expect((try mgr.view(std.testing.allocator, 1)) == null);

    const id = try mgr.start("sleep 1", null);
    const view = (try mgr.view(std.testing.allocator, id)) orelse return error.TestUnexpectedResult;
    defer deinitView(std.testing.allocator, view);
    try std.testing.expectEqual(id, view.id);

    try std.testing.expect((try mgr.view(std.testing.allocator, id + 9999)) == null);
}

test "bg manager drainDone is empty after first drain" {
    var mgr = try Mgr.init(std.testing.allocator);
    defer mgr.deinit();

    _ = try mgr.start("printf x", null);
    const woke = try waitWake(mgr.wakeFd(), 5000);
    try std.testing.expect(woke);

    const first = try mgr.drainDone(std.testing.allocator);
    defer deinitViews(std.testing.allocator, first);
    try std.testing.expectEqual(@as(usize, 1), first.len);

    const second = try mgr.drainDone(std.testing.allocator);
    defer deinitViews(std.testing.allocator, second);
    try std.testing.expectEqual(@as(usize, 0), second.len);
}

test "bg manager stop reports already_done after completion" {
    var mgr = try Mgr.init(std.testing.allocator);
    defer mgr.deinit();

    const id = try mgr.start("printf done", null);
    const woke = try waitWake(mgr.wakeFd(), 5000);
    try std.testing.expect(woke);

    const done = try mgr.drainDone(std.testing.allocator);
    defer deinitViews(std.testing.allocator, done);
    try std.testing.expectEqual(@as(usize, 1), done.len);
    try std.testing.expectEqual(id, done[0].id);

    const stop = try mgr.stop(id);
    try std.testing.expect(stop == .already_done);
}

test "bg manager stop sends termination signal" {
    var mgr = try Mgr.init(std.testing.allocator);
    defer mgr.deinit();

    const id = try mgr.start("sleep 5", null);
    const stop = try mgr.stop(id);
    try std.testing.expect(stop == .sent or stop == .already_done);

    try std.testing.expect((try mgr.stop(999999)) == .not_found);
}
