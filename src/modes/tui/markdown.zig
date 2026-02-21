const std = @import("std");
const frame = @import("frame.zig");
const theme = @import("theme.zig");
const syntax = @import("syntax.zig");
const wc = @import("wcwidth.zig");

pub const MdRenderer = struct {
    in_code_block: bool = false,
    code_lang: syntax.Lang = .unknown,

    pub const RenderError = frame.Frame.PosError || error{InvalidUtf8};

    /// Advance code-block state for a skipped line (scrolled past).
    pub fn advanceSkipped(self: *MdRenderer, line: []const u8) void {
        if (isFence(line)) {
            if (!self.in_code_block) {
                self.code_lang = syntax.Lang.detect(trimFence(line));
            } else {
                self.code_lang = .unknown;
            }
            self.in_code_block = !self.in_code_block;
        }
    }

    /// Render one line of markdown to frame at (x, y).
    /// Returns number of display columns written.
    pub fn renderLine(self: *MdRenderer, frm: *frame.Frame, x: usize, y: usize, line: []const u8, max_w: usize, base_st: frame.Style) MdRenderer.RenderError!usize {
        if (max_w == 0) return 0;

        // Code fence toggle
        if (isFence(line)) {
            if (!self.in_code_block) {
                self.code_lang = syntax.Lang.detect(trimFence(line));
            } else {
                self.code_lang = .unknown;
            }
            self.in_code_block = !self.in_code_block;
            var st = base_st;
            st.fg = theme.get().md_code_border;
            const trimmed = trimFence(line);
            if (trimmed.len > 0) {
                return try writeStr(frm, x, y, trimmed, max_w, st);
            }
            // Render fence as thin line
            return try fillCh(frm, x, y, max_w, 0x2500, st); // ─
        }

        // Inside code block — syntax highlight
        if (self.in_code_block) {
            var tok_buf: [512]syntax.Token = undefined;
            const toks = syntax.tokenize(line, self.code_lang, &tok_buf);
            var col: usize = 0;
            for (toks) |tok| {
                if (col >= max_w) break;
                const text = line[tok.start..tok.end];
                const st = tok.kind.style(base_st);
                col += try writeStr(frm, x + col, y, text, max_w - col, st);
            }
            return col;
        }

        // Horizontal rule
        if (isHRule(line)) {
            var st = base_st;
            st.fg = theme.get().md_hr;
            return try fillCh(frm, x, y, max_w, 0x2500, st); // ─
        }

        // Heading
        if (headingLevel(line)) |lvl| {
            const rest = line[lvl + 1 ..]; // skip "# "
            var st = base_st;
            st.fg = theme.get().md_heading;
            st.bold = true;
            return try renderInline(frm, x, y, rest, max_w, st);
        }

        // Blockquote
        if (isBlockquote(line)) {
            var st = base_st;
            st.fg = theme.get().md_quote;
            var col: usize = 0;
            // Write "│ " prefix
            if (col < max_w) {
                try frm.set(x + col, y, 0x2502, st); // │
                col += 1;
            }
            if (col < max_w) {
                try frm.set(x + col, y, ' ', st);
                col += 1;
            }
            const rest = stripQuotePrefix(line);
            col += try renderInline(frm, x + col, y, rest, max_w - col, base_st);
            return col;
        }

        // Unordered list
        if (unorderedItem(line)) |rest| {
            var bst = base_st;
            bst.fg = theme.get().md_list_bullet;
            var col: usize = 0;
            if (col < max_w) {
                try frm.set(x + col, y, 0x2022, bst); // •
                col += 1;
            }
            if (col < max_w) {
                try frm.set(x + col, y, ' ', base_st);
                col += 1;
            }
            col += try renderInline(frm, x + col, y, rest, max_w - col, base_st);
            return col;
        }

        // Ordered list
        if (orderedItem(line)) |info| {
            var bst = base_st;
            bst.fg = theme.get().md_list_bullet;
            var col: usize = 0;
            // Write the number + ". "
            for (info.prefix) |ch| {
                if (col >= max_w) break;
                try frm.set(x + col, y, ch, bst);
                col += 1;
            }
            if (col < max_w) {
                try frm.set(x + col, y, ' ', base_st);
                col += 1;
            }
            col += try renderInline(frm, x + col, y, info.rest, max_w - col, base_st);
            return col;
        }

        // Plain text with inline formatting
        return try renderInline(frm, x, y, line, max_w, base_st);
    }
};

// -- Inline renderer --

