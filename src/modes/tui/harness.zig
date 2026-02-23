const std = @import("std");
const core = @import("../../core/mod.zig");
pub const editor = @import("editor.zig");
const mouse = @import("mouse.zig");
const transcript = @import("transcript.zig");
const panels = @import("panels.zig");
const frame = @import("frame.zig");
const render = @import("render.zig");
const theme = @import("theme.zig");
const overlay_mod = @import("overlay.zig");
const cmdprev_mod = @import("cmdprev.zig");
const pathcomp_mod = @import("pathcomp.zig");
const imgproto_mod = @import("imgproto.zig");
const spinner = @import("spinner.zig");

pub const Ui = struct {
    alloc: std.mem.Allocator,
    ed: editor.Editor,
    tr: transcript.Transcript,
    pn: panels.Panels,
    frm: frame.Frame,
    rnd: render.Renderer,
    border_fg: frame.Color = .{ .rgb = 0x81a2be },
    ov: ?overlay_mod.Overlay = null,
    cp: ?cmdprev_mod.CmdPreview = null,
    arg_src: ?[]const []const u8 = null, // runtime-provided arg completion source
    path_items: ?[][]u8 = null, // owned file path completion items
    path_prefix: ?[]u8 = null, // cached prefix for path_items
    img_cap: imgproto_mod.ImageCap = .none,
    spin: u8 = 0,

    const BorderStatus = struct {
        label: []const u8,
        fg: frame.Color,
    };

    pub fn init(
        alloc: std.mem.Allocator,
        w: usize,
        h: usize,
        model: []const u8,
        provider: []const u8,
    ) !Ui {
        return initFull(alloc, w, h, model, provider, "", "", null);
    }

    pub fn initFull(
        alloc: std.mem.Allocator,
        w: usize,
        h: usize,
        model: []const u8,
        provider: []const u8,
        cwd: []const u8,
        branch: []const u8,
        theme_name: ?[]const u8,
    ) !Ui {
        theme.init(theme_name);
        return .{
            .alloc = alloc,
            .ed = editor.Editor.init(alloc),
            .tr = transcript.Transcript.init(alloc),
            .pn = try panels.Panels.initFull(alloc, model, provider, cwd, branch),
            .frm = try frame.Frame.init(alloc, w, h),
            .rnd = try render.Renderer.init(alloc, w, h),
        };
    }

    pub fn resize(self: *Ui, w: usize, h: usize) !void {
        if (w == self.frm.w and h == self.frm.h) return;
        const new_frm = try frame.Frame.init(self.alloc, w, h);
        const new_rnd = try render.Renderer.init(self.alloc, w, h);
        self.rnd.deinit();
        self.frm.deinit(self.alloc);
        self.frm = new_frm;
        self.rnd = new_rnd;
    }

    pub fn deinit(self: *Ui) void {
        self.clearPathItems();
        self.rnd.deinit();
        self.frm.deinit(self.alloc);
        self.pn.deinit();
        self.tr.deinit();
        self.ed.deinit();
        self.* = undefined;
    }

    pub fn clearPathItems(self: *Ui) void {
        if (self.path_items) |items| {
            pathcomp_mod.freeList(self.alloc, items);
            self.path_items = null;
        }
        if (self.path_prefix) |p| {
            self.alloc.free(p);
            self.path_prefix = null;
        }
    }

    pub fn onProvider(self: *Ui, ev: core.providers.Ev) !void {
        try self.tr.append(ev);
        try self.pn.append(ev);
        if (ev == .stop and ev.stop.reason == .max_out) {
            try self.tr.infoText("[max tokens reached]");
        }
    }

    pub fn onKey(self: *Ui, key: editor.Key) !editor.Action {
        // Intercept up/down for wrapped-line navigation
        switch (key) {
            .up => if (self.wrapUp()) return .none,
            .down => if (self.wrapDown()) return .none,
            else => {},
        }
        const act = try self.ed.apply(key);
        if (act == .submit) {
            const t = self.ed.text();
            if (t.len != 0) {
                try self.ed.pushHistory(t);
                try self.tr.userText(t);
            }
            self.ed.clear();
            self.tr.scrollToBottom();
        }
        return act;
    }

    pub fn onMouse(self: *Ui, ev: mouse.Ev) void {
        switch (ev) {
            .scroll_up => self.tr.scrollUp(3),
            .scroll_down => self.tr.scrollDown(3),
            else => {},
        }
    }

    pub fn draw(self: *Ui, out: anytype) !void {
        self.frm.clear();

        const w = self.frm.w;
        const h = self.frm.h;

        // Layout matching pi: transcript | border | editor(1..N) | border | footer(2)
        const footer_h: usize = if (h >= 6) 2 else if (h >= 4) 1 else 0;
        const border_h: usize = if (h >= 5) 2 else 0;
        const max_ed: usize = 8; // max editor rows
        const ed_room = if (w > 1) w - 1 else 1; // editor display width (pad=1)
        const wi = wrapInfo(self.ed.text(), self.ed.cursor(), ed_room);
        const want_ed = @max(wi.rows, 1);
        const avail_ed = if (h > footer_h + border_h + 1) h - footer_h - border_h - 1 else 1;
        const editor_h: usize = @min(@min(want_ed, max_ed), avail_ed);
        const reserved = footer_h + border_h + editor_h;
        const tx_h = if (h > reserved) h - reserved else 0;

        if (tx_h > 0 and w > 0) {
            try self.tr.render(&self.frm, .{
                .x = 0,
                .y = 0,
                .w = w,
                .h = tx_h,
            });
        }

        if (border_h >= 1 and editor_h > 0) {
            try self.drawBorderWithStatus(tx_h);
        }

        if (editor_h > 0) {
            // Editor scroll: ensure cursor row is visible
            const ed_scroll = if (wi.cur_row >= editor_h) wi.cur_row - editor_h + 1 else 0;
            try self.drawEditor(tx_h + @min(border_h, 1), editor_h, ed_room, ed_scroll);
        }

        if (border_h >= 2) {
            try self.drawBorder(tx_h + @min(border_h, 1) + editor_h);
        }

        if (footer_h > 0) {
            try self.pn.renderFooter(&self.frm, .{
                .x = 0,
                .y = h - footer_h,
                .w = w,
                .h = footer_h,
            });
        }

        // Command preview: render below editor, overlaying lower border/footer (like pi)
        if (self.cp) |*cp| {
            const ed_y = tx_h + @min(border_h, 1);
            const below = ed_y + 1; // first row below editor
            if (below < h) {
                try cp.renderDown(&self.frm, below, w, h);
            }
        }

        if (self.ov) |*ov| {
            try ov.render(&self.frm);
        }

        try self.rnd.render(&self.frm, out);

        // Render inline images after frame (they overlay frame cells)
        if (self.img_cap != .none) {
            var i: u8 = 0;
            while (i < self.tr.img_ref_n) : (i += 1) {
                const ref = self.tr.img_refs[i];
                try imgproto_mod.writeImageAt(out, self.alloc, ref.path, 1, ref.y, ref.w, self.img_cap);
            }
        }

        // Position hardware cursor on editor
        if (editor_h > 0 and self.ov == null and w > 1) {
            const pad: usize = 1;
            const ed_y_base = tx_h + @min(border_h, 1);
            const ed_scroll = if (wi.cur_row >= editor_h) wi.cur_row - editor_h + 1 else 0;
            const vis_row = wi.cur_row - ed_scroll;
            var cup: [16]u8 = undefined;
            const seq = std.fmt.bufPrint(&cup, "\x1b[{};{}H", .{ ed_y_base + vis_row + 1, pad + wi.cur_col + 1 }) catch
                return error.Overflow;
            try out.writeAll(seq);
            try out.writeAll("\x1b[?25h"); // show cursor
        } else {
            try out.writeAll("\x1b[?25l"); // hide cursor
        }
    }

    pub fn editorText(self: *const Ui) []const u8 {
        return self.ed.text();
    }

    pub fn setModel(self: *Ui, model: []const u8) !void {
        try self.pn.setModel(model);
    }

    pub fn setProvider(self: *Ui, provider: []const u8) !void {
        try self.pn.setProvider(provider);
    }

    /// Try moving cursor up in wrapped text. Returns true if handled.
    pub fn wrapUp(self: *Ui) bool {
        const width = if (self.frm.w > 1) self.frm.w - 1 else 1;
        const wi = wrapInfo(self.ed.text(), self.ed.cursor(), width);
        if (wi.rows <= 1 or wi.cur_row == 0) return false;
        self.ed.cur = wrapRowCol(self.ed.text(), wi.cur_row - 1, wi.cur_col, width);
        return true;
    }

    /// Try moving cursor down in wrapped text. Returns true if handled.
    pub fn wrapDown(self: *Ui) bool {
        const width = if (self.frm.w > 1) self.frm.w - 1 else 1;
        const wi = wrapInfo(self.ed.text(), self.ed.cursor(), width);
        if (wi.rows <= 1 or wi.cur_row >= wi.rows - 1) return false;
        self.ed.cur = wrapRowCol(self.ed.text(), wi.cur_row + 1, wi.cur_col, width);
        return true;
    }

    pub fn updatePreview(self: *Ui) void {
        self.cp = null;

        const text = self.ed.text();
        if (text.len > 0 and text[0] == '/') {
            self.clearPathItems();
            const prefix = text[1..];
            if (std.mem.indexOfScalar(u8, prefix, ' ')) |sp| {
                if (self.arg_src) |src| {
                    const arg = std.mem.trim(u8, prefix[sp + 1 ..], " \t");
                    self.cp = cmdprev_mod.CmdPreview.updateArgs(src, arg);
                }
            } else {
                self.cp = cmdprev_mod.CmdPreview.update(prefix);
            }
        } else if (text.len > 0) {
            // Check for @ mention in last word
            const cur = self.ed.cursor();
            const ws = lastWordStart(text, cur);
            const word = text[ws..cur];
            if (word.len > 0 and word[0] == '@') {
                const pattern = word[1..];
                self.updatePathCompletion(pattern);
            } else {
                self.clearPathItems();
            }
        } else {
            self.clearPathItems();
        }
    }

    /// Update path completion with caching: if pattern extends cached prefix,
    /// filter in-place instead of re-scanning the filesystem.
    fn updatePathCompletion(self: *Ui, pattern: []const u8) void {
        // Check if we can filter cached results
        if (self.path_items != null and self.path_prefix != null) {
            const cached = self.path_prefix.?;
            if (pattern.len >= cached.len and std.mem.startsWith(u8, pattern, cached)) {
                // Pattern extends cached prefix — filter existing items
                var items = self.path_items.?;
                const old_len = items.len;
                var keep: usize = 0;
                for (items) |item| {
                    // Item paths have dir prefix; match against the file portion
                    if (std.mem.indexOf(u8, item, pattern) != null or
                        matchItemPrefix(item, pattern))
                    {
                        items[keep] = item;
                        keep += 1;
                    } else {
                        self.alloc.free(item);
                    }
                }
                if (keep == 0) {
                    self.alloc.free(items[0..old_len]);
                    self.path_items = null;
                    self.clearPathPrefix();
                    return;
                }
                const narrowed = self.alloc.alloc([]u8, keep) catch {
                    // Fallback: drop cache on allocation failure.
                    for (items[0..keep]) |item| self.alloc.free(item);
                    self.alloc.free(items[0..old_len]);
                    self.path_items = null;
                    self.clearPathPrefix();
                    return;
                };
                @memcpy(narrowed[0..keep], items[0..keep]);
                self.alloc.free(items[0..old_len]);
                self.path_items = narrowed;
                self.updatePathPrefix(pattern);
                self.cp = cmdprev_mod.CmdPreview.updateArgs(
                    pathcomp_mod.asConst(self.path_items.?),
                    pattern,
                );
                return;
            }
        }

        // Cache miss — full directory scan
        self.clearPathItems();
        if (pathcomp_mod.list(self.alloc, pattern)) |items| {
            self.path_items = items;
            self.updatePathPrefix(pattern);
            self.cp = cmdprev_mod.CmdPreview.updateArgs(
                pathcomp_mod.asConst(items),
                pattern,
            );
        }
    }

    fn updatePathPrefix(self: *Ui, pattern: []const u8) void {
        if (self.path_prefix) |p| self.alloc.free(p);
        self.path_prefix = self.alloc.dupe(u8, pattern) catch null;
    }

    fn clearPathPrefix(self: *Ui) void {
        if (self.path_prefix) |p| {
            self.alloc.free(p);
            self.path_prefix = null;
        }
    }

    fn matchItemPrefix(item: []const u8, pattern: []const u8) bool {
        // pathcomp items are "dir/name" or "name"; check if basename starts with partial
        const base = if (std.mem.lastIndexOfScalar(u8, item, '/')) |sep|
            item[sep + 1 ..]
        else
            item;
        // Strip trailing '/' for directory entries
        const name = if (base.len > 0 and base[base.len - 1] == '/')
            base[0 .. base.len - 1]
        else
            base;
        // Pattern may include directory prefix
        const pat_base = if (std.mem.lastIndexOfScalar(u8, pattern, '/')) |sep|
            pattern[sep + 1 ..]
        else
            pattern;
        return std.mem.startsWith(u8, name, pat_base);
    }

    const CpStep = struct {
        cp: u21,
        n: usize,
        w: usize,
    };

    fn nextCpLossy(text: []const u8, idx: *usize) ?CpStep {
        if (idx.* >= text.len) return null;
        const wcw = @import("wcwidth.zig").wcwidth;
        const n = std.unicode.utf8ByteSequenceLength(text[idx.*]) catch return null;
        if (idx.* + n > text.len) return null;
        const cp = std.unicode.utf8Decode(text[idx.* .. idx.* + n]) catch return null;
        return .{ .cp = cp, .n = n, .w = wcw(cp) };
    }

    fn nextCpStrict(text: []const u8, idx: *usize) error{InvalidUtf8}!?CpStep {
        if (idx.* >= text.len) return null;
        const wcw = @import("wcwidth.zig").wcwidth;
        const n = std.unicode.utf8ByteSequenceLength(text[idx.*]) catch return error.InvalidUtf8;
        if (idx.* + n > text.len) return error.InvalidUtf8;
        const cp = std.unicode.utf8Decode(text[idx.* .. idx.* + n]) catch return error.InvalidUtf8;
        return .{ .cp = cp, .n = n, .w = wcw(cp) };
    }

    pub fn clearTranscript(self: *Ui) void {
        for (self.tr.blocks.items) |*b| b.deinit(self.alloc);
        self.tr.blocks.items.len = 0;
        self.tr.scroll_off = 0;
    }

    pub fn lastResponseText(self: *const Ui) ?[]const u8 {
        // Find last text block (skip tool/meta blocks)
        var i = self.tr.blocks.items.len;
        while (i > 0) {
            i -= 1;
            const blk = &self.tr.blocks.items[i];
            if (blk.kind == .text) return blk.text();
        }
        return null;
    }

    fn drawBorder(self: *Ui, y: usize) !void {
        try self.drawBorderPlain(y, null);
    }

    fn drawBorderWithStatus(self: *Ui, y: usize) !void {
        const t = theme.get();
        const now_ms = std.time.milliTimestamp();
        const compact_on = self.pn.compactionActive(now_ms);
        const active = self.pn.run_state == .streaming or self.pn.run_state == .tool or compact_on;
        if (active) self.spin +%= 1;

        var lbl_buf: [64]u8 = undefined;
        const status: ?BorderStatus = switch (self.pn.run_state) {
            .streaming, .tool => blk: {
                const prefix: []const u8 = if (self.pn.run_state == .tool) " running tool " else " streaming ";
                const sc = spinner.cp(self.spin);
                const label = std.fmt.bufPrint(&lbl_buf, "{s}{u} ", .{ prefix, sc }) catch prefix;
                break :blk .{ .label = label, .fg = t.accent };
            },
            .canceled => .{ .label = " canceled ", .fg = t.warn },
            .failed => .{ .label = " error ", .fg = t.err },
            else => blk: {
                if (!compact_on) break :blk null;
                const sc = spinner.cp(self.spin);
                const show_spin = (self.spin & 1) == 0;
                const label = if (show_spin)
                    std.fmt.bufPrint(&lbl_buf, " compaction {u} ", .{sc}) catch " compaction "
                else
                    " compaction ";
                break :blk .{ .label = label, .fg = t.accent };
            },
        };
        try self.drawBorderPlain(y, status);
    }

    fn drawBorderPlain(self: *Ui, y: usize, status: ?BorderStatus) !void {
        const bst = frame.Style{ .fg = self.border_fg };
        var x: usize = 0;
        while (x < self.frm.w) : (x += 1) {
            try self.frm.set(x, y, 0x2500, bst); // ─
        }
        if (status) |st| {
            const lst = frame.Style{ .fg = st.fg };
            _ = try self.frm.write(1, y, st.label, lst);
        }
    }

    fn drawEditor(self: *Ui, y_base: usize, rows: usize, width: usize, scroll: usize) !void {
        const pad: usize = 1;
        if (self.frm.w <= pad or rows == 0) return;
        const text = self.ed.text();

        // Walk text, tracking wrapped rows
        var row: usize = 0;
        var col: usize = 0;
        var i: usize = 0;
        var vis_row: usize = 0;
        while (i < text.len and vis_row < rows) {
            const step = nextCpLossy(text, &i) orelse break;
            if (step.cp == '\n') {
                row += 1;
                col = 0;
                i += step.n;
                if (row >= scroll) vis_row = row - scroll;
                continue;
            }
            if (step.w == 0) {
                i += step.n;
                continue;
            }
            if (col + step.w > width) {
                row += 1;
                col = 0;
            }
            if (row >= scroll and row < scroll + rows) {
                vis_row = row - scroll;
                const x = pad + col;
                const y = y_base + vis_row;
                try self.frm.set(x, y, step.cp, .{});
                if (step.w == 2 and x + 1 < self.frm.w) {
                    try self.frm.set(x + 1, y, frame.Frame.wide_pad, .{});
                }
            }
            col += step.w;
            i += step.n;
        }
    }
};

