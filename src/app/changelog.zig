const std = @import("std");
const build_options = @import("build_options");

pub const log = build_options.changelog;

/// Return the portion of the embedded log that is newer than `last_hash`.
/// If `last_hash` is null (first run), returns empty (don't flood).
/// If `last_hash` is not found, returns entire log (treat as very old build).
pub fn entriesSince(last_hash: ?[]const u8) []const u8 {
    const hash = last_hash orelse return "";
    if (hash.len == 0) return "";

    var off: usize = 0;
    while (off < log.len) {
        const eol = std.mem.indexOfScalarPos(u8, log, off, '\n') orelse log.len;
        const line = log[off..eol];
        // Each line starts with short hash
        if (line.len >= hash.len and std.mem.startsWith(u8, line, hash)) {
            // Found the last-seen commit — everything before is new
            return if (off == 0) "" else log[0 .. off - 1];
        }
        off = eol + 1;
    }
    // Hash not found — return all entries
    return log;
}

/// Format the embedded log for display, prefixing each line.
/// Returns owned slice. Caller frees.
pub fn formatForDisplay(alloc: std.mem.Allocator, max_entries: usize) ![]u8 {
    if (log.len == 0) return try alloc.dupe(u8, "No changes.");

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);

    var count: usize = 0;
    var off: usize = 0;
    while (off < log.len and count < max_entries) {
        const eol = std.mem.indexOfScalarPos(u8, log, off, '\n') orelse log.len;
        const line = log[off..eol];
        if (line.len > 0) {
            if (count > 0) try out.append(alloc, '\n');
            try out.appendSlice(alloc, "  ");
            try out.appendSlice(alloc, line);
            count += 1;
        }
        off = eol + 1;
    }

    if (out.items.len == 0) return try alloc.dupe(u8, "No changes.");
    return try out.toOwnedSlice(alloc);
}

/// Format a subset of the log (raw text, not the full log).
pub fn formatRaw(alloc: std.mem.Allocator, raw: []const u8, max_entries: usize) ![]u8 {
    if (raw.len == 0) return try alloc.dupe(u8, "No changes.");

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);

    var count: usize = 0;
    var off: usize = 0;
    while (off < raw.len and count < max_entries) {
        const eol = std.mem.indexOfScalarPos(u8, raw, off, '\n') orelse raw.len;
        const line = raw[off..eol];
        if (line.len > 0) {
            if (count > 0) try out.append(alloc, '\n');
            try out.appendSlice(alloc, "  ");
            try out.appendSlice(alloc, line);
            count += 1;
        }
        off = eol + 1;
    }

    if (out.items.len == 0) return try alloc.dupe(u8, "No changes.");
    return try out.toOwnedSlice(alloc);
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "entriesSince null returns empty" {
    try testing.expectEqualStrings("", entriesSince(null));
}

test "entriesSince empty hash returns empty" {
    try testing.expectEqualStrings("", entriesSince(""));
}

test "entriesSince matching first line returns empty" {
    // The first line's hash = first 7 chars of log
    if (log.len < 7) return;
    const first_hash = log[0..7];
    try testing.expectEqualStrings("", entriesSince(first_hash));
}

test "entriesSince nonexistent hash returns all" {
    const result = entriesSince("zzzzzzzz_no_match");
    try testing.expectEqualStrings(log, result);
}

test "formatForDisplay respects max_entries" {
    const result = try formatForDisplay(testing.allocator, 2);
    defer testing.allocator.free(result);
    // Count lines
    var lines: usize = 1;
    for (result) |c| {
        if (c == '\n') lines += 1;
    }
    try testing.expect(lines <= 2);
}

test "formatRaw formats correctly" {
    const raw = "abc Fix thing\ndef Another fix";
    const result = try formatRaw(testing.allocator, raw, 10);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.startsWith(u8, result, "  abc Fix thing"));
}

test "formatRaw empty returns no changes" {
    const result = try formatRaw(testing.allocator, "", 10);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("No changes.", result);
}