fn renderInline(frm: *frame.Frame, x: usize, y: usize, text: []const u8, max_w: usize, base_st: frame.Style) MdRenderer.RenderError!usize {
    if (max_w == 0) return 0;

    var col: usize = 0;
    var i: usize = 0;

    while (i < text.len and col < max_w) {
        // Inline code: `...`
        if (text[i] == '`') {
            if (findInlineCode(text, i)) |span| {
                var st = base_st;
                st.fg = theme.get().md_code;
                const content = text[span.start..span.end];
                col += try writeStr(frm, x + col, y, content, max_w - col, st);
                i = span.after;
                continue;
            }
        }

        // Bold: **...** or __...__
        if (i + 1 < text.len and ((text[i] == '*' and text[i + 1] == '*') or (text[i] == '_' and text[i + 1] == '_'))) {
            if (findDelimited(text, i, 2)) |span| {
                var st = base_st;
                st.bold = true;
                const content = text[span.start..span.end];
                col += try writeStr(frm, x + col, y, content, max_w - col, st);
                i = span.after;
                continue;
            }
        }

        // Italic: *...* or _..._
        if ((text[i] == '*' or text[i] == '_') and !(i + 1 < text.len and text[i + 1] == text[i])) {
            if (findDelimited(text, i, 1)) |span| {
                var st = base_st;
                st.italic = true;
                const content = text[span.start..span.end];
                col += try writeStr(frm, x + col, y, content, max_w - col, st);
                i = span.after;
                continue;
            }
        }

        // Link: [text](url)
        if (text[i] == '[') {
            if (findLink(text, i)) |lnk| {
                var st = base_st;
                st.fg = theme.get().md_link;
                col += try writeStr(frm, x + col, y, lnk.label, max_w - col, st);
                i = lnk.after;
                continue;
            }
        }

        // Regular character
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const end = @min(i + n, text.len);
        const view = std.unicode.Utf8View.initUnchecked(text[i..end]);
        var it = view.iterator();
        if (it.nextCodepoint()) |cp| {
            const cw = wc.wcwidth(cp);
            if (col + cw > max_w) break;
            try frm.set(x + col, y, cp, base_st);
            col += cw;
        }
        i = end;
    }

    return col;
}

// -- Block detection helpers --

pub fn isFence(line: []const u8) bool {
    const t = trimLeadingSpaces(line);
    if (t.len < 3) return false;
    if (t[0] != '`') return false;
    if (t[1] != '`') return false;
    if (t[2] != '`') return false;
    return true;
}

fn trimFence(line: []const u8) []const u8 {
    const t = trimLeadingSpaces(line);
    // Skip backticks
    var i: usize = 0;
    while (i < t.len and t[i] == '`') : (i += 1) {}
    // Remaining is the language tag
    const rest = std.mem.trim(u8, t[i..], " \t");
    return rest;
}

fn isHRule(line: []const u8) bool {
    const t = trimLeadingSpaces(line);
    if (t.len < 3) return false;
    const ch = t[0];
    if (ch != '-' and ch != '*' and ch != '_') return false;
    for (t) |c| {
        if (c != ch and c != ' ' and c != '\t') return false;
    }
    // Count actual chars
    var n: usize = 0;
    for (t) |c| {
        if (c == ch) n += 1;
    }
    return n >= 3;
}

fn headingLevel(line: []const u8) ?usize {
    var lvl: usize = 0;
    while (lvl < line.len and line[lvl] == '#') : (lvl += 1) {}
    if (lvl == 0 or lvl > 6) return null;
    if (lvl >= line.len or line[lvl] != ' ') return null;
    return lvl;
}

fn isBlockquote(line: []const u8) bool {
    if (line.len < 2) return false;
    return line[0] == '>' and line[1] == ' ';
}

fn stripQuotePrefix(line: []const u8) []const u8 {
    if (line.len >= 2 and line[0] == '>' and line[1] == ' ')
        return line[2..];
    return line;
}

fn unorderedItem(line: []const u8) ?[]const u8 {
    if (line.len < 2) return null;
    if ((line[0] == '-' or line[0] == '*' or line[0] == '+') and line[1] == ' ')
        return line[2..];
    return null;
}

const OrdItem = struct {
    prefix: []const u8,
    rest: []const u8,
};

fn orderedItem(line: []const u8) ?OrdItem {
    var i: usize = 0;
    while (i < line.len and line[i] >= '0' and line[i] <= '9') : (i += 1) {}
    if (i == 0) return null;
    if (i >= line.len or line[i] != '.') return null;
    if (i + 1 >= line.len or line[i + 1] != ' ') return null;
    return .{
        .prefix = line[0 .. i + 1], // "1."
        .rest = line[i + 2 ..],
    };
}