const lastWordStart = editor.wordStartIn;

/// Wrapped-line info for cursor positioning and rendering.
const WrapInfo = struct {
    rows: usize, // total display rows
    cur_row: usize, // cursor's row (0-based)
    cur_col: usize, // cursor's column within its row
};

/// Compute wrap info for text at given display width.
fn wrapInfo(text: []const u8, byte_pos: usize, width: usize) WrapInfo {
    if (width == 0) return .{ .rows = 1, .cur_row = 0, .cur_col = 0 };
    var row: usize = 0;
    var col: usize = 0;
    var cur_row: usize = 0;
    var cur_col: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (i == byte_pos) {
            cur_row = row;
            cur_col = col;
        }
        const step = Ui.nextCpLossy(text, &i) orelse break;
        if (step.cp == '\n') {
            row += 1;
            col = 0;
            i += step.n;
            continue;
        }
        if (col + step.w > width) {
            row += 1;
            col = 0;
        }
        col += step.w;
        i += step.n;
    }
    if (byte_pos >= text.len) {
        cur_row = row;
        cur_col = col;
    }
    return .{ .rows = row + 1, .cur_row = cur_row, .cur_col = cur_col };
}

/// Find byte offset at start of a given wrapped row.
fn wrapRowStart(text: []const u8, target_row: usize, width: usize) usize {
    if (width == 0 or target_row == 0) return 0;
    var row: usize = 0;
    var col: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (row == target_row) return i;
        const step = Ui.nextCpLossy(text, &i) orelse break;
        if (step.cp == '\n') {
            row += 1;
            col = 0;
            i += step.n;
            continue;
        }
        if (col + step.w > width) {
            row += 1;
            col = 0;
            if (row == target_row) return i;
        }
        col += step.w;
        i += step.n;
    }
    return i;
}

