const std = @import("std");
const core = @import("../../core/mod.zig");
const frame = @import("frame.zig");
const markdown = @import("markdown.zig");
const theme = @import("theme.zig");
const wc = @import("wcwidth.zig");

pub const Rect = struct {
    x: usize,
    y: usize,
    w: usize,
    h: usize,
};

const Kind = enum { text, thinking, tool, err, meta };

const Span = struct {
    start: usize, // byte offset in buf
    end: usize, // byte offset in buf
    st: frame.Style,
};

const Block = struct {
    kind: Kind,
    buf: std.ArrayListUnmanaged(u8),
    st: frame.Style,
    spans: std.ArrayListUnmanaged(Span) = .empty,

    pub fn deinit(self: *Block, alloc: std.mem.Allocator) void {
        self.spans.deinit(alloc);
        self.buf.deinit(alloc);
    }

    pub fn text(self: *const Block) []const u8 {
        return self.buf.items;
    }

    fn styleAt(self: *const Block, pos: usize) frame.Style {
        for (self.spans.items) |s| {
            if (s.start > pos) break; // spans sorted by start
            if (pos >= s.start and pos < s.end) return s.st;
        }
        return self.st;
    }

    fn hasSpans(self: *const Block) bool {
        return self.spans.items.len > 0;
    }
};

