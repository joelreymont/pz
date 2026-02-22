const std = @import("std");
const schema = @import("schema.zig");
const reader_mod = @import("reader.zig");
const sid_path = @import("path.zig");

/// Export a session to markdown.
/// Returns the absolute path to the written file (caller owns).
pub fn toMarkdown(
    alloc: std.mem.Allocator,
    dir: std.fs.Dir,
    sid: []const u8,
    out_path: ?[]const u8,
) ![]u8 {
    var rdr = try reader_mod.ReplayReader.init(alloc, dir, sid, .{});
    defer rdr.deinit();

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);

    // Header
    try buf.appendSlice(alloc, "# Session ");
    try buf.appendSlice(alloc, sid);
    try buf.appendSlice(alloc, "\n\n");

    var in_tool = false;
    while (try rdr.next()) |ev| {
        switch (ev.data) {
            .prompt => |p| {
                if (in_tool) {
                    try buf.appendSlice(alloc, "```\n\n");
                    in_tool = false;
                }
                try buf.appendSlice(alloc, "## User\n\n");
                try buf.appendSlice(alloc, p.text);
                try buf.appendSlice(alloc, "\n\n");
            },
            .text => |t| {
                if (in_tool) {
                    try buf.appendSlice(alloc, "```\n\n");
                    in_tool = false;
                }
                try buf.appendSlice(alloc, "## Assistant\n\n");
                try buf.appendSlice(alloc, t.text);
                try buf.appendSlice(alloc, "\n\n");
            },
            .thinking => |t| {
                if (in_tool) {
                    try buf.appendSlice(alloc, "```\n\n");
                    in_tool = false;
                }
                try buf.appendSlice(alloc, "<details><summary>Thinking</summary>\n\n");
                try buf.appendSlice(alloc, t.text);
                try buf.appendSlice(alloc, "\n\n</details>\n\n");
            },
            .tool_call => |tc| {
                if (in_tool) {
                    try buf.appendSlice(alloc, "```\n\n");
                }
                try buf.appendSlice(alloc, "### Tool: ");
                try buf.appendSlice(alloc, tc.name);
                try buf.appendSlice(alloc, "\n\n```\n");
                in_tool = true;
                try buf.appendSlice(alloc, tc.args);
                try buf.appendSlice(alloc, "\n");
            },
            .tool_result => |tr| {
                if (tr.is_err) {
                    try buf.appendSlice(alloc, "ERROR: ");
                }
                // Truncate very long tool output
                const max_out = 2000;
                if (tr.out.len > max_out) {
                    try buf.appendSlice(alloc, tr.out[0..max_out]);
                    const trunc_msg = try std.fmt.allocPrint(alloc, "\n... ({d} bytes truncated)", .{tr.out.len - max_out});
                    defer alloc.free(trunc_msg);
                    try buf.appendSlice(alloc, trunc_msg);
                } else {
                    try buf.appendSlice(alloc, tr.out);
                }
                try buf.appendSlice(alloc, "\n");
            },
            .err => |e| {
                if (in_tool) {
                    try buf.appendSlice(alloc, "```\n\n");
                    in_tool = false;
                }
                try buf.appendSlice(alloc, "> **Error:** ");
                try buf.appendSlice(alloc, e.text);
                try buf.appendSlice(alloc, "\n\n");
            },
            .usage, .stop, .noop => {},
        }
    }
    if (in_tool) {
        try buf.appendSlice(alloc, "```\n\n");
    }

    // Determine output path (resolve relative to cwd)
    const dest = if (out_path) |p| blk: {
        if (std.fs.path.isAbsolute(p)) {
            break :blk try alloc.dupe(u8, p);
        }
        const cwd = try std.fs.cwd().realpathAlloc(alloc, ".");
        defer alloc.free(cwd);
        break :blk try std.fs.path.join(alloc, &.{ cwd, p });
    } else blk: {
        const fname = try sid_path.sidExtAlloc(alloc, sid, ".md");
        defer alloc.free(fname);
        // Write next to the session directory
        const real = try dir.realpathAlloc(alloc, ".");
        defer alloc.free(real);
        break :blk try std.fs.path.join(alloc, &.{ real, fname });
    };
    errdefer alloc.free(dest);

    // Write file
    const file = try std.fs.createFileAbsolute(dest, .{ .truncate = true });
    defer file.close();
    try file.writeAll(buf.items);

    return dest;
}

test "export session to markdown" {
    const writer_mod = @import("writer.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var wr = try writer_mod.Writer.init(std.testing.allocator, tmp.dir, .{
        .flush = .{ .always = {} },
    });

    try wr.append("ex1", .{ .at_ms = 1, .data = .{ .prompt = .{ .text = "hello" } } });
    try wr.append("ex1", .{ .at_ms = 2, .data = .{ .text = .{ .text = "Hi there!" } } });
    try wr.append("ex1", .{ .at_ms = 3, .data = .{ .tool_call = .{ .id = "c1", .name = "bash", .args = "ls -la" } } });
    try wr.append("ex1", .{ .at_ms = 4, .data = .{ .tool_result = .{ .id = "c1", .out = "file.txt\ndir/", .is_err = false } } });
    try wr.append("ex1", .{ .at_ms = 5, .data = .{ .stop = .{ .reason = .done } } });

    // Export to a specific path
    const real = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(real);
    const dest = try std.fs.path.join(std.testing.allocator, &.{ real, "out.md" });
    defer std.testing.allocator.free(dest);

    const path = try toMarkdown(std.testing.allocator, tmp.dir, "ex1", dest);
    defer std.testing.allocator.free(path);

    try std.testing.expectEqualStrings(dest, path);

    // Read back and verify
    const content = try std.fs.openFileAbsolute(path, .{ .mode = .read_only });
    defer content.close();
    const md = try content.readToEndAlloc(std.testing.allocator, 64 * 1024);
    defer std.testing.allocator.free(md);

    try std.testing.expect(std.mem.indexOf(u8, md, "# Session ex1") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "## User") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "## Assistant") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "Hi there!") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "### Tool: bash") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "ls -la") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "file.txt") != null);
}

test "export default path uses sid.md" {
    const writer_mod = @import("writer.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var wr = try writer_mod.Writer.init(std.testing.allocator, tmp.dir, .{
        .flush = .{ .always = {} },
    });

    try wr.append("s2", .{ .at_ms = 1, .data = .{ .prompt = .{ .text = "q" } } });
    try wr.append("s2", .{ .at_ms = 2, .data = .{ .text = .{ .text = "a" } } });
    try wr.append("s2", .{ .at_ms = 3, .data = .{ .stop = .{ .reason = .done } } });

    const path = try toMarkdown(std.testing.allocator, tmp.dir, "s2", null);
    defer std.testing.allocator.free(path);

    // Should end with s2.md
    try std.testing.expect(std.mem.endsWith(u8, path, "s2.md"));

    // File should exist
    const f = try std.fs.openFileAbsolute(path, .{ .mode = .read_only });
    f.close();
}