/// Find byte offset for a given (row, col) in wrapped text.
fn wrapRowCol(text: []const u8, target_row: usize, target_col: usize, width: usize) usize {
    if (width == 0) return 0;
    var row: usize = 0;
    var col: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (row == target_row and col >= target_col) return i;
        if (row > target_row) return i;
        const step = Ui.nextCpLossy(text, &i) orelse break;
        if (step.cp == '\n') {
            if (row == target_row) return i; // at end of target row
            row += 1;
            col = 0;
            i += step.n;
            continue;
        }
        if (col + step.w > width) {
            row += 1;
            col = 0;
            if (row == target_row and col >= target_col) return i;
            if (row > target_row) return i;
        }
        col += step.w;
        i += step.n;
    }
    return i;
}

fn cursorCol(text: []const u8, byte_pos: usize) usize {
    var i: usize = 0;
    var col: usize = 0;
    while (i < byte_pos and i < text.len) {
        const step = Ui.nextCpLossy(text, &i) orelse break;
        col += step.w;
        i += step.n;
    }
    return col;
}

fn viewportSlice(text: []const u8, skip_cols: usize, cols: usize) error{InvalidUtf8}![]const u8 {
    if (cols == 0 or text.len == 0) return text[0..0];
    var i: usize = 0;
    var col: usize = 0;

    // Skip `skip_cols` columns
    while (i < text.len and col < skip_cols) {
        const step = (try Ui.nextCpStrict(text, &i)) orelse return error.InvalidUtf8;
        col += step.w;
        i += step.n;
    }
    const start = i;

    // Take `cols` columns
    var used: usize = 0;
    while (i < text.len) {
        const step = (try Ui.nextCpStrict(text, &i)) orelse break;
        if (used + step.w > cols) break;
        i += step.n;
        used += step.w;
    }
    return text[start..i];
}

