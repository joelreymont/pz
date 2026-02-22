const std = @import("std");

pub const Key = union(enum) {
    char: u21,
    left: void,
    right: void,
    home: void,
    end: void,
    backspace: void,
    delete: void,
    enter: void,
    ctrl_c: void,
    ctrl_d: void,
    ctrl_g: void,
    ctrl_k: void,
    ctrl_l: void,
    ctrl_o: void,
    ctrl_p: void,
    ctrl_t: void,
    ctrl_v: void,
    ctrl_z: void,
    esc: void,
    shift_tab: void,
    alt_enter: void,
    alt_up: void,
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
};

pub const Editor = struct {
    alloc: std.mem.Allocator,
    buf: std.ArrayListUnmanaged(u8) = .empty,
    cur: usize = 0,

    pub fn init(alloc: std.mem.Allocator) Editor {
        return .{
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *Editor) void {
        self.buf.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn text(self: *const Editor) []const u8 {
        return self.buf.items;
    }

    pub fn cursor(self: *const Editor) usize {
        return self.cur;
    }

    pub fn setText(self: *Editor, t: []const u8) !void {
        self.buf.items.len = 0;
        try self.buf.appendSlice(self.alloc, t);
        self.cur = self.buf.items.len;
    }

    pub fn clear(self: *Editor) void {
        self.buf.items.len = 0;
        self.cur = 0;
    }

    pub fn apply(self: *Editor, key: Key) !Action {
        return switch (key) {
            .char => |cp| blk: {
                try insertCp(self, cp);
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
                self.backspace();
                break :blk .none;
            },
            .delete => blk: {
                self.delete();
                break :blk .none;
            },
            .enter => .submit,
            .ctrl_c => if (self.buf.items.len > 0) blk: {
                self.clear();
                break :blk .interrupt;
            } else .cancel,
            .ctrl_d => if (self.buf.items.len == 0) Action.cancel else .none,
            .ctrl_g => .ext_editor,
            .ctrl_k => blk: {
                self.killToEol();
                break :blk .kill_to_eol;
            },
            .ctrl_l => .select_model,
            .ctrl_o => .toggle_tools,
            .ctrl_p => .cycle_model,
            .ctrl_t => .toggle_thinking,
            .ctrl_v => .paste_image,
            .ctrl_z => .@"suspend",
            .alt_enter => .queue_followup,
            .alt_up => .edit_queued,
            .esc => blk: {
                if (self.buf.items.len > 0) self.clear();
                break :blk .interrupt;
            },
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

    fn killToEol(self: *Editor) void {
        self.buf.items.len = self.cur;
    }

    fn deleteRange(self: *Editor, start: usize, end: usize) void {
        const tail = self.buf.items[end..];
        std.mem.copyForwards(u8, self.buf.items[start .. start + tail.len], tail);
        self.buf.items.len -= end - start;
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

test "new keys produce correct actions" {
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();

    try std.testing.expect((try ed.apply(.{ .ctrl_z = {} })) == .@"suspend");
    try std.testing.expect((try ed.apply(.{ .ctrl_l = {} })) == .select_model);
    try std.testing.expect((try ed.apply(.{ .ctrl_g = {} })) == .ext_editor);
    try std.testing.expect((try ed.apply(.{ .ctrl_v = {} })) == .paste_image);
    try std.testing.expect((try ed.apply(.{ .alt_enter = {} })) == .queue_followup);
    try std.testing.expect((try ed.apply(.{ .alt_up = {} })) == .edit_queued);
}
