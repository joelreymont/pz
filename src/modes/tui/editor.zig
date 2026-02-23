const std = @import("std");

pub const Key = union(enum) {
    char: u21,
    up: void,
    down: void,
    left: void,
    right: void,
    home: void,
    end: void,
    backspace: void,
    delete: void,
    enter: void,
    ctrl_a: void,
    ctrl_c: void,
    ctrl_d: void,
    ctrl_e: void,
    ctrl_g: void,
    ctrl_k: void,
    ctrl_l: void,
    ctrl_o: void,
    ctrl_p: void,
    ctrl_t: void,
    ctrl_u: void,
    ctrl_v: void,
    ctrl_w: void,
    ctrl_z: void,
    shift_ctrl_p: void,
    esc: void,
    shift_tab: void,
    alt_enter: void,
    alt_up: void,
    alt_b: void,
    alt_f: void,
    ctrl_left: void,
    ctrl_right: void,
    alt_d: void,
    alt_y: void,
    ctrl_y: void,
    ctrl_close_bracket: void,
    ctrl_shift_z: void,
    tab: void,
    page_up: void,
    page_down: void,
};

pub const Action = enum {
    none,
    submit,
    cancel,
    interrupt,
    cycle_thinking,
    cycle_model,
    toggle_tools,
    toggle_thinking,
    kill_to_eol,
    @"suspend",
    select_model,
    ext_editor,
    queue_followup,
    edit_queued,
    paste_image,
    reverse_cycle_model,
    tab_complete,
    scroll_up,
    scroll_down,
};

pub const EditKind = enum { none, insert, delete, kill, other };

pub const UndoEntry = struct {
    buf: []u8,
    cur: usize,
    fn deinit(self: UndoEntry, alloc: std.mem.Allocator) void {
        alloc.free(self.buf);
    }
};

/// Start of the word containing/before `pos` in `text` (whitespace-delimited).
pub fn wordStartIn(text: []const u8, pos: usize) usize {
    var i = pos;
    while (i > 0 and text[i - 1] != ' ' and text[i - 1] != '\n' and text[i - 1] != '\t') i -= 1;
    return i;
}