fn clipCols(text: []const u8, cols: usize) error{InvalidUtf8}![]const u8 {
    if (cols == 0 or text.len == 0) return text[0..0];

    var i: usize = 0;
    var used: usize = 0;
    while (i < text.len) {
        const step = (try Ui.nextCpStrict(text, &i)) orelse break;
        if (used + step.w > cols) break;
        i += step.n;
        used += step.w;
    }
    return text[0..i];
}

const TestBuf = struct {
    buf: []u8,
    len: usize = 0,

    fn init(buf: []u8) TestBuf {
        return .{ .buf = buf };
    }

    fn clear(self: *TestBuf) void {
        self.len = 0;
    }

    pub fn writeAll(self: *TestBuf, bytes: []const u8) !void {
        if (self.len + bytes.len > self.buf.len) return error.NoSpaceLeft;
        @memcpy(self.buf[self.len .. self.len + bytes.len], bytes);
        self.len += bytes.len;
    }

    fn view(self: *const TestBuf) []const u8 {
        return self.buf[0..self.len];
    }
};

fn findAsciiSeqX(frm: *const frame.Frame, y: usize, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    var x: usize = 0;
    while (x + needle.len <= frm.w) : (x += 1) {
        var ok = true;
        for (needle, 0..) |ch, j| {
            const c = frm.cell(x + j, y) catch return null;
            if (c.cp != @as(u21, ch)) {
                ok = false;
                break;
            }
        }
        if (ok) return x;
    }
    return null;
}