// -- Inline span detection --

const Span = struct {
    start: usize,
    end: usize,
    after: usize,
};

fn findInlineCode(text: []const u8, pos: usize) ?Span {
    if (pos >= text.len or text[pos] != '`') return null;
    const start = pos + 1;
    if (start >= text.len) return null;
    var i = start;
    while (i < text.len) : (i += 1) {
        if (text[i] == '`') {
            if (i == start) return null; // empty ``
            return .{ .start = start, .end = i, .after = i + 1 };
        }
    }
    return null;
}

fn findDelimited(text: []const u8, pos: usize, delim_len: usize) ?Span {
    if (pos + delim_len >= text.len) return null;
    const ch = text[pos];
    // Verify opening delimiter
    var d: usize = 0;
    while (d < delim_len) : (d += 1) {
        if (pos + d >= text.len or text[pos + d] != ch) return null;
    }
    const start = pos + delim_len;
    if (start >= text.len) return null;
    // Don't match if opening delimiter is followed by space
    if (text[start] == ' ') return null;

    var i = start;
    while (i + delim_len <= text.len) : (i += 1) {
        var match = true;
        var j: usize = 0;
        while (j < delim_len) : (j += 1) {
            if (text[i + j] != ch) {
                match = false;
                break;
            }
        }
        if (match and i > start) {
            // Don't match if closing delimiter preceded by space
            if (text[i - 1] == ' ') continue;
            return .{ .start = start, .end = i, .after = i + delim_len };
        }
    }
    return null;
}

const Link = struct {
    label: []const u8,
    after: usize,
};

fn findLink(text: []const u8, pos: usize) ?Link {
    if (pos >= text.len or text[pos] != '[') return null;
    // Find ]
    var i = pos + 1;
    while (i < text.len and text[i] != ']') : (i += 1) {}
    if (i >= text.len) return null;
    const label = text[pos + 1 .. i];
    if (label.len == 0) return null;
    // Expect (
    i += 1;
    if (i >= text.len or text[i] != '(') return null;
    // Find )
    i += 1;
    while (i < text.len and text[i] != ')') : (i += 1) {}
    if (i >= text.len) return null;
    return .{ .label = label, .after = i + 1 };
}

// -- Utility --

fn trimLeadingSpaces(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}
    return s[i..];
}

fn writeStr(frm: *frame.Frame, x: usize, y: usize, text: []const u8, max_w: usize, st: frame.Style) MdRenderer.RenderError!usize {
    if (max_w == 0 or text.len == 0) return 0;
    if (x >= frm.w or y >= frm.h) return error.OutOfBounds;

    var col: usize = 0;
    const view = std.unicode.Utf8View.initUnchecked(text);
    var it = view.iterator();
    while (col < max_w) {
        const cp = it.nextCodepoint() orelse break;
        const cw = wc.wcwidth(cp);
        if (col + cw > max_w) break;
        if (x + col >= frm.w) break;
        try frm.set(x + col, y, cp, st);
        col += cw;
    }
    return col;
}

