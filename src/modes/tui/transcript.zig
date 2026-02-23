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

const imgproto = @import("imgproto.zig");

const Kind = enum { text, user, thinking, tool, err, meta, image };
const ToolPhase = enum { none, call, result };

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
    tool_gid: u64 = 0,
    tool_phase: ToolPhase = .none,

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

pub const ImageRef = struct {
    path: []const u8, // borrowed from block
    y: usize, // screen row
    w: usize, // available width
};

pub const Transcript = struct {
    alloc: std.mem.Allocator,
    blocks: std.ArrayListUnmanaged(Block) = .empty,
    md: markdown.MdRenderer = .{},
    scroll_off: usize = 0,
    show_tools: bool = true,
    show_thinking: bool = true,
    img_refs: [8]ImageRef = undefined,
    img_ref_n: u8 = 0,

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
            .thinking => |t| {
                // Coalesce consecutive thinking events
                if (self.blocks.items.len > 0) {
                    const last = &self.blocks.items[self.blocks.items.len - 1];
                    if (last.kind == .thinking) {
                        try ensureUtf8(t);
                        try last.buf.appendSlice(self.alloc, t);
                        return;
                    }
                }
                try self.pushBlock(.thinking, t, .{
                    .fg = theme.get().thinking_fg,
                    .italic = true,
                });
            },
            .tool_call => |tc| {
                // Format like pi: " $ command args" for bash,
                // " $ tool_name path" for file tools, etc.
                const display = fmtToolCall(self.alloc, tc.name, tc.args) catch
                    try std.fmt.allocPrint(self.alloc, " $ {s}", .{tc.name});
                defer self.alloc.free(display);
                try self.pushBlock(.tool, display, .{
                    .fg = theme.get().dim,
                    .bg = theme.get().tool_pending_bg,
                });
                self.tagLastTool(toolGroup(tc.id), .call);
            },
            .tool_result => |tr| {
                const gid = toolGroup(tr.id);
                self.setToolCallStatus(gid, tr.is_err);
                if (tr.is_err) {
                    try self.pushAnsi(.err, "", .{}, tr.out, .{
                        .fg = theme.get().err,
                        .bg = theme.get().tool_error_bg,
                    });
                    self.tagLastTool(gid, .result);
                } else {
                    // Show result with collapsing like pi
                    try self.pushToolResult(tr.out);
                    self.tagLastTool(gid, .result);
                }
            },
            .err => |t| try self.pushFmt(.err, "[err] {s}", .{t}, .{
                .fg = theme.get().err,
                .bold = true,
                .bg = theme.get().tool_error_bg,
            }),
            // Usage and stop are tracked in panels, not shown in transcript
            .usage => {},
            .stop => {},
        }
    }

    pub fn userText(self: *Transcript, t: []const u8) AppendError!void {
        try self.pushBlock(.user, t, .{ .bg = theme.get().user_msg_bg });
    }

    pub fn infoText(self: *Transcript, t: []const u8) AppendError!void {
        try self.pushBlock(.meta, t, .{ .fg = theme.get().dim });
    }

    pub fn styledText(self: *Transcript, t: []const u8, st: frame.Style) AppendError!void {
        try self.pushBlock(.meta, t, st);
    }

    pub fn imageBlock(self: *Transcript, path: []const u8) AppendError!void {
        try self.pushBlock(.image, path, .{ .fg = theme.get().dim });
    }

    pub fn pushAnsiText(self: *Transcript, ansi_text: []const u8) AppendError!void {
        try self.pushAnsi(.meta, "", .{}, ansi_text, .{});
    }

    pub fn render(self: *Transcript, frm: *frame.Frame, rect: Rect) RenderError!void {
        self.img_ref_n = 0;
        if (rect.w == 0 or rect.h == 0) return;

        _ = try rectEndX(frm, rect);
        _ = try rectEndY(frm, rect);
        try clearRect(frm, rect);

        // 1-col left padding matching pi
        const pad: usize = if (rect.w > 2) 1 else 0;
        const content_x = rect.x + pad;
        const avail_w = rect.w - pad;

        // Count total display lines at scrollbar-reserved width (single pass).
        // Using avail_w - 1 means: if overflow, count is already correct;
        // if no overflow, we use full avail_w for rendering (the slightly
        // wider width can only reduce line count, so no-overflow is stable).
        const bar_w: usize = if (avail_w >= 2) 1 else 0;
        const count_w = avail_w - bar_w;
        var total: usize = 0;
        var prev_vis: ?*Block = null;
        for (self.blocks.items) |*b| {
            if (!self.blockVisible(b)) continue;
            if (prev_vis) |prev| {
                if (needsGap(prev, b)) total += 1;
            }
            total += blockLineCount(b, count_w);
            prev_vis = b;
        }
        if (total == 0) return;

        const has_bar = total > rect.h and bar_w > 0;
        const text_w = if (has_bar) count_w else avail_w;

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
        var first_vis = true;
        var prev_rendered: ?*Block = null;
        for (self.blocks.items) |*b| {
            if (!self.blockVisible(b)) continue;

            // 1-line gap between blocks
            if (!first_vis and (prev_rendered == null or needsGap(prev_rendered.?, b))) {
                if (skipped < skip) {
                    skipped += 1;
                } else if (row < rect.h) {
                    row += 1;
                }
            }
            first_vis = false;
            prev_rendered = b;

            // Image blocks: header line + reserved rows
            if (b.kind == .image) {
                const blk_h = imgproto.img_rows;
                var img_skipped: usize = 0;
                var ir: usize = 0;
                while (ir < blk_h) : (ir += 1) {
                    if (skipped < skip) {
                        skipped += 1;
                        img_skipped += 1;
                        continue;
                    }
                    if (row >= rect.h) break;
                    const y = rect.y + row;
                    if (ir == 0) {
                        // First visible row: show header
                        _ = try frm.write(content_x, y, b.text(), b.st);
                    }
                    // Record image position (first displayed row)
                    if (ir == img_skipped and self.img_ref_n < self.img_refs.len) {
                        self.img_refs[self.img_ref_n] = .{
                            .path = b.text(),
                            .y = y,
                            .w = text_w,
                        };
                        self.img_ref_n += 1;
                    }
                    row += 1;
                }
                continue;
            }

            const txt = self.blockDisplayText(b);
            const use_md = b.kind == .text or b.kind == .user;
            if (use_md) md = .{};
            var wit = wrapIter(txt, text_w);
            var md_wit = mdWrapIter(txt, text_w);
            while (true) {
                const line = if (use_md) md_wit.next() orelse break else wit.next() orelse break;
                if (skipped < skip) {
                    skipped += 1;
                    if (use_md) {
                        // Advance markdown state for all skipped lines.
                        md.advanceSkipped(line);
                    }
                    continue;
                }
                if (row >= rect.h) break;

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

    fn blockVisible(self: *const Transcript, b: *const Block) bool {
        if (!self.show_tools and b.kind == .tool) return false;
        if (!self.show_thinking and b.kind == .thinking) return false;
        return true;
    }

    fn blockDisplayText(_: *const Transcript, b: *const Block) []const u8 {
        return b.text();
    }

    fn blockLineCount(b: *const Block, w: usize) usize {
        if (b.kind == .image) return imgproto.img_rows;
        if (b.kind == .text or b.kind == .user) return countMdLines(b.text(), w);
        return countLines(b.text(), w);
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
        ensureUtf8(txt) catch {
            self.alloc.free(txt);
            return error.InvalidUtf8;
        };
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
        parsed.buf = .empty; // prevent double-free via errdefer

        try ensureUtf8(buf.items);

        try self.blocks.append(self.alloc, .{
            .kind = kind,
            .buf = buf,
            .st = base_st,
            .spans = parsed.spans,
        });
    }

    /// Show tool result, collapsing long output like pi does:
    /// "... (N earlier lines, ctrl+o to expand)"
    fn pushToolResult(self: *Transcript, out: []const u8) AppendError!void {
        const max_tail = 6; // show last N lines
        var lines: usize = 0;
        for (out) |c| {
            if (c == '\n') lines += 1;
        }
        if (out.len > 0 and out[out.len - 1] != '\n') lines += 1;

        if (lines <= max_tail + 1) {
            // Short enough: show all
            try self.pushAnsi(.tool, "", .{}, out, .{
                .fg = theme.get().dim,
                .bg = theme.get().tool_success_bg,
            });
            return;
        }

        // Find where the tail starts
        const hidden = lines - max_tail;
        var skip: usize = 0;
        var nl_count: usize = 0;
        for (out, 0..) |c, idx| {
            if (c == '\n') {
                nl_count += 1;
                if (nl_count == hidden) {
                    skip = idx + 1;
                    break;
                }
            }
        }

        try self.pushAnsi(.tool, " ... ({d} earlier lines, ctrl+o to expand)\n", .{hidden}, out[skip..], .{
            .fg = theme.get().dim,
            .bg = theme.get().tool_success_bg,
        });
    }

    fn setToolCallStatus(self: *Transcript, gid: u64, is_err: bool) void {
        if (gid == 0) return;
        var i = self.blocks.items.len;
        while (i > 0) {
            i -= 1;
            var b = &self.blocks.items[i];
            if (b.tool_gid != gid or b.tool_phase != .call) continue;
            b.st.bg = if (is_err) theme.get().tool_error_bg else theme.get().tool_success_bg;
            return;
        }
    }

    fn tagLastTool(self: *Transcript, gid: u64, phase: ToolPhase) void {
        if (self.blocks.items.len == 0) return;
        var b = &self.blocks.items[self.blocks.items.len - 1];
        b.tool_gid = gid;
        b.tool_phase = phase;
    }
};

fn toolGroup(id: []const u8) u64 {
    if (id.len == 0) return 0;
    return std.hash.Wyhash.hash(0, id);
}

fn needsGap(prev: *const Block, cur: *const Block) bool {
    if (prev.tool_gid != 0 and prev.tool_gid == cur.tool_gid) return false;
    return true;
}

// -- Tool call formatting --

fn fmtToolCall(alloc: std.mem.Allocator, name: []const u8, args: []const u8) ![]u8 {
    // Parse JSON args to extract display-friendly command
    // For bash: show "$ cd ... && cmd"
    // For file tools: show "$ tool_name path"
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, args, .{}) catch
        return std.fmt.allocPrint(alloc, " $ {s}", .{name});
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return std.fmt.allocPrint(alloc, " $ {s}", .{name}),
    };

    // bash tool: show command
    if (std.mem.eql(u8, name, "bash")) {
        if (obj.get("command")) |cmd| {
            const cmd_str = switch (cmd) {
                .string => |s| s,
                else => return std.fmt.allocPrint(alloc, " $ bash", .{}),
            };
            return std.fmt.allocPrint(alloc, " $ {s}", .{cmd_str});
        }
    }

    // File tools: show path
    if (obj.get("path")) |path| {
        const path_str = switch (path) {
            .string => |s| s,
            else => return std.fmt.allocPrint(alloc, " $ {s}", .{name}),
        };
        return std.fmt.allocPrint(alloc, " $ {s} {s}", .{ name, path_str });
    }

    // edit: show file_path
    if (obj.get("file_path")) |path| {
        const path_str = switch (path) {
            .string => |s| s,
            else => return std.fmt.allocPrint(alloc, " $ {s}", .{name}),
        };
        return std.fmt.allocPrint(alloc, " $ {s} {s}", .{ name, path_str });
    }

    return std.fmt.allocPrint(alloc, " $ {s}", .{name});
}

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

            const cw: usize = if (cp == '\t') 1 else wc.wcwidth(cp);
            cols += cw;
            if (cols > self.w) {
                // Need to break - look backward for space
                var brk = i;
                var scan = i;
                var found_space = false;
                while (scan > start) {
                    scan -= 1;
                    if (self.text[scan] == ' ' or self.text[scan] == '\t') {
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
                    // Hard break — must advance at least one codepoint
                    const end = if (i == start) cp_end else i;
                    const line = self.text[start..end];
                    self.pos = end;
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

pub const MdWrapIter = struct {
    text: []const u8,
    pos: usize,
    w: usize,
    line_wit: ?WrapIter = null,

    pub fn next(self: *MdWrapIter) ?[]const u8 {
        if (self.w == 0) return null;
        while (true) {
            if (self.line_wit) |*wit| {
                if (wit.next()) |seg| return seg;
                self.line_wit = null;
            }
            if (self.pos >= self.text.len) return null;

            const start = self.pos;
            var i = start;
            while (i < self.text.len and self.text[i] != '\n') : (i += 1) {}
            const line = self.text[start..i];
            self.pos = if (i < self.text.len) i + 1 else i;

            if (line.len == 0) return line;
            if (isMdTableLine(line)) return line;

            self.line_wit = wrapIter(line, self.w);
        }
    }
};

pub fn mdWrapIter(text: []const u8, w: usize) MdWrapIter {
    return .{ .text = text, .pos = 0, .w = w };
}

fn isMdTableLine(line: []const u8) bool {
    const t = std.mem.trimLeft(u8, line, " \t");
    return t.len > 0 and t[0] == '|';
}

pub fn countLines(text: []const u8, w: usize) usize {
    if (w == 0) return 0;
    if (text.len == 0) return 1; // empty block = 1 display line
    var n: usize = 0;
    var it = wrapIter(text, w);
    while (it.next() != null) n += 1;
    return if (n == 0) 1 else n;
}

fn countMdLines(text: []const u8, w: usize) usize {
    if (w == 0) return 0;
    if (text.len == 0) return 1;
    var n: usize = 0;
    var it = mdWrapIter(text, w);
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
        // Skip control chars to prevent terminal escape leaking
        if (cp < 0x20 and cp != '\t') continue;
        if (cp == 0x7f) continue;
        // Render tab as space
        const rcp: u21 = if (cp == '\t') ' ' else cp;
        const w: usize = if (cp == '\t') 1 else wcwidth(cp);
        if (w == 0) continue;
        if (col + w > frm.w) break;
        frm.cells[y * frm.w + col] = .{ .cp = rcp, .style = st };
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
            } else if (text[i] == ']') {
                // OSC: ESC ] ... (BEL | ESC \)
                i += 1; // consume ']'
                while (i < text.len) {
                    if (text[i] == 0x07) {
                        // BEL terminator
                        i += 1;
                        break;
                    }
                    if (text[i] == 0x1b and i + 1 < text.len and text[i + 1] == '\\') {
                        // ST terminator
                        i += 2;
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
        if (i + n > text.len) return error.InvalidUtf8;
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

    // 4 blocks + 3 gaps = 7 lines; show last 5 to see two, $ read, three
    var frm = try frame.Frame.init(std.testing.allocator, 24, 5);
    defer frm.deinit(std.testing.allocator);
    try tr.render(&frm, .{
        .x = 0,
        .y = 0,
        .w = 24,
        .h = 5,
    });

    // Lines: two(0), gap(1), $ read(2), gap(3), three(4)
    var raw: [24]u8 = undefined;
    const r0 = try rowAscii(&frm, 0, raw[0..]);
    try std.testing.expect(std.mem.indexOf(u8, r0, "two") != null);
    const r2 = try rowAscii(&frm, 2, raw[0..]);
    try std.testing.expect(std.mem.indexOf(u8, r2, "$ read") != null);
    const r4 = try rowAscii(&frm, 4, raw[0..]);
    try std.testing.expect(std.mem.indexOf(u8, r4, "three") != null);
}

test "transcript tool call rows have dim fg" {
    var tr = Transcript.init(std.testing.allocator);
    defer tr.deinit();

    try tr.append(.{ .tool_call = .{
        .id = "x",
        .name = "ls",
        .args = "{\"path\":\".\"}",
    } });

    var frm = try frame.Frame.init(std.testing.allocator, 30, 1);
    defer frm.deinit(std.testing.allocator);
    try tr.render(&frm, .{ .x = 0, .y = 0, .w = 30, .h = 1 });

    // Tool calls now render as "$ ls ." in dim
    const c1 = try frm.cell(1, 0);
    try std.testing.expect(frame.Color.eql(c1.style.fg, theme.get().dim));
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

test "word wrap wide char in narrow terminal does not hang" {
    // Wide CJK char (width=2) in width=1 terminal — must not infinite loop
    var it = wrapIter("中", 1);
    const l0 = it.next().?;
    try std.testing.expectEqualStrings("中", l0);
    try std.testing.expect(it.next() == null);
}

test "word wrap tabs count as width 1" {
    // Tab is whitespace → acts as a break point and counts as 1 col
    var it = wrapIter("a\tb\tc", 3);
    const l0 = it.next().?;
    try std.testing.expectEqualStrings("a", l0); // breaks at tab
    const l1 = it.next().?;
    try std.testing.expectEqualStrings("b\tc", l1); // b + tab + c = 3 cols, fits
    try std.testing.expect(it.next() == null);
}

test "markdown wrap keeps table rows intact" {
    var it = mdWrapIter(
        "| Name | Description |\n| --- | --- |\n| A | a very long description that should not wrap |",
        12,
    );
    const l0 = it.next().?;
    const l1 = it.next().?;
    const l2 = it.next().?;
    try std.testing.expectEqualStrings("| Name | Description |", l0);
    try std.testing.expectEqualStrings("| --- | --- |", l1);
    try std.testing.expectEqualStrings("| A | a very long description that should not wrap |", l2);
    try std.testing.expect(it.next() == null);
}

test "markdown wrap still wraps non-table lines" {
    var it = mdWrapIter("alpha beta gamma", 8);
    const l0 = it.next().?;
    const l1 = it.next().?;
    const l2 = it.next().?;
    try std.testing.expectEqualStrings("alpha", l0);
    try std.testing.expectEqualStrings("beta", l1);
    try std.testing.expectEqualStrings("gamma", l2);
    try std.testing.expect(it.next() == null);
}

test "transcript keeps markdown table state when top rows are skipped" {
    var tr = Transcript.init(std.testing.allocator);
    defer tr.deinit();

    try tr.append(.{ .text =
        "| H1 | H2 |\n" ++
        "| --- | --- |\n" ++
        "| a1 | b1 |\n" ++
        "| a2 | b2 |"
    });

    var frm = try frame.Frame.init(std.testing.allocator, 30, 1);
    defer frm.deinit(std.testing.allocator);
    try tr.render(&frm, .{ .x = 0, .y = 0, .w = 30, .h = 1 });

    var a2_col: ?usize = null;
    var x: usize = 0;
    while (x < frm.w) : (x += 1) {
        const c = try frm.cell(x, 0);
        if (c.cp == 'a') {
            const n = if (x + 1 < frm.w) try frm.cell(x + 1, 0) else continue;
            if (n.cp == '2') {
                a2_col = x;
                break;
            }
        }
    }
    try std.testing.expect(a2_col != null);
    const c = try frm.cell(a2_col.?, 0);
    try std.testing.expect(!c.style.bold);
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

test "parseAnsi strips OSC terminated by BEL" {
    const base: frame.Style = .{};
    var res = try parseAnsi(std.testing.allocator, "\x1b]0;my title\x07hello", base);
    defer {
        res.buf.deinit(std.testing.allocator);
        res.spans.deinit(std.testing.allocator);
    }
    try std.testing.expectEqualStrings("hello", res.buf.items);
}

test "parseAnsi strips OSC terminated by ST" {
    const base: frame.Style = .{};
    var res = try parseAnsi(std.testing.allocator, "\x1b]0;my title\x1b\\world", base);
    defer {
        res.buf.deinit(std.testing.allocator);
        res.spans.deinit(std.testing.allocator);
    }
    try std.testing.expectEqualStrings("world", res.buf.items);
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

    // 4 single-line blocks + 3 gaps = 7 lines total
    try tr.append(.{ .text = "AAA" });
    try tr.userText("BBB");
    try tr.userText("CCC");
    try tr.userText("DDD");

    // At bottom (scroll_off=0) with 3-row viewport: gap, DDD (last 2 of 7)
    // Use 3 rows to see: CCC, gap, DDD
    var frm = try frame.Frame.init(std.testing.allocator, 20, 3);
    defer frm.deinit(std.testing.allocator);
    try tr.render(&frm, .{ .x = 0, .y = 0, .w = 20, .h = 3 });

    var raw: [20]u8 = undefined;
    {
        const r0 = try rowAscii(&frm, 0, raw[0..]);
        try std.testing.expect(std.mem.indexOf(u8, r0, "CCC") != null);
    }
    {
        const r2 = try rowAscii(&frm, 2, raw[0..]);
        try std.testing.expect(std.mem.indexOf(u8, r2, "DDD") != null);
    }

    // Scroll up 4 lines: show AAA, gap, BBB from top
    tr.scrollUp(4);
    try tr.render(&frm, .{ .x = 0, .y = 0, .w = 20, .h = 3 });

    {
        const r0 = try rowAscii(&frm, 0, raw[0..]);
        try std.testing.expect(std.mem.indexOf(u8, r0, "AAA") != null);
    }
    {
        const r2 = try rowAscii(&frm, 2, raw[0..]);
        try std.testing.expect(std.mem.indexOf(u8, r2, "BBB") != null);
    }
}

test "show_tools hides tool blocks" {
    var tr = Transcript.init(std.testing.allocator);
    defer tr.deinit();

    try tr.append(.{ .text = "hello" });
    try tr.append(.{ .tool_call = .{ .id = "c1", .name = "read", .args = "{}" } });
    try tr.append(.{ .tool_result = .{ .id = "c1", .out = "ok", .is_err = false } });
    try tr.append(.{ .text = "bye" });

    // 4 blocks + 3 gaps = 7 lines visible by default
    var frm = try frame.Frame.init(std.testing.allocator, 30, 7);
    defer frm.deinit(std.testing.allocator);
    try tr.render(&frm, .{ .x = 0, .y = 0, .w = 30, .h = 7 });
    var raw: [30]u8 = undefined;
    // hello, gap, $ read, gap, ok, gap, bye
    const r2 = try rowAscii(&frm, 2, raw[0..]);
    try std.testing.expect(std.mem.indexOf(u8, r2, "$ read") != null);

    // Hide tools: 2 blocks (hello, bye) + 1 gap = 3 lines
    tr.show_tools = false;
    try tr.render(&frm, .{ .x = 0, .y = 0, .w = 30, .h = 7 });
    const r0h = try rowAscii(&frm, 0, raw[0..]);
    try std.testing.expect(std.mem.indexOf(u8, r0h, "hello") != null);
    const r2h = try rowAscii(&frm, 2, raw[0..]);
    try std.testing.expect(std.mem.indexOf(u8, r2h, "bye") != null);
}

test "thinking visible by default, hidden when toggled" {
    var tr = Transcript.init(std.testing.allocator);
    defer tr.deinit();

    try tr.append(.{ .text = "before" });
    try tr.append(.{ .thinking = "deep reasoning here" });
    try tr.append(.{ .text = "after" });

    // Default: show_thinking=true → 3 blocks + 2 gaps = 5 lines
    // h=5 shows all: before, gap, deep reasoning, gap, after
    var frm = try frame.Frame.init(std.testing.allocator, 40, 5);
    defer frm.deinit(std.testing.allocator);
    try tr.render(&frm, .{ .x = 0, .y = 0, .w = 40, .h = 5 });
    var raw: [40]u8 = undefined;
    const r2v = try rowAscii(&frm, 2, raw[0..]);
    try std.testing.expect(std.mem.indexOf(u8, r2v, "deep reasoning") != null);
    const t = theme.get();
    const c_exp = try frm.cell(1, 2);
    try std.testing.expect(c_exp.style.italic);
    try std.testing.expect(frame.Color.eql(c_exp.style.fg, t.thinking_fg));

    // Toggle off → 2 blocks + 1 gap = 3 lines: before, gap, after
    tr.show_thinking = false;
    var frm2 = try frame.Frame.init(std.testing.allocator, 20, 3);
    defer frm2.deinit(std.testing.allocator);
    try tr.render(&frm2, .{ .x = 0, .y = 0, .w = 20, .h = 3 });
    var raw2: [20]u8 = undefined;
    const r0 = try rowAscii(&frm2, 0, raw2[0..]);
    try std.testing.expect(std.mem.indexOf(u8, r0, "before") != null);
    const r2 = try rowAscii(&frm2, 2, raw2[0..]);
    try std.testing.expect(std.mem.indexOf(u8, r2, "after") != null);
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

test "tool result success has dim fg" {
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
    try std.testing.expect(frame.Color.eql(c1.style.fg, t.dim));
    try std.testing.expect(frame.Color.eql(c1.style.bg, t.tool_success_bg));
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

test "tool call pending recolors to success and joins result block" {
    var tr = Transcript.init(std.testing.allocator);
    defer tr.deinit();

    try tr.append(.{ .tool_call = .{ .id = "c9", .name = "read", .args = "{\"path\":\"a\"}" } });

    var frm = try frame.Frame.init(std.testing.allocator, 30, 2);
    defer frm.deinit(std.testing.allocator);
    try tr.render(&frm, .{ .x = 0, .y = 0, .w = 30, .h = 2 });

    const t = theme.get();
    const call_pending = try frm.cell(1, 0);
    try std.testing.expect(frame.Color.eql(call_pending.style.bg, t.tool_pending_bg));

    try tr.append(.{ .tool_result = .{ .id = "c9", .out = "ok", .is_err = false } });
    try tr.render(&frm, .{ .x = 0, .y = 0, .w = 30, .h = 2 });

    const call_done = try frm.cell(1, 0);
    try std.testing.expect(frame.Color.eql(call_done.style.bg, t.tool_success_bg));
    const result_row = try frm.cell(1, 1);
    try std.testing.expect(frame.Color.eql(result_row.style.bg, t.tool_success_bg));
}

test "tool call recolors to error with failed result" {
    var tr = Transcript.init(std.testing.allocator);
    defer tr.deinit();

    try tr.append(.{ .tool_call = .{ .id = "ce", .name = "bash", .args = "{\"cmd\":\"false\"}" } });
    try tr.append(.{ .tool_result = .{ .id = "ce", .out = "failed", .is_err = true } });

    var frm = try frame.Frame.init(std.testing.allocator, 30, 2);
    defer frm.deinit(std.testing.allocator);
    try tr.render(&frm, .{ .x = 0, .y = 0, .w = 30, .h = 2 });

    const t = theme.get();
    const call_row = try frm.cell(1, 0);
    const result_row = try frm.cell(1, 1);
    try std.testing.expect(frame.Color.eql(call_row.style.bg, t.tool_error_bg));
    try std.testing.expect(frame.Color.eql(result_row.style.bg, t.tool_error_bg));
    try std.testing.expect(frame.Color.eql(result_row.style.fg, t.err));
}

test "usage and stop produce no transcript blocks" {
    var tr = Transcript.init(std.testing.allocator);
    defer tr.deinit();

    try tr.append(.{ .usage = .{ .in_tok = 10, .out_tok = 20, .tot_tok = 30 } });
    try tr.append(.{ .stop = .{ .reason = .done } });

    // No blocks should be added for usage/stop events
    try std.testing.expectEqual(@as(usize, 0), tr.count());
}

test "scroll offset clamped to max" {
    var tr = Transcript.init(std.testing.allocator);
    defer tr.deinit();

    try tr.append(.{ .text = "A" });
    try tr.userText("B");
    try tr.userText("C");

    // 3 blocks + 2 gaps = 5 lines, viewport 3 => max_skip=2
    // Scrolling up 999 clamps to max, showing first 3: A, gap, B
    tr.scrollUp(999);

    var frm = try frame.Frame.init(std.testing.allocator, 10, 3);
    defer frm.deinit(std.testing.allocator);
    try tr.render(&frm, .{ .x = 0, .y = 0, .w = 10, .h = 3 });

    var raw: [10]u8 = undefined;
    const r0 = try rowAscii(&frm, 0, raw[0..]);
    try std.testing.expect(std.mem.indexOf(u8, r0, "A") != null);
    const r2 = try rowAscii(&frm, 2, raw[0..]);
    try std.testing.expect(std.mem.indexOf(u8, r2, "B") != null);
}