fn findAsciiSeqInFrame(frm: *const frame.Frame, needle: []const u8) ?struct { x: usize, y: usize } {
    var y: usize = 0;
    while (y < frm.h) : (y += 1) {
        if (findAsciiSeqX(frm, y, needle)) |x| return .{ .x = x, .y = y };
    }
    return null;
}

test "harness renders full-width transcript with footer" {
    var ui = try Ui.init(std.testing.allocator, 40, 8, "gpt-x", "prov-a");
    defer ui.deinit();

    try ui.onProvider(.{ .text = "hello" });

    var raw: [4096]u8 = undefined;
    var out = TestBuf.init(raw[0..]);
    try ui.draw(&out);

    try std.testing.expect(out.view().len != 0);
    try std.testing.expect(std.mem.indexOf(u8, out.view(), "\x1b[2J") != null);
}

test "harness editor interaction returns submit and clears line" {
    var ui = try Ui.init(std.testing.allocator, 20, 4, "gpt", "prov-a");
    defer ui.deinit();

    try std.testing.expect((try ui.onKey(.{ .char = 'h' })) == .none);
    try std.testing.expect((try ui.onKey(.{ .char = 'i' })) == .none);
    try std.testing.expectEqualStrings("hi", ui.editorText());

    try std.testing.expect((try ui.onKey(.{ .enter = {} })) == .submit);
    try std.testing.expectEqualStrings("", ui.editorText());
    try std.testing.expect(ui.tr.count() >= 1);
}

