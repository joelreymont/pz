const std = @import("std");
const sid_path = @import("path.zig");

const jsonl_ext = ".jsonl";

pub const Plan = struct {
    sid: []u8,
    dir_path: []u8,

    pub fn deinit(self: *Plan, alloc: std.mem.Allocator) void {
        alloc.free(self.sid);
        alloc.free(self.dir_path);
        self.* = undefined;
    }
};

pub fn latestInDir(alloc: std.mem.Allocator, base_dir: []const u8) !Plan {
    var dir = std.fs.cwd().openDir(base_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return error.SessionNotFound,
        else => return err,
    };
    defer dir.close();

    const sid = try latestSidAlloc(alloc, dir);
    errdefer alloc.free(sid);
    return .{
        .sid = sid,
        .dir_path = try alloc.dupe(u8, base_dir),
    };
}

pub fn fromIdOrPrefix(alloc: std.mem.Allocator, base_dir: []const u8, tok: []const u8) !Plan {
    try sid_path.validateSid(tok);

    var dir = std.fs.cwd().openDir(base_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return error.SessionNotFound,
        else => return err,
    };
    defer dir.close();

    const exact_file = try sid_path.sidJsonlAlloc(alloc, tok);
    defer alloc.free(exact_file);

    const has_exact = blk: {
        dir.access(exact_file, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => return err,
        };
        break :blk true;
    };
    if (has_exact) {
        return .{
            .sid = try alloc.dupe(u8, tok),
            .dir_path = try alloc.dupe(u8, base_dir),
        };
    }

    var matched_sid: ?[]u8 = null;
    defer if (matched_sid) |v| alloc.free(v);

    var it = dir.iterate();
    while (try it.next()) |ent| {
        if (ent.kind != .file) continue;
        const sid = fileSid(ent.name) orelse continue;
        if (!std.mem.startsWith(u8, sid, tok)) continue;

        if (matched_sid != null) return error.AmbiguousSession;
        matched_sid = try alloc.dupe(u8, sid);
    }

    const sid = matched_sid orelse return error.SessionNotFound;
    matched_sid = null;
    return .{
        .sid = sid,
        .dir_path = try alloc.dupe(u8, base_dir),
    };
}

pub fn fromPath(alloc: std.mem.Allocator, raw_path: []const u8) !Plan {
    if (raw_path.len == 0) return error.InvalidSessionPath;

    const dir_path = std.fs.path.dirname(raw_path) orelse ".";
    const base = std.fs.path.basename(raw_path);
    if (base.len == 0) return error.InvalidSessionPath;

    const sid = if (std.mem.endsWith(u8, base, jsonl_ext))
        base[0 .. base.len - jsonl_ext.len]
    else
        base;
    if (sid.len == 0) return error.InvalidSessionPath;
    try sid_path.validateSid(sid);

    const file_path = if (std.mem.endsWith(u8, base, jsonl_ext))
        try alloc.dupe(u8, raw_path)
    else blk: {
        const sid_file = try sid_path.sidJsonlAlloc(alloc, sid);
        defer alloc.free(sid_file);
        break :blk try std.fs.path.join(alloc, &.{ dir_path, sid_file });
    };
    defer alloc.free(file_path);

    if (std.fs.path.isAbsolute(file_path)) {
        std.fs.accessAbsolute(file_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return error.SessionNotFound,
            else => return err,
        };
    } else {
        std.fs.cwd().access(file_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return error.SessionNotFound,
            else => return err,
        };
    }

    return .{
        .sid = try alloc.dupe(u8, sid),
        .dir_path = try alloc.dupe(u8, dir_path),
    };
}

fn latestSidAlloc(alloc: std.mem.Allocator, dir: std.fs.Dir) ![]u8 {
    const Mtime = @TypeOf((@as(std.fs.File.Stat, undefined)).mtime);
    var best_sid: ?[]u8 = null;
    defer if (best_sid) |v| alloc.free(v);
    var best_mtime: ?Mtime = null;

    var it = dir.iterate();
    while (try it.next()) |ent| {
        if (ent.kind != .file) continue;
        const sid = fileSid(ent.name) orelse continue;
        sid_path.validateSid(sid) catch continue;

        const st = try dir.statFile(ent.name);
        const better = if (best_sid == null)
            true
        else if (st.mtime > best_mtime.?)
            true
        else if (st.mtime == best_mtime.? and std.mem.order(u8, sid, best_sid.?) == .gt)
            true
        else
            false;
        if (!better) continue;

        if (best_sid) |v| alloc.free(v);
        best_sid = try alloc.dupe(u8, sid);
        best_mtime = st.mtime;
    }

    const sid = best_sid orelse return error.SessionNotFound;
    best_sid = null;
    return sid;
}

fn fileSid(name: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, name, jsonl_ext)) return null;
    if (name.len <= jsonl_ext.len) return null;
    return name[0 .. name.len - jsonl_ext.len];
}

test "latest selector picks newest session and falls back deterministically" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "100.jsonl",
        .data = "{\"version\":1,\"at_ms\":1,\"data\":{\"prompt\":{\"text\":\"a\"}}}\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "200.jsonl",
        .data = "{\"version\":1,\"at_ms\":1,\"data\":{\"prompt\":{\"text\":\"b\"}}}\n",
    });

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var plan = try latestInDir(std.testing.allocator, dir_path);
    defer plan.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("200", plan.sid);
    try std.testing.expectEqualStrings(dir_path, plan.dir_path);
}

test "id selector resolves exact id and unique prefix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "abc123.jsonl",
        .data = "{}\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "def456.jsonl",
        .data = "{}\n",
    });

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var exact = try fromIdOrPrefix(std.testing.allocator, dir_path, "abc123");
    defer exact.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("abc123", exact.sid);

    var pref = try fromIdOrPrefix(std.testing.allocator, dir_path, "def");
    defer pref.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("def456", pref.sid);

    try std.testing.expectError(error.SessionNotFound, fromIdOrPrefix(std.testing.allocator, dir_path, "zzz"));
}

test "id selector rejects ambiguous prefix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "aa1.jsonl",
        .data = "{}\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "aa2.jsonl",
        .data = "{}\n",
    });

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    try std.testing.expectError(error.AmbiguousSession, fromIdOrPrefix(std.testing.allocator, dir_path, "aa"));
}

test "path selector resolves sid and directory from jsonl path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("sess");
    try tmp.dir.writeFile(.{
        .sub_path = "sess/sid-1.jsonl",
        .data = "{}\n",
    });

    const file_abs = try tmp.dir.realpathAlloc(std.testing.allocator, "sess/sid-1.jsonl");
    defer std.testing.allocator.free(file_abs);
    const dir_abs = std.fs.path.dirname(file_abs) orelse return error.TestUnexpectedResult;

    var plan = try fromPath(std.testing.allocator, file_abs);
    defer plan.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("sid-1", plan.sid);
    try std.testing.expectEqualStrings(dir_abs, plan.dir_path);

    const missing_abs = try tmp.dir.realpathAlloc(std.testing.allocator, "sess");
    defer std.testing.allocator.free(missing_abs);
    const missing_file = try std.fs.path.join(std.testing.allocator, &.{ missing_abs, "missing.jsonl" });
    defer std.testing.allocator.free(missing_file);
    try std.testing.expectError(error.SessionNotFound, fromPath(std.testing.allocator, missing_file));
}
