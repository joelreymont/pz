const std = @import("std");

const max_results: usize = 32;

/// List files matching a path prefix. Returns full paths relative to cwd.
/// Caller must free with `freeList`.
pub fn list(alloc: std.mem.Allocator, prefix: []const u8) ?[][]u8 {
    const last_sep = std.mem.lastIndexOfScalar(u8, prefix, '/');
    const dir_path = if (last_sep) |s| (if (s == 0) "/" else prefix[0..s]) else ".";
    const partial = if (last_sep) |s| prefix[s + 1 ..] else prefix;
    const dir_prefix = if (last_sep) |s| prefix[0 .. s + 1] else "";

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return null;
    defer dir.close();

    var names = std.ArrayList([]u8).empty;

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (names.items.len >= max_results) break;
        if (entry.name.len > 0 and entry.name[0] == '.' and (partial.len == 0 or partial[0] != '.')) continue;
        if (partial.len > 0 and !std.mem.startsWith(u8, entry.name, partial)) continue;

        const is_dir = entry.kind == .directory;
        const name = if (is_dir)
            std.fmt.allocPrint(alloc, "{s}{s}/", .{ dir_prefix, entry.name }) catch continue
        else
            std.fmt.allocPrint(alloc, "{s}{s}", .{ dir_prefix, entry.name }) catch continue;

        names.append(alloc, name) catch {
            alloc.free(name);
            continue;
        };
    }

    if (names.items.len == 0) {
        names.deinit(alloc);
        return null;
    }

    std.sort.pdq([]u8, names.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    return names.toOwnedSlice(alloc) catch {
        for (names.items) |n| alloc.free(n);
        names.deinit(alloc);
        return null;
    };
}

pub fn freeList(alloc: std.mem.Allocator, items: [][]u8) void {
    for (items) |item| alloc.free(item);
    alloc.free(items);
}

/// Longest common prefix of all items.
pub fn commonPrefix(items: []const []const u8) []const u8 {
    if (items.len == 0) return "";
    if (items.len == 1) return items[0];
    var n = items[0].len;
    for (items[1..]) |item| {
        var i: usize = 0;
        while (i < n and i < item.len and items[0][i] == item[i]) i += 1;
        n = i;
    }
    return items[0][0..n];
}

/// Cast [][]u8 to []const []const u8.
pub fn asConst(items: [][]u8) []const []const u8 {
    const ptr: [*]const []const u8 = @ptrCast(items.ptr);
    return ptr[0..items.len];
}

// -- Tests --

test "list finds files in src dir" {
    const alloc = std.testing.allocator;
    if (list(alloc, "src/")) |items| {
        defer freeList(alloc, items);
        try std.testing.expect(items.len > 0);
        // All items should start with "src/"
        for (items) |item| {
            try std.testing.expect(std.mem.startsWith(u8, item, "src/"));
        }
    }
}

test "list returns null for nonexistent dir" {
    try std.testing.expect(list(std.testing.allocator, "nonexistent_dir_xyz_42/") == null);
}

test "list with partial name" {
    const alloc = std.testing.allocator;
    // "src/m" should match "src/modes/" at minimum
    if (list(alloc, "src/m")) |items| {
        defer freeList(alloc, items);
        try std.testing.expect(items.len > 0);
        for (items) |item| {
            try std.testing.expect(std.mem.startsWith(u8, item, "src/m"));
        }
    }
}

test "list skips hidden files" {
    const alloc = std.testing.allocator;
    if (list(alloc, "")) |items| {
        defer freeList(alloc, items);
        for (items) |item| {
            try std.testing.expect(item[0] != '.');
        }
    }
}

test "list shows hidden files when prefix starts with dot" {
    const alloc = std.testing.allocator;
    if (list(alloc, ".")) |items| {
        defer freeList(alloc, items);
        try std.testing.expect(items.len > 0);
        for (items) |item| {
            try std.testing.expect(item[0] == '.');
        }
    }
}

test "commonPrefix basic" {
    const items = [_][]const u8{ "abc", "abd", "abe" };
    try std.testing.expectEqualStrings("ab", commonPrefix(&items));
}

test "commonPrefix single" {
    const items = [_][]const u8{"hello"};
    try std.testing.expectEqualStrings("hello", commonPrefix(&items));
}

test "commonPrefix empty" {
    const items = [_][]const u8{};
    try std.testing.expectEqualStrings("", commonPrefix(&items));
}

test "commonPrefix identical" {
    const items = [_][]const u8{ "same", "same", "same" };
    try std.testing.expectEqualStrings("same", commonPrefix(&items));
}

test "commonPrefix with paths" {
    const items = [_][]const u8{ "src/mod.zig", "src/modes/" };
    try std.testing.expectEqualStrings("src/mod", commonPrefix(&items));
}