test "harness editor writes wide characters with wide-pad cell" {
    var ui = try Ui.init(std.testing.allocator, 10, 6, "m", "p");
    defer ui.deinit();

    try ui.ed.setText("中A");

    var raw: [4096]u8 = undefined;
    var out = TestBuf.init(raw[0..]);
    try ui.draw(&out);

    // h=6 => editor row is 2 (tx_h=1, border omitted, editor starts at y=2)
    const c1 = try ui.frm.cell(1, 2);
    const c2 = try ui.frm.cell(2, 2);
    const c3 = try ui.frm.cell(3, 2);
    try std.testing.expectEqual(@as(u21, 0x4E2D), c1.cp);
    try std.testing.expectEqual(@as(u21, frame.Frame.wide_pad), c2.cp);
    try std.testing.expectEqual(@as(u21, 'A'), c3.cp);
}

test "harness renders tiny terminal without bounds errors" {
    var ui = try Ui.init(std.testing.allocator, 8, 2, "m", "prov-a");
    defer ui.deinit();

    var raw: [512]u8 = undefined;
    var out = TestBuf.init(raw[0..]);
    try ui.draw(&out);
    out.clear();
    try ui.draw(&out);
}

test "harness resize reallocates frame and renderer" {
    var ui = try Ui.init(std.testing.allocator, 40, 8, "m", "p");
    defer ui.deinit();

    var raw: [4096]u8 = undefined;
    var out = TestBuf.init(raw[0..]);
    try ui.draw(&out);

    try ui.resize(20, 4);

    out.clear();
    try ui.draw(&out);
    try std.testing.expect(out.view().len != 0);
}