pub const Transcript = struct {
    alloc: std.mem.Allocator,
    blocks: std.ArrayListUnmanaged(Block) = .empty,
    md: markdown.MdRenderer = .{},
    scroll_off: usize = 0,
    show_tools: bool = true,
    show_thinking: bool = false,

    pub fn scrollUp(self: *Transcript, n: usize) void {
        self.scroll_off +|= n;
    }

    pub fn scrollDown(self: *Transcript, n: usize) void {
        if (n >= self.scroll_off) {
            self.scroll_off = 0;
        } else {
            self.scroll_off -= n;
        }
    }

    pub fn scrollToBottom(self: *Transcript) void {
        self.scroll_off = 0;
    }

    pub const AppendError = std.mem.Allocator.Error || error{InvalidUtf8};
    pub const RenderError = frame.Frame.PosError || error{InvalidUtf8};

    pub fn init(alloc: std.mem.Allocator) Transcript {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Transcript) void {
        for (self.blocks.items) |*b| b.deinit(self.alloc);
        self.blocks.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn count(self: *const Transcript) usize {
        return self.blocks.items.len;
    }

    pub fn append(self: *Transcript, ev: core.providers.Ev) AppendError!void {
        switch (ev) {
            .text => |t| {
                // Coalesce consecutive text events
                if (self.blocks.items.len > 0) {
                    const last = &self.blocks.items[self.blocks.items.len - 1];
                    if (last.kind == .text) {
                        try ensureUtf8(t);
                        try last.buf.appendSlice(self.alloc, t);
                        return;
                    }
                }
                try self.pushBlock(.text, t, .{});
            },
            .thinking => |t| try self.pushFmt(.thinking, "[thinking] {s}", .{t}, .{
                .fg = theme.get().thinking_fg,
                .italic = true,
            }),
            .tool_call => |tc| try self.pushFmt(.tool, "[tool {s}#{s}] {s}", .{
                tc.name,
                tc.id,
                tc.args,
            }, .{
                .fg = theme.get().warn,
                .bg = theme.get().tool_pending_bg,
            }),
            .tool_result => |tr| {
                const kind: Kind = if (tr.is_err) .err else .tool;
                const base_st: frame.Style = if (tr.is_err) .{
                    .fg = theme.get().err,
                    .bg = theme.get().tool_error_bg,
                } else .{
                    .fg = theme.get().success,
                    .bg = theme.get().tool_success_bg,
                };
                const tag = if (tr.is_err) "true" else "false";
                try self.pushAnsi(kind, "[tool-result #{s} err={s}] ", .{
                    tr.id, tag,
                }, tr.out, base_st);
            },
            .err => |t| try self.pushFmt(.err, "[err] {s}", .{t}, .{
                .fg = theme.get().err,
                .bold = true,
                .bg = theme.get().tool_error_bg,
            }),
            .usage => |u| try self.pushFmt(.meta, "[usage {d}/{d}/{d}]", .{
                u.in_tok,
                u.out_tok,
                u.tot_tok,
            }, .{
                .fg = theme.get().dim,
            }),
            .stop => |s| try self.pushFmt(.meta, "[stop {s}]", .{
                @tagName(s.reason),
            }, .{
                .fg = theme.get().dim,
            }),
        }
    }

    pub fn userText(self: *Transcript, t: []const u8) AppendError!void {
        try self.pushBlock(.text, t, .{ .bg = theme.get().user_msg_bg });
    }

    pub fn infoText(self: *Transcript, t: []const u8) AppendError!void {
        try self.pushBlock(.text, t, .{ .fg = theme.get().dim });
    }

    pub fn render(self: *const Transcript, frm: *frame.Frame, rect: Rect) RenderError!void {
        if (rect.w == 0 or rect.h == 0) return;

        _ = try rectEndX(frm, rect);
        _ = try rectEndY(frm, rect);
        try clearRect(frm, rect);

        // 1-col left padding matching pi
        const pad: usize = if (rect.w > 2) 1 else 0;
        const content_x = rect.x + pad;
        const avail_w = rect.w - pad;

        // Count total display lines
        var total: usize = 0;
        for (self.blocks.items) |*b| {
            if (!self.blockVisible(b)) continue;
            total += countLines(self.blockDisplayText(b), avail_w);
        }
        if (total == 0) return;

        // If content overflows, reserve 1 col for scrollbar
        const has_bar = total > rect.h and avail_w >= 2;
        const text_w = if (has_bar) avail_w - 1 else avail_w;

        // Recount with narrower width if scrollbar present
        if (has_bar) {
            total = 0;
            for (self.blocks.items) |*b| {
                if (!self.blockVisible(b)) continue;
                total += countLines(self.blockDisplayText(b), text_w);
            }
        }

        // Auto-scroll when scroll_off == 0, otherwise respect manual offset
        const max_skip = if (total > rect.h) total - rect.h else 0;
        const clamped_off = @min(self.scroll_off, max_skip);
        const skip = if (self.scroll_off == 0)
            max_skip
        else if (max_skip > clamped_off)
            max_skip - clamped_off
        else
            0;
        var skipped: usize = 0;
        var row: usize = 0;

        var md = markdown.MdRenderer{};
        for (self.blocks.items) |*b| {
            if (!self.blockVisible(b)) continue;
            const txt = self.blockDisplayText(b);
            const use_md = b.kind == .text;
            if (use_md) md = .{};
            var wit = wrapIter(txt, text_w);
            while (wit.next()) |line| {
                if (skipped < skip) {
                    skipped += 1;
                    if (use_md) {
                        // Advance md state for skipped lines
                        if (md.in_code_block or markdown.isFence(line))
                            md.advanceSkipped(line);
                    }
                    continue;
                }
                if (row >= rect.h) return;

                const y = rect.y + row;

                // Fill bg across full width (including padding) if non-default
                if (!b.st.bg.isDefault()) {
                    var x = rect.x;
                    while (x < rect.x + rect.w) : (x += 1) {
                        try frm.set(x, y, ' ', .{ .bg = b.st.bg });
                    }
                }

                if (use_md) {
                    _ = try md.renderLine(frm, content_x, y, line, text_w, b.st);
                } else if (b.hasSpans()) {
                    const base_off = @intFromPtr(line.ptr) - @intFromPtr(txt.ptr);
                    _ = try writeStyled(frm, content_x, y, line, base_off, b);
                } else {
                    _ = try frm.write(content_x, y, line, b.st);
                }

                row += 1;
            }
        }

        // Scroll indicator
        if (has_bar) {
            const bar_x = rect.x + rect.w - 1;
            const bar_st = frame.Style{ .fg = theme.get().border_muted };
            const track_st = frame.Style{ .fg = theme.get().dim };

            const thumb_h = @max(@as(usize, 1), rect.h * rect.h / total);
            const scroll_range = if (total > rect.h) total - rect.h else 0;
            const track_range = if (rect.h > thumb_h) rect.h - thumb_h else 0;
            const thumb_y = if (scroll_range > 0) skip * track_range / scroll_range else 0;

            var sy: usize = 0;
            while (sy < rect.h) : (sy += 1) {
                const is_thumb = sy >= thumb_y and sy < thumb_y + thumb_h;
                const cp: u21 = if (is_thumb) 0x2588 else 0x2591;
                const st = if (is_thumb) bar_st else track_st;
                try frm.set(bar_x, rect.y + sy, cp, st);
            }
        }
    }

    const thinking_label = "Thinking...";

    fn blockVisible(self: *const Transcript, b: *const Block) bool {
        if (!self.show_tools and b.kind == .tool) return false;
        return true;
    }

    fn blockDisplayText(self: *const Transcript, b: *const Block) []const u8 {
        if (!self.show_thinking and b.kind == .thinking) return thinking_label;
        return b.text();
    }

    fn pushBlock(self: *Transcript, kind: Kind, t: []const u8, st: frame.Style) AppendError!void {
        try ensureUtf8(t);
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        try buf.appendSlice(self.alloc, t);
        errdefer buf.deinit(self.alloc);
        try self.blocks.append(self.alloc, .{
            .kind = kind,
            .buf = buf,
            .st = st,
        });
    }

    fn pushFmt(
        self: *Transcript,
        kind: Kind,
        comptime fmt: []const u8,
        args: anytype,
        st: frame.Style,
    ) AppendError!void {
        const txt = try std.fmt.allocPrint(self.alloc, fmt, args);
        errdefer self.alloc.free(txt);
        try ensureUtf8(txt);
        var buf: std.ArrayListUnmanaged(u8) = .{
            .items = txt,
            .capacity = txt.len,
        };
        errdefer buf.deinit(self.alloc);
        try self.blocks.append(self.alloc, .{
            .kind = kind,
            .buf = buf,
            .st = st,
        });
    }

    fn pushAnsi(
        self: *Transcript,
        kind: Kind,
        comptime prefix_fmt: []const u8,
        prefix_args: anytype,
        ansi_text: []const u8,
        base_st: frame.Style,
    ) AppendError!void {
        const prefix = try std.fmt.allocPrint(self.alloc, prefix_fmt, prefix_args);
        defer self.alloc.free(prefix);

        var parsed = try parseAnsi(self.alloc, ansi_text, base_st);
        errdefer {
            parsed.spans.deinit(self.alloc);
            parsed.buf.deinit(self.alloc);
        }

        // Shift span offsets by prefix length
        const off = prefix.len;
        for (parsed.spans.items) |*s| {
            s.start += off;
            s.end += off;
        }

        // Build final buf: prefix + parsed text
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        try buf.ensureTotalCapacity(self.alloc, off + parsed.buf.items.len);
        errdefer buf.deinit(self.alloc);
        buf.appendSliceAssumeCapacity(prefix);
        buf.appendSliceAssumeCapacity(parsed.buf.items);
        parsed.buf.deinit(self.alloc);

        try ensureUtf8(buf.items);

        try self.blocks.append(self.alloc, .{
            .kind = kind,
            .buf = buf,
            .st = base_st,
            .spans = parsed.spans,
        });
    }
};

// -- Word wrap --

pub const WrapIter = struct {
    text: []const u8,
    pos: usize,
    w: usize,

    pub fn next(self: *WrapIter) ?[]const u8 {
        if (self.w == 0) return null;
        if (self.pos >= self.text.len) return null;

        // Check for trailing position after final \n
        const start = self.pos;
        var i = start;
        var cols: usize = 0;

        while (i < self.text.len) {
            // Check for newline
            if (self.text[i] == '\n') {
                const line = self.text[start..i];
                self.pos = i + 1;
                // If this \n is the last char, and we haven't seen content,
                // need to check if we're at end
                return line;
            }

            // Decode codepoint
            const n = std.unicode.utf8ByteSequenceLength(self.text[i]) catch 1;
            const cp_end = @min(i + n, self.text.len);
            const cp = std.unicode.utf8Decode(self.text[i..cp_end]) catch 0xFFFD;

            cols += wc.wcwidth(cp);
            if (cols > self.w) {
                // Need to break - look backward for space
                var brk = i;
                var scan = i;
                // Scan backward from current position to find space
                var found_space = false;
                while (scan > start) {
                    scan -= 1;
                    // Walk back to find a space
                    if (self.text[scan] == ' ' or self.text[scan] == '\t') {
                        // Break after this space: exclude space from line
                        brk = scan;
                        found_space = true;
                        break;
                    }
                }
                if (found_space) {
                    const line = self.text[start..brk];
                    self.pos = brk + 1; // skip the space
                    return line;
                } else {
                    // Hard break at w columns
                    const line = self.text[start..i];
                    self.pos = i;
                    return line;
                }
            }

            i = cp_end;
        }

        // Remaining text (no newline at end)
        if (start < self.text.len) {
            self.pos = self.text.len;
            return self.text[start..];
        }

        return null;
    }
};

pub fn wrapIter(text: []const u8, w: usize) WrapIter {
    return .{ .text = text, .pos = 0, .w = w };
}

pub fn countLines(text: []const u8, w: usize) usize {
    if (w == 0) return 0;
    if (text.len == 0) return 1; // empty block = 1 display line
    var n: usize = 0;
    var it = wrapIter(text, w);
    while (it.next() != null) n += 1;
    return if (n == 0) 1 else n;
}

// -- Per-span styled write --

fn writeStyled(
    frm: *frame.Frame,
    x: usize,
    y: usize,
    line: []const u8,
    base_off: usize,
    blk: *const Block,
) (frame.Frame.PosError || error{InvalidUtf8})!usize {
    if (x >= frm.w or y >= frm.h) return error.OutOfBounds;
    const wcwidth = @import("wcwidth.zig").wcwidth;

    var col = x;
    var ct: usize = 0;
    var it = (std.unicode.Utf8View.init(line) catch return error.InvalidUtf8).iterator();
    var byte_pos: usize = 0;
    while (col < frm.w) {
        const cp = it.nextCodepoint() orelse break;
        const cp_len = std.unicode.utf8CodepointSequenceLength(cp) catch 1;
        const st = blk.styleAt(base_off + byte_pos);
        byte_pos += cp_len;
        const w: usize = wcwidth(cp);
        if (w == 0) continue;
        if (col + w > frm.w) break;
        frm.cells[y * frm.w + col] = .{ .cp = cp, .style = st };
        if (w == 2) {
            frm.cells[y * frm.w + col + 1] = .{ .cp = frame.Frame.wide_pad, .style = st };
        }
        col += w;
        ct += 1;
    }
    return ct;
}

// -- ANSI parsing --

const ParseResult = struct {
    buf: std.ArrayListUnmanaged(u8),
    spans: std.ArrayListUnmanaged(Span),
};

pub fn parseAnsi(alloc: std.mem.Allocator, text: []const u8, base_st: frame.Style) !ParseResult {
    // Fast path: no ESC
    if (std.mem.indexOfScalar(u8, text, 0x1b) == null) {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        try buf.appendSlice(alloc, text);
        return .{ .buf = buf, .spans = .empty };
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try buf.ensureTotalCapacity(alloc, text.len);
    errdefer buf.deinit(alloc);

    var spans: std.ArrayListUnmanaged(Span) = .empty;
    errdefer spans.deinit(alloc);

    var cur_st = base_st;
    var span_start: ?usize = null;

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == 0x1b) {
            i += 1;
            if (i >= text.len) break;
            if (text[i] == '[') {
                // CSI: parse SGR
                i += 1;
                const seq_start = i;
                while (i < text.len) {
                    if (text[i] >= 0x40 and text[i] <= 0x7e) {
                        const cmd = text[i];
                        i += 1;
                        if (cmd == 'm') {
                            // Close open span before style change
                            if (span_start) |ss| {
                                if (buf.items.len > ss) {
                                    try spans.append(alloc, .{
                                        .start = ss,
                                        .end = buf.items.len,
                                        .st = cur_st,
                                    });
                                }
                                span_start = null;
                            }
                            cur_st = applySgr(text[seq_start .. i - 1], base_st, cur_st);
                            if (!frame.Style.eql(cur_st, base_st)) {
                                span_start = buf.items.len;
                            }
                        }
                        break;
                    }
                    i += 1;
                }
            } else {
                // Simple ESC+char — skip
                i += 1;
            }
        } else {
            buf.appendAssumeCapacity(text[i]);
            i += 1;
        }
    }

    // Close trailing span
    if (span_start) |ss| {
        if (buf.items.len > ss) {
            try spans.append(alloc, .{
                .start = ss,
                .end = buf.items.len,
                .st = cur_st,
            });
        }
    }

    return .{ .buf = buf, .spans = spans };
}