pub const Editor = struct {
    alloc: std.mem.Allocator,
    buf: std.ArrayListUnmanaged(u8) = .empty,
    cur: usize = 0,
    hist: std.ArrayListUnmanaged([]u8) = .empty,
    hist_idx: ?usize = null, // null = editing new input
    stash: std.ArrayListUnmanaged(u8) = .empty, // saves current input when browsing history
    // Kill ring (emacs-style)
    kill_ring: [8]?[]u8 = .{null} ** 8,
    kr_head: u8 = 0,
    kr_len: u8 = 0,
    kr_yank_idx: u8 = 0,
    last_was_kill: bool = false,
    yank_mark: ?struct { pos: usize, len: usize } = null,
    jump_mode: bool = false,
    // Undo/redo
    undo_stack: std.ArrayListUnmanaged(UndoEntry) = .empty,
    redo_stack: std.ArrayListUnmanaged(UndoEntry) = .empty,
    last_edit: EditKind = .none,

    pub fn init(alloc: std.mem.Allocator) Editor {
        return .{
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *Editor) void {
        for (self.hist.items) |h| self.alloc.free(h);
        self.hist.deinit(self.alloc);
        self.stash.deinit(self.alloc);
        for (&self.kill_ring) |*e| {
            if (e.*) |s| self.alloc.free(s);
        }
        for (self.undo_stack.items) |e| e.deinit(self.alloc);
        self.undo_stack.deinit(self.alloc);
        for (self.redo_stack.items) |e| e.deinit(self.alloc);
        self.redo_stack.deinit(self.alloc);
        self.buf.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn text(self: *const Editor) []const u8 {
        return self.buf.items;
    }

    pub fn cursor(self: *const Editor) usize {
        return self.cur;
    }

    /// Start of the word containing/before `pos` (whitespace-delimited).
    pub fn wordStart(self: *const Editor, pos: usize) usize {
        return wordStartIn(self.text(), pos);
    }

    pub fn setText(self: *Editor, t: []const u8) !void {
        self.buf.items.len = 0;
        try self.buf.appendSlice(self.alloc, t);
        self.cur = self.buf.items.len;
        self.last_was_kill = false;
        self.yank_mark = null;
    }

    pub fn clear(self: *Editor) void {
        self.buf.items.len = 0;
        self.cur = 0;
        self.hist_idx = null;
        self.stash.items.len = 0;
        self.last_was_kill = false;
        self.yank_mark = null;
    }

    pub fn pushHistory(self: *Editor, t: []const u8) !void {
        if (t.len == 0) return;
        // Dedup: skip if same as last entry
        if (self.hist.items.len > 0) {
            const last = self.hist.items[self.hist.items.len - 1];
            if (std.mem.eql(u8, last, t)) return;
        }
        const dup = try self.alloc.dupe(u8, t);
        try self.hist.append(self.alloc, dup);
    }

    pub fn insertSlice(self: *Editor, s: []const u8) !void {
        // Validate UTF-8 before inserting to prevent downstream panics
        _ = std.unicode.Utf8View.init(s) catch return error.InvalidUtf8;
        try self.buf.insertSlice(self.alloc, self.cur, s);
        self.cur += s.len;
    }

    pub fn apply(self: *Editor, key: Key) !Action {
        // Jump-to-char mode: next printable char jumps cursor
        if (self.jump_mode) {
            self.jump_mode = false;
            switch (key) {
                .char => |cp| self.jumpToChar(cp),
                else => {},
            }
            return .none;
        }
        // Track kill accumulation and yank-pop state
        switch (key) {
            .ctrl_k, .ctrl_u, .ctrl_w, .alt_d => {
                self.yank_mark = null;
            },
            .ctrl_y, .alt_y => {
                self.last_was_kill = false;
            },
            else => {
                self.last_was_kill = false;
                self.yank_mark = null;
            },
        }
        return switch (key) {
            .char => |cp| blk: {
                try self.snapshot(.insert);
                try insertCp(self, cp);
                break :blk .none;
            },
            .up => blk: {
                try self.histPrev();
                break :blk .none;
            },
            .down => blk: {
                try self.histNext();
                break :blk .none;
            },
            .left => blk: {
                self.moveLeft();
                break :blk .none;
            },
            .right => blk: {
                self.moveRight();
                break :blk .none;
            },
            .home => blk: {
                self.cur = 0;
                break :blk .none;
            },
            .end => blk: {
                self.cur = self.buf.items.len;
                break :blk .none;
            },
            .backspace => blk: {
                try self.snapshot(.delete);
                self.backspace();
                break :blk .none;
            },
            .delete => blk: {
                try self.snapshot(.delete);
                self.delete();
                break :blk .none;
            },
            .enter => .submit,
            .ctrl_a => blk: {
                self.cur = 0;
                break :blk .none;
            },
            .ctrl_c => if (self.buf.items.len > 0) blk: {
                self.clear();
                break :blk .interrupt;
            } else .cancel,
            .ctrl_d => if (self.buf.items.len == 0) Action.cancel else .none,
            .ctrl_e => blk: {
                self.cur = self.buf.items.len;
                break :blk .none;
            },
            .ctrl_g => .ext_editor,
            .ctrl_k => blk: {
                try self.snapshot(.kill);
                try self.killToEol();
                break :blk .kill_to_eol;
            },
            .ctrl_l => .select_model,
            .ctrl_o => .toggle_tools,
            .ctrl_p => .cycle_model,
            .ctrl_t => .toggle_thinking,
            .ctrl_u => blk: {
                try self.snapshot(.kill);
                try self.killLine();
                break :blk .none;
            },
            .ctrl_v => .paste_image,
            .ctrl_w => blk: {
                try self.snapshot(.kill);
                try self.killWordBack();
                break :blk .none;
            },
            .ctrl_z => blk: {
                try self.undoOp();
                break :blk .none;
            },
            .ctrl_shift_z => blk: {
                try self.redoOp();
                break :blk .none;
            },
            .shift_ctrl_p => .reverse_cycle_model,
            .alt_enter => .queue_followup,
            .alt_up => .edit_queued,
            .alt_b, .ctrl_left => blk: {
                self.wordLeft();
                break :blk .none;
            },
            .alt_d => blk: {
                try self.snapshot(.kill);
                try self.killWordFwd();
                break :blk .none;
            },
            .alt_f, .ctrl_right => blk: {
                self.wordRight();
                break :blk .none;
            },
            .ctrl_y => blk: {
                try self.yank();
                break :blk .none;
            },
            .alt_y => blk: {
                try self.yankPop();
                break :blk .none;
            },
            .ctrl_close_bracket => blk: {
                self.jump_mode = true;
                break :blk .none;
            },
            .esc => blk: {
                if (self.buf.items.len > 0) self.clear();
                break :blk .interrupt;
            },
            .tab => .tab_complete,
            .page_up => .scroll_up,
            .page_down => .scroll_down,
            .shift_tab => .cycle_thinking,
        };
    }

    fn insertCp(self: *Editor, cp: u21) !void {
        var enc: [4]u8 = undefined;
        const n = try std.unicode.utf8Encode(cp, &enc);
        try self.buf.insertSlice(self.alloc, self.cur, enc[0..n]);
        self.cur += n;
    }

    fn moveLeft(self: *Editor) void {
        if (self.cur == 0) return;
        var i = self.cur - 1;
        while (i > 0 and (self.buf.items[i] & 0b1100_0000) == 0b1000_0000) : (i -= 1) {}
        self.cur = i;
    }

    fn moveRight(self: *Editor) void {
        if (self.cur >= self.buf.items.len) return;
        const n = utf8SeqLen(self.buf.items[self.cur]);
        self.cur = @min(self.buf.items.len, self.cur + n);
    }

    fn backspace(self: *Editor) void {
        if (self.cur == 0) return;
        const end = self.cur;
        self.moveLeft();
        const start = self.cur;
        deleteRange(self, start, end);
    }

    fn delete(self: *Editor) void {
        if (self.cur >= self.buf.items.len) return;
        const n = utf8SeqLen(self.buf.items[self.cur]);
        const end = @min(self.buf.items.len, self.cur + n);
        deleteRange(self, self.cur, end);
    }

    fn killToEol(self: *Editor) !void {
        if (self.cur < self.buf.items.len) {
            try self.krPush(self.buf.items[self.cur..], false);
        }
        self.buf.items.len = self.cur;
    }

    fn killLine(self: *Editor) !void {
        if (self.buf.items.len > 0) {
            try self.krPush(self.buf.items, true);
        }
        self.buf.items.len = 0;
        self.cur = 0;
    }

    fn killWordBack(self: *Editor) !void {
        if (self.cur == 0) return;
        const end = self.cur;
        // Skip whitespace backward
        while (self.cur > 0 and isSpace(self.buf.items[self.cur - 1])) self.cur -= 1;
        // Skip word chars backward
        while (self.cur > 0 and !isSpace(self.buf.items[self.cur - 1])) self.cur -= 1;
        try self.krPush(self.buf.items[self.cur..end], true);
        deleteRange(self, self.cur, end);
    }

    fn snapshot(self: *Editor, kind: EditKind) !void {
        if (kind != self.last_edit or self.last_edit == .other) {
            const snap = UndoEntry{
                .buf = try self.alloc.dupe(u8, self.buf.items),
                .cur = self.cur,
            };
            try self.undo_stack.append(self.alloc, snap);
            // Clear redo stack on new edit
            for (self.redo_stack.items) |e| e.deinit(self.alloc);
            self.redo_stack.items.len = 0;
            // Limit stack size
            if (self.undo_stack.items.len > 100) {
                self.undo_stack.items[0].deinit(self.alloc);
                _ = self.undo_stack.orderedRemove(0);
            }
        }
        self.last_edit = kind;
    }

    fn undoOp(self: *Editor) !void {
        if (self.undo_stack.items.len == 0) return;
        const redo_snap = UndoEntry{
            .buf = try self.alloc.dupe(u8, self.buf.items),
            .cur = self.cur,
        };
        try self.redo_stack.append(self.alloc, redo_snap);
        const snap = self.undo_stack.pop().?;
        self.buf.items.len = 0;
        try self.buf.appendSlice(self.alloc, snap.buf);
        self.cur = snap.cur;
        snap.deinit(self.alloc);
        self.last_edit = .none;
    }

    fn redoOp(self: *Editor) !void {
        if (self.redo_stack.items.len == 0) return;
        const undo_snap = UndoEntry{
            .buf = try self.alloc.dupe(u8, self.buf.items),
            .cur = self.cur,
        };
        try self.undo_stack.append(self.alloc, undo_snap);
        const snap = self.redo_stack.pop().?;
        self.buf.items.len = 0;
        try self.buf.appendSlice(self.alloc, snap.buf);
        self.cur = snap.cur;
        snap.deinit(self.alloc);
        self.last_edit = .none;
    }

    fn jumpToChar(self: *Editor, target: u21) void {
        const items = self.buf.items;
        var i = self.cur;
        // Skip current codepoint
        if (i < items.len) {
            i += utf8SeqLen(items[i]);
        }
        // Search forward for target
        while (i < items.len) {
            const n = utf8SeqLen(items[i]);
            if (i + n <= items.len) {
                const cp = std.unicode.utf8Decode(items[i .. i + n]) catch {
                    i += n;
                    continue;
                };
                if (cp == target) {
                    self.cur = i;
                    return;
                }
            }
            i += n;
        }
    }

    fn killWordFwd(self: *Editor) !void {
        if (self.cur >= self.buf.items.len) return;
        const start = self.cur;
        var end = start;
        while (end < self.buf.items.len and isSpace(self.buf.items[end])) end += 1;
        while (end < self.buf.items.len and !isSpace(self.buf.items[end])) end += 1;
        if (end == start) return;
        try self.krPush(self.buf.items[start..end], false);
        deleteRange(self, start, end);
    }

    fn krPush(self: *Editor, killed: []const u8, prepend: bool) !void {
        if (killed.len == 0) return;
        if (self.last_was_kill and self.kr_len > 0) {
            const idx = (self.kr_head + 8 - 1) % 8;
            if (self.kill_ring[idx]) |prev| {
                const new = try self.alloc.alloc(u8, prev.len + killed.len);
                if (prepend) {
                    @memcpy(new[0..killed.len], killed);
                    @memcpy(new[killed.len..], prev);
                } else {
                    @memcpy(new[0..prev.len], prev);
                    @memcpy(new[prev.len..], killed);
                }
                self.alloc.free(prev);
                self.kill_ring[idx] = new;
            } else {
                self.kill_ring[idx] = try self.alloc.dupe(u8, killed);
            }
        } else {
            if (self.kill_ring[self.kr_head]) |old| self.alloc.free(old);
            self.kill_ring[self.kr_head] = try self.alloc.dupe(u8, killed);
            self.kr_head = (self.kr_head + 1) % 8;
            if (self.kr_len < 8) self.kr_len += 1;
        }
        self.last_was_kill = true;
    }

    fn yank(self: *Editor) !void {
        if (self.kr_len == 0) return;
        self.kr_yank_idx = 0;
        const idx = (self.kr_head + 8 - 1) % 8;
        const entry = self.kill_ring[idx] orelse return;
        const pos = self.cur;
        try self.buf.insertSlice(self.alloc, self.cur, entry);
        self.cur += entry.len;
        self.yank_mark = .{ .pos = pos, .len = entry.len };
    }

    fn yankPop(self: *Editor) !void {
        const mark = self.yank_mark orelse return;
        if (self.kr_len <= 1) return;
        deleteRange(self, mark.pos, mark.pos + mark.len);
        self.cur = mark.pos;
        self.kr_yank_idx = (self.kr_yank_idx + 1) % self.kr_len;
        const idx = (self.kr_head + 8 - 1 - @as(usize, self.kr_yank_idx)) % 8;
        const entry = self.kill_ring[idx] orelse return;
        const pos = self.cur;
        try self.buf.insertSlice(self.alloc, self.cur, entry);
        self.cur += entry.len;
        self.yank_mark = .{ .pos = pos, .len = entry.len };
    }

    fn wordLeft(self: *Editor) void {
        if (self.cur == 0) return;
        // Skip whitespace backward
        while (self.cur > 0 and isSpace(self.buf.items[self.cur - 1])) self.cur -= 1;
        // Skip word chars backward
        while (self.cur > 0 and !isSpace(self.buf.items[self.cur - 1])) self.cur -= 1;
    }

    fn wordRight(self: *Editor) void {
        const items = self.buf.items;
        // Skip word chars forward
        while (self.cur < items.len and !isSpace(items[self.cur])) self.cur += 1;
        // Skip whitespace forward
        while (self.cur < items.len and isSpace(items[self.cur])) self.cur += 1;
    }

    fn isSpace(b: u8) bool {
        return b == ' ' or b == '\t' or b == '\n';
    }

    fn deleteRange(self: *Editor, start: usize, end: usize) void {
        const tail = self.buf.items[end..];
        std.mem.copyForwards(u8, self.buf.items[start .. start + tail.len], tail);
        self.buf.items.len -= end - start;
    }

    fn histPrev(self: *Editor) !void {
        if (self.hist.items.len == 0) return;
        if (self.hist_idx == null) {
            // Stash current input
            self.stash.items.len = 0;
            try self.stash.appendSlice(self.alloc, self.buf.items);
            self.hist_idx = self.hist.items.len - 1;
        } else if (self.hist_idx.? > 0) {
            self.hist_idx.? -= 1;
        } else {
            return; // at oldest
        }
        try self.loadHistEntry();
    }

    fn histNext(self: *Editor) !void {
        if (self.hist_idx == null) return;
        if (self.hist_idx.? + 1 < self.hist.items.len) {
            self.hist_idx.? += 1;
            try self.loadHistEntry();
        } else {
            // Restore stashed input
            self.hist_idx = null;
            self.buf.items.len = 0;
            try self.buf.appendSlice(self.alloc, self.stash.items);
            self.cur = self.buf.items.len;
            self.stash.items.len = 0;
        }
    }

    fn loadHistEntry(self: *Editor) !void {
        const entry = self.hist.items[self.hist_idx.?];
        self.buf.items.len = 0;
        try self.buf.appendSlice(self.alloc, entry);
        self.cur = self.buf.items.len;
    }

    fn utf8SeqLen(lead: u8) usize {
        return std.unicode.utf8ByteSequenceLength(lead) catch 1;
    }
};

test "editor supports utf8 insert cursor movement and deletion" {
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();

    _ = try ed.apply(.{ .char = 'A' });
    _ = try ed.apply(.{ .char = 0x03b2 });
    _ = try ed.apply(.{ .char = 'Z' });
    try std.testing.expectEqualStrings("AβZ", ed.text());

    _ = try ed.apply(.{ .left = {} });
    _ = try ed.apply(.{ .backspace = {} });
    try std.testing.expectEqualStrings("AZ", ed.text());

    _ = try ed.apply(.{ .home = {} });
    _ = try ed.apply(.{ .delete = {} });
    try std.testing.expectEqualStrings("Z", ed.text());
}

test "editor maps enter and ctrl-c to actions" {
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();

    try std.testing.expect((try ed.apply(.{ .enter = {} })) == .submit);
    // ctrl-c on empty → cancel (quit)
    try std.testing.expect((try ed.apply(.{ .ctrl_c = {} })) == .cancel);
}

test "esc clears editor text" {
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();

    _ = try ed.apply(.{ .char = 'h' });
    _ = try ed.apply(.{ .char = 'i' });
    try std.testing.expectEqualStrings("hi", ed.text());

    // ESC with text → interrupt + clear
    try std.testing.expect((try ed.apply(.{ .esc = {} })) == .interrupt);
    try std.testing.expectEqualStrings("", ed.text());

    // ESC on empty → interrupt (no-op clear)
    try std.testing.expect((try ed.apply(.{ .esc = {} })) == .interrupt);
}

test "ctrl-c clears text first then cancels" {
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();

    _ = try ed.apply(.{ .char = 'x' });
    // ctrl-c with text → interrupt + clear
    try std.testing.expect((try ed.apply(.{ .ctrl_c = {} })) == .interrupt);
    try std.testing.expectEqualStrings("", ed.text());

    // ctrl-c on empty → cancel (quit)
    try std.testing.expect((try ed.apply(.{ .ctrl_c = {} })) == .cancel);
}

test "ctrl-d exits on empty, no-op on text" {
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();

    // empty → cancel (exit)
    try std.testing.expect((try ed.apply(.{ .ctrl_d = {} })) == .cancel);

    _ = try ed.apply(.{ .char = 'a' });
    // with text → none (no-op)
    try std.testing.expect((try ed.apply(.{ .ctrl_d = {} })) == .none);
}

test "shift-tab cycles thinking" {
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();

    try std.testing.expect((try ed.apply(.{ .shift_tab = {} })) == .cycle_thinking);
}

test "ctrl-p cycles model" {
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();

    try std.testing.expect((try ed.apply(.{ .ctrl_p = {} })) == .cycle_model);
}

test "ctrl-k kills to end of line" {
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();

    _ = try ed.apply(.{ .char = 'a' });
    _ = try ed.apply(.{ .char = 'b' });
    _ = try ed.apply(.{ .char = 'c' });
    _ = try ed.apply(.{ .left = {} });
    // cursor after 'b', kill 'c'
    try std.testing.expect((try ed.apply(.{ .ctrl_k = {} })) == .kill_to_eol);
    try std.testing.expectEqualStrings("ab", ed.text());
}

test "ctrl-k at end is no-op" {
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();

    _ = try ed.apply(.{ .char = 'x' });
    try std.testing.expect((try ed.apply(.{ .ctrl_k = {} })) == .kill_to_eol);
    try std.testing.expectEqualStrings("x", ed.text());
}

test "setText replaces editor content" {
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();

    _ = try ed.apply(.{ .char = 'a' });
    try ed.setText("hello world");
    try std.testing.expectEqualStrings("hello world", ed.text());
    try std.testing.expectEqual(ed.buf.items.len, ed.cur);
}

test "insertSlice inserts at cursor" {
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();

    _ = try ed.apply(.{ .char = 'a' });
    _ = try ed.apply(.{ .char = 'b' });
    _ = try ed.apply(.{ .left = {} });
    try ed.insertSlice("XY");
    try std.testing.expectEqualStrings("aXYb", ed.text());
    try std.testing.expectEqual(@as(usize, 3), ed.cur);
}

test "new keys produce correct actions" {
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();

    try std.testing.expect((try ed.apply(.{ .ctrl_z = {} })) == .none); // undo (no-op on empty)
    try std.testing.expect((try ed.apply(.{ .ctrl_l = {} })) == .select_model);
    try std.testing.expect((try ed.apply(.{ .ctrl_g = {} })) == .ext_editor);
    try std.testing.expect((try ed.apply(.{ .ctrl_v = {} })) == .paste_image);
    try std.testing.expect((try ed.apply(.{ .alt_enter = {} })) == .queue_followup);
    try std.testing.expect((try ed.apply(.{ .alt_up = {} })) == .edit_queued);
    try std.testing.expect((try ed.apply(.{ .shift_ctrl_p = {} })) == .reverse_cycle_model);
}

test "input history navigates with up/down" {
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();

    // Type and submit "hello"
    _ = try ed.apply(.{ .char = 'h' });
    _ = try ed.apply(.{ .char = 'i' });
    try ed.pushHistory(ed.text());
    ed.clear();

    // Type and submit "world"
    _ = try ed.apply(.{ .char = 'g' });
    _ = try ed.apply(.{ .char = 'o' });
    try ed.pushHistory(ed.text());
    ed.clear();

    // Up → "go" (most recent)
    _ = try ed.apply(.{ .up = {} });
    try std.testing.expectEqualStrings("go", ed.text());

    // Up → "hi" (older)
    _ = try ed.apply(.{ .up = {} });
    try std.testing.expectEqualStrings("hi", ed.text());

    // Up at oldest → stays "hi"
    _ = try ed.apply(.{ .up = {} });
    try std.testing.expectEqualStrings("hi", ed.text());

    // Down → "go"
    _ = try ed.apply(.{ .down = {} });
    try std.testing.expectEqualStrings("go", ed.text());

    // Down → back to empty (stashed input)
    _ = try ed.apply(.{ .down = {} });
    try std.testing.expectEqualStrings("", ed.text());
}

test "history stashes current input" {
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();

    try ed.pushHistory("prev");

    // Type partial input
    _ = try ed.apply(.{ .char = 'x' });
    _ = try ed.apply(.{ .char = 'y' });

    // Up → stashes "xy", shows "prev"
    _ = try ed.apply(.{ .up = {} });
    try std.testing.expectEqualStrings("prev", ed.text());

    // Down → restores "xy"
    _ = try ed.apply(.{ .down = {} });
    try std.testing.expectEqualStrings("xy", ed.text());
}

test "history deduplicates consecutive entries" {
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();

    try ed.pushHistory("same");
    try ed.pushHistory("same");
    try std.testing.expectEqual(@as(usize, 1), ed.hist.items.len);

    try ed.pushHistory("diff");
    try std.testing.expectEqual(@as(usize, 2), ed.hist.items.len);
}

test "ctrl-a moves to start, ctrl-e to end" {
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();

    _ = try ed.apply(.{ .char = 'a' });
    _ = try ed.apply(.{ .char = 'b' });
    _ = try ed.apply(.{ .char = 'c' });
    try std.testing.expectEqual(@as(usize, 3), ed.cur);

    _ = try ed.apply(.{ .ctrl_a = {} });
    try std.testing.expectEqual(@as(usize, 0), ed.cur);

    _ = try ed.apply(.{ .ctrl_e = {} });
    try std.testing.expectEqual(@as(usize, 3), ed.cur);
}

test "ctrl-u kills whole line" {
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();

    _ = try ed.apply(.{ .char = 'h' });
    _ = try ed.apply(.{ .char = 'i' });
    _ = try ed.apply(.{ .ctrl_u = {} });
    try std.testing.expectEqualStrings("", ed.text());
    try std.testing.expectEqual(@as(usize, 0), ed.cur);
}

test "ctrl-w kills word backward" {
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();

    try ed.setText("hello world foo");
    _ = try ed.apply(.{ .ctrl_w = {} });
    try std.testing.expectEqualStrings("hello world ", ed.text());

    _ = try ed.apply(.{ .ctrl_w = {} });
    try std.testing.expectEqualStrings("hello ", ed.text());

    _ = try ed.apply(.{ .ctrl_w = {} });
    try std.testing.expectEqualStrings("", ed.text());
}

test "alt-b and alt-f move by word" {
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();

    try ed.setText("hello world foo");
    // cursor at end (15)

    _ = try ed.apply(.{ .alt_b = {} });
    try std.testing.expectEqual(@as(usize, 12), ed.cur); // before "foo"

    _ = try ed.apply(.{ .alt_b = {} });
    try std.testing.expectEqual(@as(usize, 6), ed.cur); // before "world"

    _ = try ed.apply(.{ .alt_f = {} });
    try std.testing.expectEqual(@as(usize, 12), ed.cur); // after "world "

    _ = try ed.apply(.{ .alt_f = {} });
    try std.testing.expectEqual(@as(usize, 15), ed.cur); // end
}

test "word movement with utf-8 multibyte characters" {
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();

    // "hi 日本語 bye" — 日=\xe6\x97\xa5 本=\xe6\x9c\xac 語=\xe8\xaa\x9e
    try ed.setText("hi \xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e bye");

    // cursor at end (16)
    _ = try ed.apply(.{ .alt_b = {} }); // before "bye"
    try std.testing.expectEqual(@as(usize, 13), ed.cur);

    _ = try ed.apply(.{ .alt_b = {} }); // before "日本語"
    try std.testing.expectEqual(@as(usize, 3), ed.cur);
    // cur=3 is start of 日 (0xe6) — valid UTF-8 lead byte
    try std.testing.expect(ed.buf.items[ed.cur] == 0xe6);

    _ = try ed.apply(.{ .alt_b = {} }); // before "hi"
    try std.testing.expectEqual(@as(usize, 0), ed.cur);

    _ = try ed.apply(.{ .alt_f = {} }); // after "hi "
    try std.testing.expectEqual(@as(usize, 3), ed.cur);

    _ = try ed.apply(.{ .alt_f = {} }); // after "日本語 "
    try std.testing.expectEqual(@as(usize, 13), ed.cur);
}

test "alt-d deletes word forward" {
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();

    try ed.setText("hello world foo");
    ed.cur = 0;
    _ = try ed.apply(.{ .alt_d = {} });
    // Deletes "hello" (skips word chars), leaves " world foo"
    try std.testing.expectEqualStrings(" world foo", ed.text());
    try std.testing.expectEqual(@as(usize, 0), ed.cur);

    _ = try ed.apply(.{ .alt_d = {} });
    // Deletes " world" (skips space then word), leaves " foo"
    try std.testing.expectEqualStrings(" foo", ed.text());

    _ = try ed.apply(.{ .alt_d = {} });
    try std.testing.expectEqualStrings("", ed.text());
}

test "alt-d at end is no-op" {
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();

    try ed.setText("hi");
    // cursor at end
    _ = try ed.apply(.{ .alt_d = {} });
    try std.testing.expectEqualStrings("hi", ed.text());
}

test "kill ring: ctrl-k saves killed text for yank" {
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();

    try ed.setText("hello world");
    ed.cur = 5; // after "hello"
    _ = try ed.apply(.{ .ctrl_k = {} });
    try std.testing.expectEqualStrings("hello", ed.text());

    // Yank should restore " world"
    ed.cur = 5;
    _ = try ed.apply(.{ .ctrl_y = {} });
    try std.testing.expectEqualStrings("hello world", ed.text());
}

test "kill ring: ctrl-w saves for yank" {
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();

    try ed.setText("hello world");
    _ = try ed.apply(.{ .ctrl_w = {} });
    try std.testing.expectEqualStrings("hello ", ed.text());

    ed.cur = 0;
    _ = try ed.apply(.{ .ctrl_y = {} });
    try std.testing.expectEqualStrings("worldhello ", ed.text());
}

test "kill ring: consecutive kills accumulate" {
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();

    try ed.setText("aaa bbb ccc");
    // Kill "ccc" then "bbb " — consecutive backward kills accumulate
    _ = try ed.apply(.{ .ctrl_w = {} }); // kills "ccc"
    try std.testing.expectEqualStrings("aaa bbb ", ed.text());

    _ = try ed.apply(.{ .ctrl_w = {} }); // kills "bbb " (accumulates)
    try std.testing.expectEqualStrings("aaa ", ed.text());

    // Yank should give "bbb ccc" (prepend mode for backward kills)
    _ = try ed.apply(.{ .ctrl_y = {} });
    try std.testing.expectEqualStrings("aaa bbb ccc", ed.text());
}

test "kill ring: non-kill breaks accumulation" {
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();

    try ed.setText("aaa bbb");
    _ = try ed.apply(.{ .ctrl_w = {} }); // kills "bbb"
    _ = try ed.apply(.{ .char = 'X' }); // non-kill breaks chain
    _ = try ed.apply(.{ .ctrl_w = {} }); // kills "X" (new entry)

    // Yank should give "X" (most recent), not "Xbbb"
    ed.cur = 0;
    _ = try ed.apply(.{ .ctrl_y = {} });
    try std.testing.expectEqualStrings("Xaaa ", ed.text());
}

test "yank with empty kill ring is no-op" {
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();

    try ed.setText("hello");
    _ = try ed.apply(.{ .ctrl_y = {} });
    try std.testing.expectEqualStrings("hello", ed.text());
}

test "yank-pop cycles through kill ring" {
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();

    // Kill two separate items
    try ed.setText("aaa");
    _ = try ed.apply(.{ .ctrl_u = {} }); // kills "aaa"

    try ed.setText("bbb");
    _ = try ed.apply(.{ .ctrl_u = {} }); // kills "bbb"

    // Yank most recent ("bbb")
    _ = try ed.apply(.{ .ctrl_y = {} });
    try std.testing.expectEqualStrings("bbb", ed.text());

    // Yank-pop to older ("aaa")
    _ = try ed.apply(.{ .alt_y = {} });
    try std.testing.expectEqualStrings("aaa", ed.text());
}

test "yank-pop without prior yank is no-op" {
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();

    try ed.setText("hello");
    _ = try ed.apply(.{ .alt_y = {} });
    try std.testing.expectEqualStrings("hello", ed.text());
}

test "alt-d saves to kill ring" {
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();

    try ed.setText("hello world");
    ed.cur = 0;
    _ = try ed.apply(.{ .alt_d = {} }); // kills "hello"
    try std.testing.expectEqualStrings(" world", ed.text());

    ed.cur = ed.buf.items.len;
    _ = try ed.apply(.{ .ctrl_y = {} });
    try std.testing.expectEqualStrings(" worldhello", ed.text());
}

test "ctrl-u saves to kill ring" {
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();

    try ed.setText("hello");
    _ = try ed.apply(.{ .ctrl_u = {} });
    try std.testing.expectEqualStrings("", ed.text());

    _ = try ed.apply(.{ .ctrl_y = {} });
    try std.testing.expectEqualStrings("hello", ed.text());
}

test "ctrl-] jump-to-char forward" {
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();

    try ed.setText("hello world");
    ed.cur = 0;
    _ = try ed.apply(.{ .ctrl_close_bracket = {} }); // enter jump mode
    _ = try ed.apply(.{ .char = 'o' }); // jump to first 'o'
    try std.testing.expectEqual(@as(usize, 4), ed.cur); // 'o' in "hello"

    // Jump again to next 'o'
    _ = try ed.apply(.{ .ctrl_close_bracket = {} });
    _ = try ed.apply(.{ .char = 'o' });
    try std.testing.expectEqual(@as(usize, 7), ed.cur); // 'o' in "world"
}

test "ctrl-] no match stays in place" {
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();

    try ed.setText("hello");
    ed.cur = 0;
    _ = try ed.apply(.{ .ctrl_close_bracket = {} });
    _ = try ed.apply(.{ .char = 'z' }); // no 'z' in "hello"
    try std.testing.expectEqual(@as(usize, 0), ed.cur);
}

test "ctrl-] cancel with non-char key" {
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();

    try ed.setText("hello");
    ed.cur = 0;
    _ = try ed.apply(.{ .ctrl_close_bracket = {} });
    _ = try ed.apply(.{ .esc = {} }); // cancel jump mode
    try std.testing.expectEqual(@as(usize, 0), ed.cur);
    try std.testing.expectEqualStrings("hello", ed.text()); // esc doesn't clear in jump cancel
}

test "undo restores previous state" {
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();

    _ = try ed.apply(.{ .char = 'h' });
    _ = try ed.apply(.{ .char = 'i' });
    try std.testing.expectEqualStrings("hi", ed.text());

    // Kill triggers new undo group
    _ = try ed.apply(.{ .ctrl_k = {} }); // no-op at end, but creates snapshot
    // Type more chars (new group)
    _ = try ed.apply(.{ .char = '!' });
    try std.testing.expectEqualStrings("hi!", ed.text());

    // Undo the '!' insertion
    _ = try ed.apply(.{ .ctrl_z = {} });
    try std.testing.expectEqualStrings("hi", ed.text());
}

test "undo groups consecutive inserts" {
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();

    _ = try ed.apply(.{ .char = 'a' });
    _ = try ed.apply(.{ .char = 'b' });
    _ = try ed.apply(.{ .char = 'c' });
    try std.testing.expectEqualStrings("abc", ed.text());

    // All chars are .insert type → one group → one undo
    _ = try ed.apply(.{ .ctrl_z = {} });
    try std.testing.expectEqualStrings("", ed.text());
}

test "redo after undo" {
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();

    _ = try ed.apply(.{ .char = 'x' });
    _ = try ed.apply(.{ .char = 'y' });

    // Backspace creates new group (delete)
    _ = try ed.apply(.{ .backspace = {} });
    try std.testing.expectEqualStrings("x", ed.text());

    // Undo backspace
    _ = try ed.apply(.{ .ctrl_z = {} });
    try std.testing.expectEqualStrings("xy", ed.text());

    // Redo backspace
    _ = try ed.apply(.{ .ctrl_shift_z = {} });
    try std.testing.expectEqualStrings("x", ed.text());
}

test "undo kill restores killed text" {
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();

    try ed.setText("hello world");
    ed.cur = 5;
    _ = try ed.apply(.{ .ctrl_k = {} });
    try std.testing.expectEqualStrings("hello", ed.text());

    _ = try ed.apply(.{ .ctrl_z = {} });
    try std.testing.expectEqualStrings("hello world", ed.text());
    try std.testing.expectEqual(@as(usize, 5), ed.cur);
}

test "undo on empty stack is no-op" {
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();

    _ = try ed.apply(.{ .ctrl_z = {} });
    try std.testing.expectEqualStrings("", ed.text());
}

test "redo on empty stack is no-op" {
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();

    try ed.setText("hi");
    _ = try ed.apply(.{ .ctrl_shift_z = {} });
    try std.testing.expectEqualStrings("hi", ed.text());
}

test "new edit clears redo stack" {
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();

    _ = try ed.apply(.{ .char = 'a' });
    _ = try ed.apply(.{ .backspace = {} }); // new group
    try std.testing.expectEqualStrings("", ed.text());

    _ = try ed.apply(.{ .ctrl_z = {} }); // undo backspace → "a"
    try std.testing.expectEqualStrings("a", ed.text());

    _ = try ed.apply(.{ .char = 'b' }); // new edit clears redo
    try std.testing.expectEqualStrings("ab", ed.text());

    _ = try ed.apply(.{ .ctrl_shift_z = {} }); // redo should be empty → no-op
    try std.testing.expectEqualStrings("ab", ed.text());
}
