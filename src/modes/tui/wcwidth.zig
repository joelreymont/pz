const std = @import("std");

/// Display width of a Unicode codepoint.
/// 0 for control chars, 2 for wide/fullwidth, 1 for everything else.
pub fn wcwidth(cp: u21) u2 {
    if (cp < 0x20) return 0;
    if (cp == 0x7f) return 0;
    if (isWide(cp)) return 2;
    return 1;
}

/// String display width in columns, decoding UTF-8.
pub fn strwidth(text: []const u8) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            i += 1;
            w += 1;
            continue;
        };
        if (i + n > text.len) {
            w += 1;
            break;
        }
        const cp = std.unicode.utf8Decode(text[i..][0..n]) catch {
            i += 1;
            w += 1;
            continue;
        };
        w += wcwidth(cp);
        i += n;
    }
    return w;
}

fn isWide(cp: u21) bool {
    // Fast path: ASCII
    if (cp < 0x1100) return false;

    const Range = struct { lo: u21, hi: u21 };
    const ranges = comptime [_]Range{
        .{ .lo = 0x1100, .hi = 0x115F },
        .{ .lo = 0x231A, .hi = 0x231B },
        .{ .lo = 0x2329, .hi = 0x232A },
        .{ .lo = 0x23E9, .hi = 0x23F3 },
        .{ .lo = 0x23F8, .hi = 0x23FA },
        .{ .lo = 0x25FD, .hi = 0x25FE },
        .{ .lo = 0x2614, .hi = 0x2615 },
        .{ .lo = 0x2648, .hi = 0x2653 },
        .{ .lo = 0x267F, .hi = 0x267F },
        .{ .lo = 0x2693, .hi = 0x2693 },
        .{ .lo = 0x26A1, .hi = 0x26A1 },
        .{ .lo = 0x26AA, .hi = 0x26AB },
        .{ .lo = 0x26BD, .hi = 0x26BE },
        .{ .lo = 0x26C4, .hi = 0x26C5 },
        .{ .lo = 0x26CE, .hi = 0x26CE },
        .{ .lo = 0x26D4, .hi = 0x26D4 },
        .{ .lo = 0x26EA, .hi = 0x26EA },
        .{ .lo = 0x26F2, .hi = 0x26F3 },
        .{ .lo = 0x26F5, .hi = 0x26F5 },
        .{ .lo = 0x26FA, .hi = 0x26FA },
        .{ .lo = 0x26FD, .hi = 0x26FD },
        .{ .lo = 0x2702, .hi = 0x2702 },
        .{ .lo = 0x2705, .hi = 0x2705 },
        .{ .lo = 0x2708, .hi = 0x270D },
        .{ .lo = 0x270F, .hi = 0x270F },
        .{ .lo = 0x2712, .hi = 0x2712 },
        .{ .lo = 0x2714, .hi = 0x2714 },
        .{ .lo = 0x2716, .hi = 0x2716 },
        .{ .lo = 0x271D, .hi = 0x271D },
        .{ .lo = 0x2721, .hi = 0x2721 },
        .{ .lo = 0x2728, .hi = 0x2728 },
        .{ .lo = 0x2733, .hi = 0x2734 },
        .{ .lo = 0x2744, .hi = 0x2744 },
        .{ .lo = 0x2747, .hi = 0x2747 },
        .{ .lo = 0x274C, .hi = 0x274C },
        .{ .lo = 0x274E, .hi = 0x274E },
        .{ .lo = 0x2753, .hi = 0x2755 },
        .{ .lo = 0x2757, .hi = 0x2757 },
        .{ .lo = 0x2763, .hi = 0x2764 },
        .{ .lo = 0x2795, .hi = 0x2797 },
        .{ .lo = 0x27A1, .hi = 0x27A1 },
        .{ .lo = 0x27B0, .hi = 0x27B0 },
        .{ .lo = 0x27BF, .hi = 0x27BF },
        .{ .lo = 0x2934, .hi = 0x2935 },
        .{ .lo = 0x2B05, .hi = 0x2B07 },
        .{ .lo = 0x2B1B, .hi = 0x2B1C },
        .{ .lo = 0x2B50, .hi = 0x2B50 },
        .{ .lo = 0x2B55, .hi = 0x2B55 },
        .{ .lo = 0x2E80, .hi = 0x303E },
        .{ .lo = 0x3041, .hi = 0x3247 },
        .{ .lo = 0x3250, .hi = 0x4DBF },
        .{ .lo = 0x4E00, .hi = 0x9FFF },
        .{ .lo = 0xA000, .hi = 0xA4CF },
        .{ .lo = 0xA960, .hi = 0xA97C },
        .{ .lo = 0xAC00, .hi = 0xD7AF },
        .{ .lo = 0xF900, .hi = 0xFAFF },
        .{ .lo = 0xFE10, .hi = 0xFE19 },
        .{ .lo = 0xFE30, .hi = 0xFE6F },
        .{ .lo = 0xFF01, .hi = 0xFF60 },
        .{ .lo = 0xFFE0, .hi = 0xFFE6 },
        .{ .lo = 0x1F004, .hi = 0x1F004 },
        .{ .lo = 0x1F0CF, .hi = 0x1F0CF },
        .{ .lo = 0x1F18E, .hi = 0x1F18E },
        .{ .lo = 0x1F191, .hi = 0x1F19A },
        .{ .lo = 0x1F1E0, .hi = 0x1F1FF },
        .{ .lo = 0x1F200, .hi = 0x1F202 },
        .{ .lo = 0x1F210, .hi = 0x1F23B },
        .{ .lo = 0x1F240, .hi = 0x1F248 },
        .{ .lo = 0x1F250, .hi = 0x1F251 },
        .{ .lo = 0x1F260, .hi = 0x1F265 },
        .{ .lo = 0x1F300, .hi = 0x1F320 },
        .{ .lo = 0x1F32D, .hi = 0x1F335 },
        .{ .lo = 0x1F337, .hi = 0x1F37C },
        .{ .lo = 0x1F37E, .hi = 0x1F393 },
        .{ .lo = 0x1F3A0, .hi = 0x1F3CA },
        .{ .lo = 0x1F3CF, .hi = 0x1F3D3 },
        .{ .lo = 0x1F3E0, .hi = 0x1F3F0 },
        .{ .lo = 0x1F3F4, .hi = 0x1F3F4 },
        .{ .lo = 0x1F3F8, .hi = 0x1F43E },
        .{ .lo = 0x1F440, .hi = 0x1F440 },
        .{ .lo = 0x1F442, .hi = 0x1F4FC },
        .{ .lo = 0x1F4FF, .hi = 0x1F53D },
        .{ .lo = 0x1F54B, .hi = 0x1F54E },
        .{ .lo = 0x1F550, .hi = 0x1F567 },
        .{ .lo = 0x1F57A, .hi = 0x1F57A },
        .{ .lo = 0x1F595, .hi = 0x1F596 },
        .{ .lo = 0x1F5A4, .hi = 0x1F5A4 },
        .{ .lo = 0x1F5FB, .hi = 0x1F64F },
        .{ .lo = 0x1F680, .hi = 0x1F6C5 },
        .{ .lo = 0x1F6CC, .hi = 0x1F6CC },
        .{ .lo = 0x1F6D0, .hi = 0x1F6D2 },
        .{ .lo = 0x1F6D5, .hi = 0x1F6D7 },
        .{ .lo = 0x1F6EB, .hi = 0x1F6EC },
        .{ .lo = 0x1F6F4, .hi = 0x1F6FC },
        .{ .lo = 0x1F7E0, .hi = 0x1F7EB },
        .{ .lo = 0x1F90C, .hi = 0x1F93A },
        .{ .lo = 0x1F93C, .hi = 0x1F945 },
        .{ .lo = 0x1F947, .hi = 0x1F978 },
        .{ .lo = 0x1F97A, .hi = 0x1F9CB },
        .{ .lo = 0x1F9CD, .hi = 0x1F9FF },
        .{ .lo = 0x1FA70, .hi = 0x1FA74 },
        .{ .lo = 0x1FA78, .hi = 0x1FA7A },
        .{ .lo = 0x1FA80, .hi = 0x1FA86 },
        .{ .lo = 0x1FA90, .hi = 0x1FAA8 },
        .{ .lo = 0x1FAB0, .hi = 0x1FAB6 },
        .{ .lo = 0x1FAC0, .hi = 0x1FAC2 },
        .{ .lo = 0x1FAD0, .hi = 0x1FAD6 },
        .{ .lo = 0x20000, .hi = 0x2FFFD },
        .{ .lo = 0x30000, .hi = 0x3FFFD },
    };

    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cp > ranges[mid].hi) {
            lo = mid + 1;
        } else if (cp < ranges[mid].lo) {
            hi = mid;
        } else {
            return true;
        }
    }
    return false;
}