fn applySgr(params: []const u8, base: frame.Style, cur: frame.Style) frame.Style {
    var st = cur;
    var it = SgrIter{ .data = params };
    while (it.next()) |code| {
        switch (code) {
            0 => st = base,
            1 => st.bold = true,
            2 => st.dim = true,
            3 => st.italic = true,
            4 => st.underline = true,
            7 => st.inverse = true,
            22 => {
                st.bold = false;
                st.dim = false;
            },
            23 => st.italic = false,
            24 => st.underline = false,
            27 => st.inverse = false,
            30...37 => st.fg = .{ .idx = @intCast(code - 30) },
            38 => {
                if (parseExtColor(&it)) |c| st.fg = c;
            },
            39 => st.fg = base.fg,
            40...47 => st.bg = .{ .idx = @intCast(code - 40) },
            48 => {
                if (parseExtColor(&it)) |c| st.bg = c;
            },
            49 => st.bg = base.bg,
            90...97 => st.fg = .{ .idx = @intCast(code - 90 + 8) },
            100...107 => st.bg = .{ .idx = @intCast(code - 100 + 8) },
            else => {},
        }
    }
    return st;
}

fn parseExtColor(it: *SgrIter) ?frame.Color {
    const mode = it.next() orelse return null;
    switch (mode) {
        5 => {
            const n = it.next() orelse return null;
            return .{ .idx = @intCast(n & 0xff) };
        },
        2 => {
            const r = it.next() orelse return null;
            const g = it.next() orelse return null;
            const b = it.next() orelse return null;
            const rgb: u24 = (@as(u24, @intCast(r & 0xff)) << 16) |
                (@as(u24, @intCast(g & 0xff)) << 8) |
                @as(u24, @intCast(b & 0xff));
            return .{ .rgb = rgb };
        },
        else => return null,
    }
}

