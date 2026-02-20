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
};

pub const Action = enum {
    none,
    submit,
    cancel,
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
            .ctrl_c => .cancel,
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
    try std.testing.expect((try ed.apply(.{ .ctrl_c = {} })) == .cancel);
}
