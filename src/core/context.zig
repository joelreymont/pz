const std = @import("std");

/// Discover and load AGENTS.md / CLAUDE.md context files.
/// Searches global dir, then walks cwd upward to root.
/// Returns concatenated content with section headers.
pub fn load(alloc: std.mem.Allocator) !?[]u8 {
    var parts = std.ArrayListUnmanaged([]u8){};
    defer {
        for (parts.items) |p| alloc.free(p);
        parts.deinit(alloc);
    }

    // Global: ~/.pz/AGENTS.md or ~/.pz/CLAUDE.md
    if (globalDir(alloc)) |gdir| {
        defer alloc.free(gdir);
        if (readContext(alloc, gdir)) |content| {
            try parts.append(alloc, content);
        }
    }

    // Walk cwd upward
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.process.getCwd(&cwd_buf) catch return assembleParts(alloc, parts.items);

    var dir: []const u8 = cwd;
    while (true) {
        if (readContext(alloc, dir)) |content| {
            try parts.append(alloc, content);
        }
        if (parent(dir)) |p| {
            dir = p;
        } else break;
    }

    return assembleParts(alloc, parts.items);
}

fn assembleParts(alloc: std.mem.Allocator, parts: []const []u8) !?[]u8 {
    if (parts.len == 0) return null;

    var total: usize = 0;
    for (parts) |p| total += p.len + 2; // \n\n separator
    if (total >= 2) total -= 2; // no trailing separator

    const buf = try alloc.alloc(u8, total);
    var off: usize = 0;
    for (parts, 0..) |p, i| {
        if (i > 0) {
            buf[off] = '\n';
            buf[off + 1] = '\n';
            off += 2;
        }
        @memcpy(buf[off .. off + p.len], p);
        off += p.len;
    }
    return buf;
}

fn globalDir(alloc: std.mem.Allocator) ?[]u8 {
    const home = std.process.getEnvVarOwned(alloc, "HOME") catch return null;
    defer alloc.free(home);
    return std.fmt.allocPrint(alloc, "{s}/.pz", .{home}) catch return null;
}

fn readContext(alloc: std.mem.Allocator, dir: []const u8) ?[]u8 {
    return readFile(alloc, dir, "AGENTS.md") orelse readFile(alloc, dir, "CLAUDE.md");
}

fn readFile(alloc: std.mem.Allocator, dir: []const u8, name: []const u8) ?[]u8 {
    const path = std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, name }) catch return null;
    defer alloc.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    const content = file.readToEndAlloc(alloc, 1024 * 1024) catch return null;
    if (content.len == 0) {
        alloc.free(content);
        return null;
    }

    // Wrap with section header
    const header = std.fmt.allocPrint(alloc, "## {s}\n\n", .{path}) catch {
        alloc.free(content);
        return null;
    };
    defer alloc.free(header);

    const result = std.fmt.allocPrint(alloc, "{s}{s}", .{ header, content }) catch {
        alloc.free(content);
        return null;
    };
    alloc.free(content);
    return result;
}

fn parent(path: []const u8) ?[]const u8 {
    if (path.len <= 1) return null;
    const idx = std.mem.lastIndexOfScalar(u8, path, '/') orelse return null;
    if (idx == 0) return null;
    return path[0..idx];
}

test "parent extracts directory" {
    try std.testing.expectEqualStrings("/foo", parent("/foo/bar").?);
    try std.testing.expectEqualStrings("/foo/bar", parent("/foo/bar/baz").?);
    try std.testing.expect(parent("/") == null);
    try std.testing.expect(parent("/foo") == null);
}

test "assembleParts joins with newlines" {
    const parts = [_][]u8{
        @constCast("aaa"),
        @constCast("bbb"),
    };
    const result = (try assembleParts(std.testing.allocator, parts[0..])).?;
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("aaa\n\nbbb", result);
}

test "assembleParts empty returns null" {
    const result = try assembleParts(std.testing.allocator, &.{});
    try std.testing.expect(result == null);
}