const SgrIter = struct {
    data: []const u8,
    pos: usize = 0,
    done: bool = false,

    fn next(self: *SgrIter) ?u16 {
        if (self.done) return null;
        if (self.pos >= self.data.len) {
            self.done = true;
            // Bare \x1b[m (empty params) => implicit reset (0)
            // Also handles trailing semicolon like "1;"
            return 0;
        }
        var val: u16 = 0;
        var found_digit = false;
        while (self.pos < self.data.len) {
            const c = self.data[self.pos];
            self.pos += 1;
            if (c == ';') return if (found_digit) val else 0;
            if (c >= '0' and c <= '9') {
                val = val *% 10 +% @as(u16, c - '0');
                found_digit = true;
            }
        }
        self.done = true;
        return if (found_digit) val else 0;
    }
};

// -- ANSI stripping (kept for non-tool blocks) --

pub fn stripAnsi(alloc: std.mem.Allocator, text: []const u8) ![]const u8 {
    // Quick check: no ESC → return original
    if (std.mem.indexOfScalar(u8, text, 0x1b) == null)
        return text;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.ensureTotalCapacity(alloc, text.len);
    errdefer out.deinit(alloc);

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == 0x1b) {
            i += 1;
            if (i >= text.len) break;
            if (text[i] == '[') {
                // CSI sequence: skip until command byte (0x40-0x7e)
                i += 1;
                while (i < text.len) {
                    if (text[i] >= 0x40 and text[i] <= 0x7e) {
                        i += 1;
                        break;
                    }
                    i += 1;
                }
            } else {
                // Simple ESC+char
                i += 1;
            }
        } else {
            try out.append(alloc, text[i]);
            i += 1;
        }
    }

    return try out.toOwnedSlice(alloc);
}

// -- Utilities --

fn cpCount(text: []const u8) usize {
    return wc.strwidth(text);
}

fn ensureUtf8(text: []const u8) error{InvalidUtf8}!void {
    _ = std.unicode.Utf8View.init(text) catch return error.InvalidUtf8;
}

fn clipCols(text: []const u8, cols: usize) error{InvalidUtf8}![]const u8 {
    if (cols == 0 or text.len == 0) return text[0..0];

    var i: usize = 0;
    var used: usize = 0;
    while (i < text.len and used < cols) {
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch return error.InvalidUtf8;
        const cp = std.unicode.utf8Decode(text[i .. i + n]) catch return error.InvalidUtf8;
        const w = wc.wcwidth(cp);
        if (used + w > cols) break;
        i += n;
        used += w;
    }
    return text[0..i];
}

fn rectEndX(frm: *const frame.Frame, rect: Rect) frame.Frame.PosError!usize {
    const x_end = std.math.add(usize, rect.x, rect.w) catch return error.OutOfBounds;
    if (x_end > frm.w) return error.OutOfBounds;
    return x_end;
}

fn rectEndY(frm: *const frame.Frame, rect: Rect) frame.Frame.PosError!usize {
    const y_end = std.math.add(usize, rect.y, rect.h) catch return error.OutOfBounds;
    if (y_end > frm.h) return error.OutOfBounds;
    return y_end;
}

fn clearRect(frm: *frame.Frame, rect: Rect) frame.Frame.PosError!void {
    var y: usize = 0;
    while (y < rect.h) : (y += 1) {
        var x: usize = 0;
        while (x < rect.w) : (x += 1) {
            try frm.set(rect.x + x, rect.y + y, ' ', .{});
        }
    }
}

fn rowAscii(frm: *const frame.Frame, y: usize, out: []u8) ![]const u8 {
    std.debug.assert(out.len >= frm.w);
    var x: usize = 0;
    while (x < frm.w) : (x += 1) {
        const c = try frm.cell(x, y);
        out[x] = if (c.cp <= 0x7f) @intCast(c.cp) else '?';
    }
    return out[0..frm.w];
}

// ============================================================
// Tests
// ============================================================

test "transcript appends provider events and renders fixed-height tail" {
    var tr = Transcript.init(std.testing.allocator);
    defer tr.deinit();

    try tr.append(.{ .text = "one" });
    try tr.append(.{ .thinking = "two" });
    try tr.append(.{ .tool_call = .{
        .id = "c1",
        .name = "read",
        .args = "{}",
    } });
    try tr.append(.{ .text = "three" });

    // 4 blocks: text("one"), thinking, tool, text("three")
    try std.testing.expectEqual(@as(usize, 4), tr.count());

    var frm = try frame.Frame.init(std.testing.allocator, 24, 3);
    defer frm.deinit(std.testing.allocator);
    try tr.render(&frm, .{
        .x = 0,
        .y = 0,
        .w = 24,
        .h = 3,
    });

    var raw0: [24]u8 = undefined;
    var raw1: [24]u8 = undefined;
    var raw2: [24]u8 = undefined;
    const r0 = try rowAscii(&frm, 0, raw0[0..]);
    const r1 = try rowAscii(&frm, 1, raw1[0..]);
    const r2 = try rowAscii(&frm, 2, raw2[0..]);

    // Thinking hidden by default → collapsed "Thinking..." label
    try std.testing.expect(std.mem.indexOf(u8, r0, "Thinking...") != null);
    try std.testing.expect(std.mem.indexOf(u8, r1, "[tool read#c1] {}") != null);
    try std.testing.expect(std.mem.indexOf(u8, r2, "three") != null);
}

test "transcript fills tool rows with background color" {
    var tr = Transcript.init(std.testing.allocator);
    defer tr.deinit();

    try tr.append(.{ .tool_call = .{
        .id = "x",
        .name = "ls",
        .args = ".",
    } });

    var frm = try frame.Frame.init(std.testing.allocator, 30, 1);
    defer frm.deinit(std.testing.allocator);
    try tr.render(&frm, .{ .x = 0, .y = 0, .w = 30, .h = 1 });

    // Col 0 is padding (bg filled), col 1 has tool text
    const c0 = try frm.cell(0, 0);
    try std.testing.expect(frame.Color.eql(c0.style.bg, theme.get().tool_pending_bg));
    const c1 = try frm.cell(1, 0);
    try std.testing.expect(frame.Color.eql(c1.style.fg, theme.get().warn));
    try std.testing.expect(frame.Color.eql(c1.style.bg, theme.get().tool_pending_bg));

    // Remaining cols should be filled with bg
    const c_last = try frm.cell(29, 0);
    try std.testing.expect(frame.Color.eql(c_last.style.bg, theme.get().tool_pending_bg));
}