test "harness border shows compaction indicator" {
    var ui = try Ui.init(std.testing.allocator, 40, 8, "m", "p");
    defer ui.deinit();
    ui.pn.noteCompaction();

    var raw: [4096]u8 = undefined;
    var out = TestBuf.init(raw[0..]);
    try ui.draw(&out);

    const pos = findAsciiSeqInFrame(&ui.frm, "compaction");
    try std.testing.expect(pos != null);
    const cc = try ui.frm.cell(pos.?.x, pos.?.y);
    try std.testing.expect(frame.Color.eql(cc.style.fg, theme.get().accent));
}

test "harness onMouse scrolls transcript" {
    var ui = try Ui.init(std.testing.allocator, 20, 4, "m", "p");
    defer ui.deinit();

    try ui.onProvider(.{ .text = "line1" });
    try ui.tr.userText("line2");
    try ui.tr.userText("line3");
    try ui.tr.userText("line4");
    try ui.tr.userText("line5");

    try std.testing.expectEqual(@as(usize, 0), ui.tr.scroll_off);

    ui.onMouse(.scroll_up);
    try std.testing.expectEqual(@as(usize, 3), ui.tr.scroll_off);

    ui.onMouse(.scroll_down);
    try std.testing.expectEqual(@as(usize, 0), ui.tr.scroll_off);

    // Extra scroll down doesn't underflow
    ui.onMouse(.scroll_down);
    try std.testing.expectEqual(@as(usize, 0), ui.tr.scroll_off);
}

test "harness submit resets scroll" {
    var ui = try Ui.init(std.testing.allocator, 20, 4, "m", "p");
    defer ui.deinit();

    ui.tr.scrollUp(10);
    _ = try ui.onKey(.{ .char = 'x' });
    _ = try ui.onKey(.{ .enter = {} });
    try std.testing.expectEqual(@as(usize, 0), ui.tr.scroll_off);
}

test "harness resize to same size is noop" {
    var ui = try Ui.init(std.testing.allocator, 10, 5, "m", "p");
    defer ui.deinit();
    try ui.resize(10, 5);

    var raw: [1024]u8 = undefined;
    var out = TestBuf.init(raw[0..]);
    try ui.draw(&out);
    try std.testing.expect(out.view().len != 0);
}

