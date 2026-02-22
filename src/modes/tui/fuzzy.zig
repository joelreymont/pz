const std = @import("std");

/// Fuzzy match scoring (lower = better, null = no match).
/// Matches query chars in order within text, scoring based on
/// consecutive matches, gaps, word boundaries, and position.
pub fn score(query: []const u8, txt: []const u8) ?i32 {
    if (query.len == 0) return 0;
    if (txt.len == 0) return null;

    var qi: usize = 0; // query byte index
    var s: i32 = 0;
    var last_match: ?usize = null;
    var consec: i32 = 0;

    const q_lower = toLowerByte(query[qi]);

    var i: usize = 0;
    var qc = q_lower;
    while (i < txt.len) : (i += 1) {
        const tc = toLowerByte(txt[i]);
        if (tc != qc) continue;

        // Match found
        if (last_match) |lm| {
            if (i == lm + 1) {
                consec += 1;
                s -= consec * 5;
            } else {
                consec = 0;
                const gap: i32 = @intCast(i - lm - 1);
                s += gap * 2;
            }
        }

        // Word boundary bonus
        if (i > 0 and isWordBoundary(txt[i - 1])) {
            s -= 10;
        } else if (i == 0) {
            s -= 10; // start of string counts as boundary
        }

        // Position penalty
        s += @divTrunc(@as(i32, @intCast(i)), 10);

        last_match = i;
        qi += 1;
        if (qi >= query.len) return s;
        qc = toLowerByte(query[qi]);
    }

    return null; // not all query chars matched
}

fn isWordBoundary(c: u8) bool {
    return c == ' ' or c == '-' or c == '_' or c == '.' or c == '/' or c == ':';
}

fn toLowerByte(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

// -- Tests --

test "exact match scores well" {
    const s = score("help", "help").?;
    try std.testing.expect(s < 0); // good score (bonuses)
}

test "prefix match" {
    const s = score("he", "help").?;
    try std.testing.expect(s < 0);
}

test "no match returns null" {
    try std.testing.expect(score("xyz", "help") == null);
}

test "fuzzy match with gaps" {
    const s = score("mdl", "model").?;
    // m-d-l matches m..d.l in "model" (gap penalty but still matches)
    try std.testing.expect(s != 0);
}

test "word boundary bonus" {
    // "sc" in "slash-command" should score better than in "disco"
    const s1 = score("sc", "slash-command").?;
    const s2 = score("sc", "disco").?;
    try std.testing.expect(s1 < s2);
}

test "consecutive match bonus" {
    // "hel" in "help" (consecutive) should beat "hel" in "hxexlxp" (gaps, no boundaries)
    const s1 = score("hel", "help").?;
    const s2 = score("hel", "hxexlxp").?;
    try std.testing.expect(s1 < s2);
}

test "case insensitive" {
    const s = score("HELP", "help").?;
    try std.testing.expect(s < 0);
}

test "empty query matches everything" {
    try std.testing.expectEqual(@as(i32, 0), score("", "anything").?);
}

test "empty text returns null" {
    try std.testing.expect(score("a", "") == null);
}