test "transcript text lines have no background fill" {
    var tr = Transcript.init(std.testing.allocator);
    defer tr.deinit();

    try tr.append(.{ .text = "hi" });

    var frm = try frame.Frame.init(std.testing.allocator, 10, 1);
    defer frm.deinit(std.testing.allocator);
    try tr.render(&frm, .{ .x = 0, .y = 0, .w = 10, .h = 1 });

    // Past text, bg should be default
    const c5 = try frm.cell(5, 0);
    try std.testing.expect(c5.style.bg.isDefault());
}

test "transcript rejects invalid utf8 and out-of-bounds render" {
    var tr = Transcript.init(std.testing.allocator);
    defer tr.deinit();

    const bad = [_]u8{0xff};
    try std.testing.expectError(error.InvalidUtf8, tr.append(.{ .text = bad[0..] }));

    var frm = try frame.Frame.init(std.testing.allocator, 2, 1);
    defer frm.deinit(std.testing.allocator);
    try std.testing.expectError(error.OutOfBounds, tr.render(&frm, .{
        .x = 1,
        .y = 0,
        .w = 2,
        .h = 1,
    }));
}

test "word wrap breaks at word boundary" {
    var it = wrapIter("hello world foo", 8);
    const l0 = it.next().?;
    const l1 = it.next().?;
    const l2 = it.next().?;
    try std.testing.expectEqualStrings("hello", l0);
    try std.testing.expectEqualStrings("world", l1);
    try std.testing.expectEqualStrings("foo", l2);
    try std.testing.expect(it.next() == null);
}

test "word wrap hard breaks long words" {
    var it = wrapIter("abcdefghij", 5);
    const l0 = it.next().?;
    const l1 = it.next().?;
    try std.testing.expectEqualStrings("abcde", l0);
    try std.testing.expectEqualStrings("fghij", l1);
    try std.testing.expect(it.next() == null);
}

test "text coalescing merges consecutive text events" {
    var tr = Transcript.init(std.testing.allocator);
    defer tr.deinit();

    try tr.append(.{ .text = "a" });
    try tr.append(.{ .text = "b" });
    try std.testing.expectEqual(@as(usize, 1), tr.count());
    try std.testing.expectEqualStrings("ab", tr.blocks.items[0].text());
}

test "userText prevents coalescing" {
    var tr = Transcript.init(std.testing.allocator);
    defer tr.deinit();

    try tr.append(.{ .text = "a" });
    try tr.userText("b");
    try std.testing.expectEqual(@as(usize, 2), tr.count());
}