fn fillCh(frm: *frame.Frame, x: usize, y: usize, w: usize, cp: u21, st: frame.Style) frame.Frame.PosError!usize {
    var i: usize = 0;
    while (i < w) : (i += 1) {
        if (x + i >= frm.w) break;
        try frm.set(x + i, y, cp, st);
    }
    return i;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

fn rowChars(frm: *const frame.Frame, y: usize, buf: []u21) []const u21 {
    var i: usize = 0;
    while (i < frm.w and i < buf.len) : (i += 1) {
        buf[i] = (frm.cell(i, y) catch unreachable).cp;
    }
    return buf[0..i];
}

fn rowStyles(frm: *const frame.Frame, y: usize, buf: []frame.Style) []const frame.Style {
    var i: usize = 0;
    while (i < frm.w and i < buf.len) : (i += 1) {
        buf[i] = (frm.cell(i, y) catch unreachable).style;
    }
    return buf[0..i];
}

fn u21Eql(a: []const u21, b: []const u21) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

test "heading renders bold with md_heading color" {
    var frm = try frame.Frame.init(testing.allocator, 20, 1);
    defer frm.deinit(testing.allocator);

    var md = MdRenderer{};
    const n = try md.renderLine(&frm, 0, 0, "## Hello", 20, .{});
    try testing.expectEqual(@as(usize, 5), n);

    const c = try frm.cell(0, 0);
    try testing.expectEqual(@as(u21, 'H'), c.cp);
    try testing.expect(frame.Color.eql(c.style.fg, theme.get().md_heading));
    try testing.expect(c.style.bold);
}

test "code fence toggles code block mode" {
    var frm = try frame.Frame.init(testing.allocator, 30, 3);
    defer frm.deinit(testing.allocator);

    var md = MdRenderer{};

    // Opening fence
    _ = try md.renderLine(&frm, 0, 0, "```zig", 30, .{});
    try testing.expect(md.in_code_block);
    try testing.expectEqual(syntax.Lang.zig, md.code_lang);

    // Code line — "const" is a keyword, gets syn_keyword color + bold
    const n = try md.renderLine(&frm, 0, 1, "const x = 1;", 30, .{});
    try testing.expect(n > 0);
    const c = try frm.cell(0, 1);
    try testing.expect(frame.Color.eql(c.style.fg, theme.get().syn_keyword));
    try testing.expect(c.style.bold);

    // "x" at col 6 is plain text — default fg
    const cx = try frm.cell(6, 1);
    try testing.expectEqual(@as(u21, 'x'), cx.cp);
    try testing.expect(cx.style.fg.isDefault());

    // "1" at col 10 is a number
    const cn = try frm.cell(10, 1);
    try testing.expectEqual(@as(u21, '1'), cn.cp);
    try testing.expect(frame.Color.eql(cn.style.fg, theme.get().syn_number));

    // Closing fence
    _ = try md.renderLine(&frm, 0, 2, "```", 30, .{});
    try testing.expect(!md.in_code_block);
    try testing.expectEqual(syntax.Lang.unknown, md.code_lang);
}

test "code block without lang hint uses generic highlighting" {
    var frm = try frame.Frame.init(testing.allocator, 30, 3);
    defer frm.deinit(testing.allocator);

    var md = MdRenderer{};
    _ = try md.renderLine(&frm, 0, 0, "```", 30, .{});
    try testing.expect(md.in_code_block);
    try testing.expectEqual(syntax.Lang.unknown, md.code_lang);

    const n = try md.renderLine(&frm, 0, 1, "x = \"hi\"", 30, .{});
    try testing.expect(n > 0);

    // String "hi" should get syn_string color
    // x = "hi" => positions: x(0) ' '(1) =(2) ' '(3) "(4) h(5) i(6) "(7)
    const cs = try frm.cell(4, 1);
    try testing.expectEqual(@as(u21, '"'), cs.cp);
    try testing.expect(frame.Color.eql(cs.style.fg, theme.get().syn_string));
}

test "blockquote renders bar prefix" {
    var frm = try frame.Frame.init(testing.allocator, 20, 1);
    defer frm.deinit(testing.allocator);

    var md = MdRenderer{};
    _ = try md.renderLine(&frm, 0, 0, "> quoted", 20, .{});

    const c0 = try frm.cell(0, 0);
    try testing.expectEqual(@as(u21, 0x2502), c0.cp); // │
    try testing.expect(frame.Color.eql(c0.style.fg, theme.get().md_quote));

    const c2 = try frm.cell(2, 0);
    try testing.expectEqual(@as(u21, 'q'), c2.cp);
}

test "unordered list renders bullet" {
    var frm = try frame.Frame.init(testing.allocator, 20, 1);
    defer frm.deinit(testing.allocator);

    var md = MdRenderer{};
    _ = try md.renderLine(&frm, 0, 0, "- item", 20, .{});

    const c0 = try frm.cell(0, 0);
    try testing.expectEqual(@as(u21, 0x2022), c0.cp); // •
    try testing.expect(frame.Color.eql(c0.style.fg, theme.get().md_list_bullet));

    const c2 = try frm.cell(2, 0);
    try testing.expectEqual(@as(u21, 'i'), c2.cp);
}

test "ordered list renders number" {
    var frm = try frame.Frame.init(testing.allocator, 20, 1);
    defer frm.deinit(testing.allocator);

    var md = MdRenderer{};
    _ = try md.renderLine(&frm, 0, 0, "3. third", 20, .{});

    const c0 = try frm.cell(0, 0);
    try testing.expectEqual(@as(u21, '3'), c0.cp);
    try testing.expect(frame.Color.eql(c0.style.fg, theme.get().md_list_bullet));

    const c1 = try frm.cell(1, 0);
    try testing.expectEqual(@as(u21, '.'), c1.cp);
}

test "horizontal rule fills with line char" {
    var frm = try frame.Frame.init(testing.allocator, 10, 1);
    defer frm.deinit(testing.allocator);

    var md = MdRenderer{};
    const n = try md.renderLine(&frm, 0, 0, "---", 10, .{});
    try testing.expectEqual(@as(usize, 10), n);

    const c = try frm.cell(5, 0);
    try testing.expectEqual(@as(u21, 0x2500), c.cp); // ─
    try testing.expect(frame.Color.eql(c.style.fg, theme.get().md_hr));
}

test "inline code gets md_code style" {
    var frm = try frame.Frame.init(testing.allocator, 30, 1);
    defer frm.deinit(testing.allocator);

    var md = MdRenderer{};
    _ = try md.renderLine(&frm, 0, 0, "use `foo` here", 30, .{});

    // 'u','s','e',' ' then 'f','o','o' then ' ','h','e','r','e'
    const c4 = try frm.cell(4, 0);
    try testing.expectEqual(@as(u21, 'f'), c4.cp);
    try testing.expect(frame.Color.eql(c4.style.fg, theme.get().md_code));

    // 'h' should be default
    const c8 = try frm.cell(8, 0);
    try testing.expectEqual(@as(u21, 'h'), c8.cp);
    try testing.expect(c8.style.fg.isDefault());
}

test "bold text gets bold attribute" {
    var frm = try frame.Frame.init(testing.allocator, 30, 1);
    defer frm.deinit(testing.allocator);

    var md = MdRenderer{};
    _ = try md.renderLine(&frm, 0, 0, "a **bold** z", 30, .{});

    // 'a',' ','b','o','l','d',' ','z'
    const c2 = try frm.cell(2, 0);
    try testing.expectEqual(@as(u21, 'b'), c2.cp);
    try testing.expect(c2.style.bold);

    const c0 = try frm.cell(0, 0);
    try testing.expect(!c0.style.bold);
}

test "italic text gets italic attribute" {
    var frm = try frame.Frame.init(testing.allocator, 30, 1);
    defer frm.deinit(testing.allocator);

    var md = MdRenderer{};
    _ = try md.renderLine(&frm, 0, 0, "a *em* z", 30, .{});

    const c2 = try frm.cell(2, 0);
    try testing.expectEqual(@as(u21, 'e'), c2.cp);
    try testing.expect(c2.style.italic);
}

test "link renders label in md_link color" {
    var frm = try frame.Frame.init(testing.allocator, 30, 1);
    defer frm.deinit(testing.allocator);

    var md = MdRenderer{};
    _ = try md.renderLine(&frm, 0, 0, "[click](http://x.com)", 30, .{});

    const c0 = try frm.cell(0, 0);
    try testing.expectEqual(@as(u21, 'c'), c0.cp);
    try testing.expect(frame.Color.eql(c0.style.fg, theme.get().md_link));

    // After "click" (5 chars), should be space (nothing more rendered)
    const c5 = try frm.cell(5, 0);
    try testing.expectEqual(@as(u21, ' '), c5.cp);
}

test "fence lang tag rendered in code_border color" {
    var frm = try frame.Frame.init(testing.allocator, 20, 1);
    defer frm.deinit(testing.allocator);

    var md = MdRenderer{};
    _ = try md.renderLine(&frm, 0, 0, "```python", 20, .{});

    const c0 = try frm.cell(0, 0);
    try testing.expectEqual(@as(u21, 'p'), c0.cp);
    try testing.expect(frame.Color.eql(c0.style.fg, theme.get().md_code_border));
}

test "plain text renders unchanged" {
    var frm = try frame.Frame.init(testing.allocator, 20, 1);
    defer frm.deinit(testing.allocator);

    var md = MdRenderer{};
    const n = try md.renderLine(&frm, 0, 0, "hello", 20, .{});
    try testing.expectEqual(@as(usize, 5), n);

    const c = try frm.cell(0, 0);
    try testing.expectEqual(@as(u21, 'h'), c.cp);
    try testing.expect(c.style.isDefault());
}

test "max_w clips output" {
    var frm = try frame.Frame.init(testing.allocator, 20, 1);
    defer frm.deinit(testing.allocator);

    var md = MdRenderer{};
    const n = try md.renderLine(&frm, 0, 0, "abcdefghij", 3, .{});
    try testing.expectEqual(@as(usize, 3), n);

    // Column 3 should still be space
    const c3 = try frm.cell(3, 0);
    try testing.expectEqual(@as(u21, ' '), c3.cp);
}