// ── Tests ──────────────────────────────────────────────────────────────

test "wcwidth: ASCII printable" {
    try std.testing.expectEqual(@as(u2, 1), wcwidth('A'));
    try std.testing.expectEqual(@as(u2, 1), wcwidth(' '));
    try std.testing.expectEqual(@as(u2, 1), wcwidth('~'));
}

test "wcwidth: control chars" {
    try std.testing.expectEqual(@as(u2, 0), wcwidth(0));
    try std.testing.expectEqual(@as(u2, 0), wcwidth('\n'));
    try std.testing.expectEqual(@as(u2, 0), wcwidth(0x7f));
}

test "wcwidth: CJK ideograph" {
    // U+4E2D = '中'
    try std.testing.expectEqual(@as(u2, 2), wcwidth(0x4E2D));
    // U+3042 = 'あ' (Hiragana)
    try std.testing.expectEqual(@as(u2, 2), wcwidth(0x3042));
    // U+AC00 = '가' (Hangul)
    try std.testing.expectEqual(@as(u2, 2), wcwidth(0xAC00));
}

test "wcwidth: fullwidth forms" {
    // U+FF21 = 'Ａ' (Fullwidth A)
    try std.testing.expectEqual(@as(u2, 2), wcwidth(0xFF21));
    // U+FF01 = '！' (Fullwidth !)
    try std.testing.expectEqual(@as(u2, 2), wcwidth(0xFF01));
}

