const builtin = @import("builtin");
const std = @import("std");

pub const Active = struct {
    id: u64,
    pid: i32,
    cmd: []u8,
    log_path: []u8,
    started_at_ms: i64,
};

pub fn deinitActives(alloc: std.mem.Allocator, actives: []Active) void {
    for (actives) |a| {
        alloc.free(a.cmd);
        alloc.free(a.log_path);
    }
    alloc.free(actives);
}

pub const Opts = struct {
    state_dir: ?[]const u8 = null,
    enabled: ?bool = null,
};

pub const Journal = struct {
    alloc: std.mem.Allocator,
    dir_path: ?[]u8 = null,
    file_path: ?[]u8 = null,
    file: ?std.fs.File = null,
    mu: std.Thread.Mutex = .{},

    pub fn init(alloc: std.mem.Allocator, opts: Opts) !Journal {
        const enabled = opts.enabled orelse !builtin.is_test;
        if (!enabled and opts.state_dir == null) {
            return .{ .alloc = alloc };
        }

        const base_dir = if (opts.state_dir) |override|
            try alloc.dupe(u8, override)
        else
            try resolveStateDir(alloc);
        defer alloc.free(base_dir);

        std.fs.makeDirAbsolute(base_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const pz_dir = try std.fs.path.join(alloc, &.{ base_dir, "pz" });
        defer alloc.free(pz_dir);
        std.fs.makeDirAbsolute(pz_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const jobs_dir = try std.fs.path.join(alloc, &.{ pz_dir, "jobs" });
        errdefer alloc.free(jobs_dir);
        std.fs.makeDirAbsolute(jobs_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const events_path = try std.fs.path.join(alloc, &.{ jobs_dir, "events.jsonl" });
        errdefer alloc.free(events_path);

        const f = std.fs.createFileAbsolute(events_path, .{
            .read = true,
            .truncate = false,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => try std.fs.openFileAbsolute(events_path, .{ .mode = .read_write }),
            else => return err,
        };
        try f.seekFromEnd(0);

        return .{
            .alloc = alloc,
            .dir_path = jobs_dir,
            .file_path = events_path,
            .file = f,
        };
    }

    pub fn deinit(self: *Journal) void {
        if (self.file) |f| f.close();
        if (self.file_path) |p| self.alloc.free(p);
        if (self.dir_path) |p| self.alloc.free(p);
        self.* = undefined;
    }

    pub fn appendLaunch(
        self: *Journal,
        id: u64,
        pid: i32,
        cmd: []const u8,
        log_path: []const u8,
        started_at_ms: i64,
    ) !void {
        const line = .{
            .kind = "launch",
            .id = id,
            .pid = pid,
            .cmd = cmd,
            .log_path = log_path,
            .started_at_ms = started_at_ms,
        };
        return self.appendLine(line);
    }

    pub fn appendExit(
        self: *Journal,
        id: u64,
        state: []const u8,
        code: ?i32,
        ended_at_ms: i64,
        err_name: ?[]const u8,
    ) !void {
        const line = .{
            .kind = "exit",
            .id = id,
            .state = state,
            .code = code,
            .ended_at_ms = ended_at_ms,
            .err_name = err_name,
        };
        return self.appendLine(line);
    }

    pub fn appendCleanup(self: *Journal, id: u64, reason: []const u8) !void {
        const line = .{
            .kind = "cleanup",
            .id = id,
            .reason = reason,
        };
        return self.appendLine(line);
    }

    pub fn replayActive(self: *Journal, alloc: std.mem.Allocator) ![]Active {
        const path = self.file_path orelse return alloc.alloc(Active, 0);
        const f = std.fs.openFileAbsolute(path, .{ .mode = .read_only }) catch |err| switch (err) {
            error.FileNotFound => return alloc.alloc(Active, 0),
            else => return err,
        };
        defer f.close();
        const raw = try f.readToEndAlloc(alloc, 8 * 1024 * 1024);
        defer alloc.free(raw);

        var out: std.ArrayListUnmanaged(Active) = .empty;
        errdefer {
            for (out.items) |a| {
                alloc.free(a.cmd);
                alloc.free(a.log_path);
            }
            out.deinit(alloc);
        }

        var it = std.mem.splitScalar(u8, raw, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();
            const aa = arena.allocator();

            const parsed = std.json.parseFromSliceLeaky(Line, aa, line, .{
                .ignore_unknown_fields = true,
            }) catch continue;

            if (std.mem.eql(u8, parsed.kind, "launch")) {
                removeActive(alloc, &out, parsed.id);
                const cmd = try alloc.dupe(u8, parsed.cmd);
                errdefer alloc.free(cmd);
                const log_path = try alloc.dupe(u8, parsed.log_path);
                errdefer alloc.free(log_path);
                try out.append(alloc, .{
                    .id = parsed.id,
                    .pid = parsed.pid,
                    .cmd = cmd,
                    .log_path = log_path,
                    .started_at_ms = parsed.started_at_ms,
                });
                continue;
            }

            if (std.mem.eql(u8, parsed.kind, "exit") or std.mem.eql(u8, parsed.kind, "cleanup")) {
                removeActive(alloc, &out, parsed.id);
            }
        }

        return try out.toOwnedSlice(alloc);
    }

    fn appendLine(self: *Journal, line: anytype) !void {
        const f = self.file orelse return;
        const raw = try std.json.Stringify.valueAlloc(self.alloc, line, .{});
        defer self.alloc.free(raw);

        self.mu.lock();
        defer self.mu.unlock();

        try f.seekFromEnd(0);
        try f.writeAll(raw);
        try f.writeAll("\n");
        try f.sync();
    }
};

const Line = struct {
    kind: []const u8,
    id: u64,
    pid: i32 = 0,
    cmd: []const u8 = "",
    log_path: []const u8 = "",
    started_at_ms: i64 = 0,
};

fn removeActive(alloc: std.mem.Allocator, out: *std.ArrayListUnmanaged(Active), id: u64) void {
    var i: usize = 0;
    while (i < out.items.len) : (i += 1) {
        if (out.items[i].id != id) continue;
        const removed = out.orderedRemove(i);
        alloc.free(removed.cmd);
        alloc.free(removed.log_path);
        return;
    }
}

fn resolveStateDir(alloc: std.mem.Allocator) ![]u8 {
    if (std.posix.getenv("PZ_STATE_DIR")) |state_dir| {
        return alloc.dupe(u8, state_dir);
    }

    if (builtin.os.tag == .macos) {
        const home = std.posix.getenv("HOME") orelse return error.EnvironmentVariableNotFound;
        return std.fs.path.join(alloc, &.{ home, "Library", "Application Support" });
    }

    if (std.posix.getenv("XDG_STATE_HOME")) |xdg_state| {
        return alloc.dupe(u8, xdg_state);
    }

    const home = std.posix.getenv("HOME") orelse return error.EnvironmentVariableNotFound;
    return std.fs.path.join(alloc, &.{ home, ".local", "state" });
}

test "journal replay tracks active launches only" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const abs = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(abs);

    var j = try Journal.init(std.testing.allocator, .{
        .state_dir = abs,
        .enabled = true,
    });
    defer j.deinit();

    try j.appendLaunch(1, 111, "sleep 10", "/tmp/j1.log", 10);
    try j.appendExit(1, "exited", 0, 20, null);
    try j.appendLaunch(2, 222, "sleep 20", "/tmp/j2.log", 30);

    const active = try j.replayActive(std.testing.allocator);
    defer deinitActives(std.testing.allocator, active);

    try std.testing.expectEqual(@as(usize, 1), active.len);
    try std.testing.expectEqual(@as(u64, 2), active[0].id);
    try std.testing.expectEqual(@as(i32, 222), active[0].pid);
    try std.testing.expectEqualStrings("sleep 20", active[0].cmd);
}

test "journal cleanup removes active launch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const abs = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(abs);

    var j = try Journal.init(std.testing.allocator, .{
        .state_dir = abs,
        .enabled = true,
    });
    defer j.deinit();

    try j.appendLaunch(7, 777, "sleep 99", "/tmp/j7.log", 77);
    try j.appendCleanup(7, "startup_reap");

    const active = try j.replayActive(std.testing.allocator);
    defer deinitActives(std.testing.allocator, active);
    try std.testing.expectEqual(@as(usize, 0), active.len);
}

test "journal replay ignores malformed lines" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const abs = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(abs);

    var j = try Journal.init(std.testing.allocator, .{
        .state_dir = abs,
        .enabled = true,
    });
    defer j.deinit();

    const path = j.file_path orelse return error.TestUnexpectedResult;
    const f = try std.fs.openFileAbsolute(path, .{ .mode = .read_write });
    defer f.close();
    try f.seekFromEnd(0);
    try f.writeAll("{bad-json}\n");
    try f.sync();

    try j.appendLaunch(11, 111, "sleep 1", "/tmp/j11.log", 11);

    const active = try j.replayActive(std.testing.allocator);
    defer deinitActives(std.testing.allocator, active);
    try std.testing.expectEqual(@as(usize, 1), active.len);
    try std.testing.expectEqual(@as(u64, 11), active[0].id);
}