test "wrapInfo single line" {
    const wi = wrapInfo("hello", 5, 20);
    try std.testing.expectEqual(@as(usize, 1), wi.rows);
    try std.testing.expectEqual(@as(usize, 0), wi.cur_row);
    try std.testing.expectEqual(@as(usize, 5), wi.cur_col);
}

test "wrapInfo wraps at width" {
    // "abcde" with width 3 → wraps: "abc" + "de"
    const wi = wrapInfo("abcde", 4, 3);
    try std.testing.expectEqual(@as(usize, 2), wi.rows);
    try std.testing.expectEqual(@as(usize, 1), wi.cur_row); // 'd' on second row
    try std.testing.expectEqual(@as(usize, 1), wi.cur_col);
}

test "wrapInfo with newline" {
    const wi = wrapInfo("ab\ncd", 4, 10);
    try std.testing.expectEqual(@as(usize, 2), wi.rows);
    try std.testing.expectEqual(@as(usize, 1), wi.cur_row);
    try std.testing.expectEqual(@as(usize, 1), wi.cur_col);
}

test "wrapRowCol maps target position" {
    // "abcde" width 3 → row0: "abc", row1: "de"
    const pos = wrapRowCol("abcde", 1, 0, 3);
    try std.testing.expectEqual(@as(usize, 3), pos); // byte 3 = 'd'
}

test "wrapUp and wrapDown navigate wrapped lines" {
    var ui = try Ui.init(std.testing.allocator, 6, 10, "m", "p");
    defer ui.deinit();

    // "abcdef" with width 5 (pad=1) → "abcde" + "f" → 2 rows
    try ui.ed.setText("abcdef");
    ui.ed.cur = 6; // end

    // wrapUp should move to first row
    try std.testing.expect(ui.wrapUp());
    try std.testing.expect(ui.ed.cur < 6);

    // wrapDown should move back
    try std.testing.expect(ui.wrapDown());

    // wrapDown at last row returns false (history)
    try std.testing.expect(!ui.wrapDown());
}

test "updatePreview shows file dropdown on @" {
    var ui = try Ui.init(std.testing.allocator, 40, 10, "m", "p");
    defer ui.deinit();

    // Type "@src/" — should trigger file completion
    try ui.ed.setText("@src/");
    ui.updatePreview();
    try std.testing.expect(ui.cp != null);
    try std.testing.expect(ui.path_items != null);
    try std.testing.expect(ui.path_items.?.len > 0);
}

test "updatePreview clears on no @" {
    var ui = try Ui.init(std.testing.allocator, 40, 10, "m", "p");
    defer ui.deinit();

    try ui.ed.setText("hello");
    ui.updatePreview();
    try std.testing.expect(ui.cp == null);
    try std.testing.expect(ui.path_items == null);
}

test "updatePreview slash overrides file mode" {
    var ui = try Ui.init(std.testing.allocator, 40, 10, "m", "p");
    defer ui.deinit();

    try ui.ed.setText("/help");
    ui.updatePreview();
    try std.testing.expect(ui.cp != null);
    try std.testing.expect(ui.path_items == null); // not file mode
}

test "updatePreview narrows cached path completion prefix" {
    var ui = try Ui.init(std.testing.allocator, 40, 10, "m", "p");
    defer ui.deinit();

    try ui.ed.setText("@src/");
    ui.updatePreview();
    try std.testing.expect(ui.path_items != null);
    const before_len = ui.path_items.?.len;
    try std.testing.expect(ui.path_prefix != null);
    try std.testing.expectEqualStrings("src/", ui.path_prefix.?);

    try ui.ed.setText("@src/m");
    ui.updatePreview();
    try std.testing.expect(ui.path_items != null);
    try std.testing.expect(ui.path_items.?.len <= before_len);
    try std.testing.expect(ui.path_prefix != null);
    try std.testing.expectEqualStrings("src/m", ui.path_prefix.?);
}

test "lastWordStart finds word boundary" {
    try std.testing.expectEqual(@as(usize, 6), lastWordStart("hello @src/", 11));
    try std.testing.expectEqual(@as(usize, 0), lastWordStart("@src/", 5));
    try std.testing.expectEqual(@as(usize, 4), lastWordStart("foo @", 5));
}