test "stripAnsi removes CSI sequences" {
    const input = "\x1b[31mhello\x1b[0m";
    const result = try stripAnsi(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello", result);
}

test "scroll indicator appears when content overflows" {
    var tr = Transcript.init(std.testing.allocator);
    defer tr.deinit();

    try tr.append(.{ .text = "line1" });
    try tr.userText("line2");
    try tr.userText("line3");
    try tr.userText("line4");

    // 4 blocks, 2-row viewport → overflow → scrollbar at col 19
    var frm = try frame.Frame.init(std.testing.allocator, 20, 2);
    defer frm.deinit(std.testing.allocator);
    try tr.render(&frm, .{ .x = 0, .y = 0, .w = 20, .h = 2 });

    // Last column should have scroll indicator chars (non-space, non-default fg)
    const c0 = try frm.cell(19, 0);
    const c1 = try frm.cell(19, 1);
    try std.testing.expect(c0.cp == 0x2588 or c0.cp == 0x2591);
    try std.testing.expect(c1.cp == 0x2588 or c1.cp == 0x2591);

    // Text should not bleed into scrollbar column
    const c_text = try frm.cell(18, 1);
    try std.testing.expect(c_text.cp <= 0x7f); // ASCII text region
}

test "no scroll indicator when content fits" {
    var tr = Transcript.init(std.testing.allocator);
    defer tr.deinit();

    try tr.append(.{ .text = "hi" });

    var frm = try frame.Frame.init(std.testing.allocator, 20, 2);
    defer frm.deinit(std.testing.allocator);
    try tr.render(&frm, .{ .x = 0, .y = 0, .w = 20, .h = 2 });

    // Last column should be space (no scrollbar)
    const c = try frm.cell(19, 0);
    try std.testing.expectEqual(@as(u21, ' '), c.cp);
}

test "parseAnsi red foreground" {
    const base: frame.Style = .{ .fg = .{ .rgb = 0xaabbcc } };
    var res = try parseAnsi(std.testing.allocator, "\x1b[31mhello\x1b[0m world", base);
    defer {
        res.buf.deinit(std.testing.allocator);
        res.spans.deinit(std.testing.allocator);
    }
    try std.testing.expectEqualStrings("hello world", res.buf.items);
    try std.testing.expectEqual(@as(usize, 1), res.spans.items.len);
    const s = res.spans.items[0];
    try std.testing.expectEqual(@as(usize, 0), s.start);
    try std.testing.expectEqual(@as(usize, 5), s.end);
    try std.testing.expect(frame.Color.eql(s.st.fg, .{ .idx = 1 }));
}

test "parseAnsi bold" {
    const base: frame.Style = .{};
    var res = try parseAnsi(std.testing.allocator, "\x1b[1mbold\x1b[22mnot", base);
    defer {
        res.buf.deinit(std.testing.allocator);
        res.spans.deinit(std.testing.allocator);
    }
    try std.testing.expectEqualStrings("boldnot", res.buf.items);
    try std.testing.expectEqual(@as(usize, 1), res.spans.items.len);
    try std.testing.expect(res.spans.items[0].st.bold);
}

test "parseAnsi 256-color" {
    const base: frame.Style = .{};
    var res = try parseAnsi(std.testing.allocator, "\x1b[38;5;196mred\x1b[0m", base);
    defer {
        res.buf.deinit(std.testing.allocator);
        res.spans.deinit(std.testing.allocator);
    }
    try std.testing.expectEqualStrings("red", res.buf.items);
    try std.testing.expectEqual(@as(usize, 1), res.spans.items.len);
    try std.testing.expect(frame.Color.eql(res.spans.items[0].st.fg, .{ .idx = 196 }));
}

test "parseAnsi truecolor" {
    const base: frame.Style = .{};
    var res = try parseAnsi(std.testing.allocator, "\x1b[38;2;255;128;0mtext\x1b[0m", base);
    defer {
        res.buf.deinit(std.testing.allocator);
        res.spans.deinit(std.testing.allocator);
    }
    try std.testing.expectEqualStrings("text", res.buf.items);
    try std.testing.expectEqual(@as(usize, 1), res.spans.items.len);
    try std.testing.expect(frame.Color.eql(res.spans.items[0].st.fg, .{ .rgb = 0xff8000 }));
}

test "parseAnsi reset mid-stream" {
    const base: frame.Style = .{ .fg = .{ .rgb = 0x808080 } };
    var res = try parseAnsi(std.testing.allocator, "\x1b[31mA\x1b[0mB\x1b[32mC\x1b[0m", base);
    defer {
        res.buf.deinit(std.testing.allocator);
        res.spans.deinit(std.testing.allocator);
    }
    try std.testing.expectEqualStrings("ABC", res.buf.items);
    // Two spans: A(red), C(green); B uses base
    try std.testing.expectEqual(@as(usize, 2), res.spans.items.len);
    try std.testing.expect(frame.Color.eql(res.spans.items[0].st.fg, .{ .idx = 1 }));
    try std.testing.expect(frame.Color.eql(res.spans.items[1].st.fg, .{ .idx = 2 }));
    try std.testing.expectEqual(@as(usize, 0), res.spans.items[0].start);
    try std.testing.expectEqual(@as(usize, 1), res.spans.items[0].end);
    try std.testing.expectEqual(@as(usize, 2), res.spans.items[1].start);
    try std.testing.expectEqual(@as(usize, 3), res.spans.items[1].end);
}

test "parseAnsi no escapes returns original text" {
    const base: frame.Style = .{};
    var res = try parseAnsi(std.testing.allocator, "plain text", base);
    defer {
        res.buf.deinit(std.testing.allocator);
        res.spans.deinit(std.testing.allocator);
    }
    try std.testing.expectEqualStrings("plain text", res.buf.items);
    try std.testing.expectEqual(@as(usize, 0), res.spans.items.len);
}

test "parseAnsi nested attributes" {
    const base: frame.Style = .{};
    var res = try parseAnsi(std.testing.allocator, "\x1b[1;31mboldred\x1b[0m", base);
    defer {
        res.buf.deinit(std.testing.allocator);
        res.spans.deinit(std.testing.allocator);
    }
    try std.testing.expectEqualStrings("boldred", res.buf.items);
    try std.testing.expectEqual(@as(usize, 1), res.spans.items.len);
    try std.testing.expect(res.spans.items[0].st.bold);
    try std.testing.expect(frame.Color.eql(res.spans.items[0].st.fg, .{ .idx = 1 }));
}

test "tool result preserves ANSI colors" {
    var tr = Transcript.init(std.testing.allocator);
    defer tr.deinit();

    try tr.append(.{ .tool_result = .{
        .id = "t1",
        .out = "\x1b[31mfail\x1b[0m ok",
        .is_err = false,
    } });

    const blk = &tr.blocks.items[0];
    // Text should have ANSI stripped from buf but spans preserved
    try std.testing.expect(std.mem.indexOf(u8, blk.text(), "fail ok") != null);
    try std.testing.expect(blk.hasSpans());
    // The span should cover "fail" within the output portion
    try std.testing.expect(blk.spans.items.len >= 1);
}

test "tool result renders colored text to frame" {
    var tr = Transcript.init(std.testing.allocator);
    defer tr.deinit();

    try tr.append(.{ .tool_result = .{
        .id = "t1",
        .out = "\x1b[31mERR\x1b[0m",
        .is_err = false,
    } });

    const blk = &tr.blocks.items[0];
    const txt = blk.text();

    // Find where "ERR" starts in the buf
    const err_pos = std.mem.indexOf(u8, txt, "ERR").?;

    var frm = try frame.Frame.init(std.testing.allocator, 80, 1);
    defer frm.deinit(std.testing.allocator);
    try tr.render(&frm, .{ .x = 0, .y = 0, .w = 80, .h = 1 });

    // +1 for left padding
    const c = try frm.cell(err_pos + 1, 0);
    try std.testing.expectEqual(@as(u21, 'E'), c.cp);
    try std.testing.expect(frame.Color.eql(c.style.fg, .{ .idx = 1 }));
}

test "SgrIter parses semicolon-separated params" {
    var it = SgrIter{ .data = "1;31" };
    try std.testing.expectEqual(@as(u16, 1), it.next().?);
    try std.testing.expectEqual(@as(u16, 31), it.next().?);
    try std.testing.expect(it.next() == null);
}

test "SgrIter empty params yields zero" {
    var it = SgrIter{ .data = "" };
    try std.testing.expectEqual(@as(u16, 0), it.next().?);
    try std.testing.expect(it.next() == null);
}

test "parseAnsi bright colors" {
    const base: frame.Style = .{};
    var res = try parseAnsi(std.testing.allocator, "\x1b[91mhi\x1b[0m", base);
    defer {
        res.buf.deinit(std.testing.allocator);
        res.spans.deinit(std.testing.allocator);
    }
    try std.testing.expectEqualStrings("hi", res.buf.items);
    try std.testing.expect(frame.Color.eql(res.spans.items[0].st.fg, .{ .idx = 9 }));
}

test "parseAnsi bg color" {
    const base: frame.Style = .{};
    var res = try parseAnsi(std.testing.allocator, "\x1b[42mgreen\x1b[0m", base);
    defer {
        res.buf.deinit(std.testing.allocator);
        res.spans.deinit(std.testing.allocator);
    }
    try std.testing.expectEqualStrings("green", res.buf.items);
    try std.testing.expect(frame.Color.eql(res.spans.items[0].st.bg, .{ .idx = 2 }));
}

test "scrollUp and scrollDown adjust offset" {
    var tr = Transcript.init(std.testing.allocator);
    defer tr.deinit();

    try std.testing.expectEqual(@as(usize, 0), tr.scroll_off);
    tr.scrollUp(5);
    try std.testing.expectEqual(@as(usize, 5), tr.scroll_off);
    tr.scrollDown(3);
    try std.testing.expectEqual(@as(usize, 2), tr.scroll_off);
    tr.scrollDown(10);
    try std.testing.expectEqual(@as(usize, 0), tr.scroll_off);
}

test "scrollUp saturates" {
    var tr = Transcript.init(std.testing.allocator);
    defer tr.deinit();

    tr.scroll_off = std.math.maxInt(usize) - 1;
    tr.scrollUp(5);
    try std.testing.expectEqual(std.math.maxInt(usize), tr.scroll_off);
}

test "scrollToBottom resets offset" {
    var tr = Transcript.init(std.testing.allocator);
    defer tr.deinit();

    tr.scrollUp(100);
    tr.scrollToBottom();
    try std.testing.expectEqual(@as(usize, 0), tr.scroll_off);
}

test "render with scroll offset shows earlier content" {
    var tr = Transcript.init(std.testing.allocator);
    defer tr.deinit();

    // 4 single-line blocks, viewport of 2 rows
    try tr.append(.{ .text = "AAA" });
    try tr.userText("BBB");
    try tr.userText("CCC");
    try tr.userText("DDD");

    // At bottom (scroll_off=0): should show CCC, DDD
    var frm = try frame.Frame.init(std.testing.allocator, 20, 2);
    defer frm.deinit(std.testing.allocator);
    try tr.render(&frm, .{ .x = 0, .y = 0, .w = 20, .h = 2 });

    var raw0: [20]u8 = undefined;
    var raw1: [20]u8 = undefined;
    var r0 = try rowAscii(&frm, 0, raw0[0..]);
    var r1 = try rowAscii(&frm, 1, raw1[0..]);
    try std.testing.expect(std.mem.indexOf(u8, r0, "CCC") != null);
    try std.testing.expect(std.mem.indexOf(u8, r1, "DDD") != null);

    // Scroll up 2 lines: should show AAA, BBB
    tr.scrollUp(2);
    try tr.render(&frm, .{ .x = 0, .y = 0, .w = 20, .h = 2 });

    r0 = try rowAscii(&frm, 0, raw0[0..]);
    r1 = try rowAscii(&frm, 1, raw1[0..]);
    try std.testing.expect(std.mem.indexOf(u8, r0, "AAA") != null);
    try std.testing.expect(std.mem.indexOf(u8, r1, "BBB") != null);
}

test "show_tools hides tool blocks" {
    var tr = Transcript.init(std.testing.allocator);
    defer tr.deinit();

    try tr.append(.{ .text = "hello" });
    try tr.append(.{ .tool_call = .{ .id = "c1", .name = "read", .args = "{}" } });
    try tr.append(.{ .tool_result = .{ .id = "c1", .out = "ok", .is_err = false } });
    try tr.append(.{ .text = "bye" });

    // 4 blocks visible by default
    var frm = try frame.Frame.init(std.testing.allocator, 30, 4);
    defer frm.deinit(std.testing.allocator);
    try tr.render(&frm, .{ .x = 0, .y = 0, .w = 30, .h = 4 });
    var raw: [30]u8 = undefined;
    const r1 = try rowAscii(&frm, 1, raw[0..]);
    try std.testing.expect(std.mem.indexOf(u8, r1, "[tool") != null);

    // Hide tools
    tr.show_tools = false;
    try tr.render(&frm, .{ .x = 0, .y = 0, .w = 30, .h = 4 });
    const r0h = try rowAscii(&frm, 0, raw[0..]);
    try std.testing.expect(std.mem.indexOf(u8, r0h, "hello") != null);
    const r1h = try rowAscii(&frm, 1, raw[0..]);
    try std.testing.expect(std.mem.indexOf(u8, r1h, "bye") != null);
}

test "thinking collapsed by default shows label with style" {
    var tr = Transcript.init(std.testing.allocator);
    defer tr.deinit();

    try tr.append(.{ .text = "before" });
    try tr.append(.{ .thinking = "deep reasoning here" });
    try tr.append(.{ .text = "after" });

    // Default: show_thinking=false → collapsed label
    var frm = try frame.Frame.init(std.testing.allocator, 20, 3);
    defer frm.deinit(std.testing.allocator);
    try tr.render(&frm, .{ .x = 0, .y = 0, .w = 20, .h = 3 });

    var raw: [20]u8 = undefined;
    const r0 = try rowAscii(&frm, 0, raw[0..]);
    try std.testing.expect(std.mem.indexOf(u8, r0, "before") != null);
    const r1 = try rowAscii(&frm, 1, raw[0..]);
    try std.testing.expect(std.mem.indexOf(u8, r1, "Thinking...") != null);
    // Full content NOT shown
    try std.testing.expect(std.mem.indexOf(u8, r1, "deep reasoning") == null);

    // Verify style: collapsed thinking label has italic + thinking_fg
    const t = theme.get();
    const c_think = try frm.cell(1, 1); // col 1 = first char after padding
    try std.testing.expect(c_think.style.italic);
    try std.testing.expect(frame.Color.eql(c_think.style.fg, t.thinking_fg));

    const r2 = try rowAscii(&frm, 2, raw[0..]);
    try std.testing.expect(std.mem.indexOf(u8, r2, "after") != null);

    // Toggle on → full content visible with italic style
    tr.show_thinking = true;
    var frm2 = try frame.Frame.init(std.testing.allocator, 40, 3);
    defer frm2.deinit(std.testing.allocator);
    try tr.render(&frm2, .{ .x = 0, .y = 0, .w = 40, .h = 3 });
    var raw2: [40]u8 = undefined;
    const r1v = try rowAscii(&frm2, 1, raw2[0..]);
    try std.testing.expect(std.mem.indexOf(u8, r1v, "[thinking]") != null);
    // Expanded thinking also has italic + thinking_fg
    const c_exp = try frm2.cell(1, 1);
    try std.testing.expect(c_exp.style.italic);
    try std.testing.expect(frame.Color.eql(c_exp.style.fg, t.thinking_fg));
}

test "error block renders with err fg, bold, and error bg" {
    var tr = Transcript.init(std.testing.allocator);
    defer tr.deinit();

    try tr.append(.{ .err = "rate limit exceeded" });

    var frm = try frame.Frame.init(std.testing.allocator, 40, 1);
    defer frm.deinit(std.testing.allocator);
    try tr.render(&frm, .{ .x = 0, .y = 0, .w = 40, .h = 1 });

    const t = theme.get();
    // Col 0 = padding with bg fill
    const c0 = try frm.cell(0, 0);
    try std.testing.expect(frame.Color.eql(c0.style.bg, t.tool_error_bg));
    // Col 1 = first text char with err fg + bold + error bg
    const c1 = try frm.cell(1, 0);
    try std.testing.expect(frame.Color.eql(c1.style.fg, t.err));
    try std.testing.expect(c1.style.bold);
    try std.testing.expect(frame.Color.eql(c1.style.bg, t.tool_error_bg));
    // Trailing cols also have error bg
    const c_last = try frm.cell(39, 0);
    try std.testing.expect(frame.Color.eql(c_last.style.bg, t.tool_error_bg));
}

test "user message has user_msg_bg" {
    var tr = Transcript.init(std.testing.allocator);
    defer tr.deinit();

    try tr.userText("hello from user");

    var frm = try frame.Frame.init(std.testing.allocator, 30, 1);
    defer frm.deinit(std.testing.allocator);
    try tr.render(&frm, .{ .x = 0, .y = 0, .w = 30, .h = 1 });

    const t = theme.get();
    // Padding col and text col both have user_msg_bg
    const c0 = try frm.cell(0, 0);
    try std.testing.expect(frame.Color.eql(c0.style.bg, t.user_msg_bg));
    const c1 = try frm.cell(1, 0);
    try std.testing.expect(frame.Color.eql(c1.style.bg, t.user_msg_bg));
    // Trailing fill
    const c_last = try frm.cell(29, 0);
    try std.testing.expect(frame.Color.eql(c_last.style.bg, t.user_msg_bg));
}

test "info text has dim fg and no bg" {
    var tr = Transcript.init(std.testing.allocator);
    defer tr.deinit();

    try tr.infoText("loaded CLAUDE.md");

    var frm = try frame.Frame.init(std.testing.allocator, 30, 1);
    defer frm.deinit(std.testing.allocator);
    try tr.render(&frm, .{ .x = 0, .y = 0, .w = 30, .h = 1 });

    const t = theme.get();
    const c1 = try frm.cell(1, 0);
    try std.testing.expect(frame.Color.eql(c1.style.fg, t.dim));
    // No bg fill for info text (default bg)
    try std.testing.expect(c1.style.bg.isDefault());
}

test "tool result success has success fg and success bg" {
    var tr = Transcript.init(std.testing.allocator);
    defer tr.deinit();

    try tr.append(.{ .tool_result = .{
        .id = "r1",
        .out = "all good",
        .is_err = false,
    } });

    var frm = try frame.Frame.init(std.testing.allocator, 50, 1);
    defer frm.deinit(std.testing.allocator);
    try tr.render(&frm, .{ .x = 0, .y = 0, .w = 50, .h = 1 });

    const t = theme.get();
    const c1 = try frm.cell(1, 0);
    try std.testing.expect(frame.Color.eql(c1.style.fg, t.success));
    try std.testing.expect(frame.Color.eql(c1.style.bg, t.tool_success_bg));
    // Full-width bg fill
    const c_last = try frm.cell(49, 0);
    try std.testing.expect(frame.Color.eql(c_last.style.bg, t.tool_success_bg));
}

test "tool result error has err fg and error bg" {
    var tr = Transcript.init(std.testing.allocator);
    defer tr.deinit();

    try tr.append(.{ .tool_result = .{
        .id = "r2",
        .out = "not found",
        .is_err = true,
    } });

    var frm = try frame.Frame.init(std.testing.allocator, 50, 1);
    defer frm.deinit(std.testing.allocator);
    try tr.render(&frm, .{ .x = 0, .y = 0, .w = 50, .h = 1 });

    const t = theme.get();
    const c1 = try frm.cell(1, 0);
    try std.testing.expect(frame.Color.eql(c1.style.fg, t.err));
    try std.testing.expect(frame.Color.eql(c1.style.bg, t.tool_error_bg));
}

test "usage and stop have dim fg" {
    var tr = Transcript.init(std.testing.allocator);
    defer tr.deinit();

    try tr.append(.{ .usage = .{ .in_tok = 10, .out_tok = 20, .tot_tok = 30 } });
    try tr.append(.{ .stop = .{ .reason = .done } });

    var frm = try frame.Frame.init(std.testing.allocator, 40, 2);
    defer frm.deinit(std.testing.allocator);
    try tr.render(&frm, .{ .x = 0, .y = 0, .w = 40, .h = 2 });

    const t = theme.get();
    // Usage line
    const c_usage = try frm.cell(1, 0);
    try std.testing.expect(frame.Color.eql(c_usage.style.fg, t.dim));
    // Stop line
    const c_stop = try frm.cell(1, 1);
    try std.testing.expect(frame.Color.eql(c_stop.style.fg, t.dim));
}

test "scroll offset clamped to max" {
    var tr = Transcript.init(std.testing.allocator);
    defer tr.deinit();

    try tr.append(.{ .text = "A" });
    try tr.userText("B");
    try tr.userText("C");

    // 3 lines, viewport 2 => max_skip=1, scrolling up 999 should clamp
    tr.scrollUp(999);

    var frm = try frame.Frame.init(std.testing.allocator, 10, 2);
    defer frm.deinit(std.testing.allocator);
    try tr.render(&frm, .{ .x = 0, .y = 0, .w = 10, .h = 2 });

    var raw0: [10]u8 = undefined;
    var raw1: [10]u8 = undefined;
    const r0 = try rowAscii(&frm, 0, raw0[0..]);
    const r1 = try rowAscii(&frm, 1, raw1[0..]);
    try std.testing.expect(std.mem.indexOf(u8, r0, "A") != null);
    try std.testing.expect(std.mem.indexOf(u8, r1, "B") != null);
}