test "wcwidth: emoji" {
    // U+1F600 range
    try std.testing.expectEqual(@as(u2, 2), wcwidth(0x1F600));
    // U+2764 heart
    try std.testing.expectEqual(@as(u2, 2), wcwidth(0x2764));
}

test "wcwidth: Latin extended" {
    // U+00E9 = 'é'
    try std.testing.expectEqual(@as(u2, 1), wcwidth(0x00E9));
    // U+03B2 = 'β'
    try std.testing.expectEqual(@as(u2, 1), wcwidth(0x03B2));
}

test "wcwidth: CJK Extension B" {
    try std.testing.expectEqual(@as(u2, 2), wcwidth(0x20000));
    try std.testing.expectEqual(@as(u2, 2), wcwidth(0x2A6D6));
}

test "strwidth: ASCII" {
    try std.testing.expectEqual(@as(usize, 5), strwidth("hello"));
}

test "strwidth: CJK" {
    // "中文" = 2 chars * 2 cols = 4
    try std.testing.expectEqual(@as(usize, 4), strwidth("中文"));
}

test "strwidth: mixed ASCII + CJK" {
    // "hi中" = 2 + 2 = 4
    try std.testing.expectEqual(@as(usize, 4), strwidth("hi中"));
}

test "strwidth: empty" {
    try std.testing.expectEqual(@as(usize, 0), strwidth(""));
}

test "strwidth: invalid UTF-8 fallback" {
    const bad = [_]u8{ 0xff, 0xfe };
    try std.testing.expectEqual(@as(usize, 2), strwidth(&bad));
}
