const std = @import("std");
const core = @import("../../core/mod.zig");
const editor = @import("editor.zig");
const mouse = @import("mouse.zig");
const transcript = @import("transcript.zig");
const panels = @import("panels.zig");
const frame = @import("frame.zig");
const render = @import("render.zig");
const theme = @import("theme.zig");

pub const Ui = struct {
    alloc: std.mem.Allocator,
    ed: editor.Editor,
    tr: transcript.Transcript,
    pn: panels.Panels,
    frm: frame.Frame,
    rnd: render.Renderer,
    border_fg: frame.Color = .{ .rgb = 0x81a2be },

    pub fn init(
        alloc: std.mem.Allocator,
        w: usize,
        h: usize,
        model: []const u8,
        provider: []const u8,
    ) !Ui {
        return initFull(alloc, w, h, model, provider, "", "");
    }

    pub fn initFull(
        alloc: std.mem.Allocator,
        w: usize,
        h: usize,
        model: []const u8,
        provider: []const u8,
        cwd: []const u8,
        branch: []const u8,
    ) !Ui {
        theme.init();
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
        self.rnd.deinit();
        self.frm.deinit(self.alloc);
        self.frm = try frame.Frame.init(self.alloc, w, h);
        self.rnd = try render.Renderer.init(self.alloc, w, h);
    }

    pub fn deinit(self: *Ui) void {
        self.rnd.deinit();
        self.frm.deinit(self.alloc);
        self.pn.deinit();
        self.tr.deinit();
        self.ed.deinit();
        self.* = undefined;
    }

    pub fn onProvider(self: *Ui, ev: core.providers.Ev) !void {
        try self.tr.append(ev);
        try self.pn.append(ev);
    }

    pub fn onKey(self: *Ui, key: editor.Key) !editor.Action {
        const act = try self.ed.apply(key);
        if (act == .submit) {
            if (self.ed.text().len != 0) {
                try self.tr.userText(self.ed.text());
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

        // Layout matching pi: transcript | border | editor | border | footer(2)
        // Reserved: 2 borders + 1 editor + 2 footer = 5
        const footer_h: usize = if (h >= 6) 2 else if (h >= 4) 1 else 0;
        const border_h: usize = if (h >= 5) 2 else 0;
        const editor_h: usize = if (h > footer_h + border_h) 1 else 0;
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
            try self.drawBorder(tx_h);
        }

        if (editor_h > 0) {
            try self.drawEditorLine(tx_h + @min(border_h, 1));
        }

        if (border_h >= 2) {
            try self.drawBorder(tx_h + 1 + editor_h);
        }

        if (footer_h > 0) {
            try self.pn.renderFooter(&self.frm, .{
                .x = 0,
                .y = h - footer_h,
                .w = w,
                .h = footer_h,
            });
        }

        try self.rnd.render(&self.frm, out);
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
        const st = frame.Style{ .fg = self.border_fg };
        var x: usize = 0;
        while (x < self.frm.w) : (x += 1) {
            try self.frm.set(x, y, 0x2500, st); // ─
        }
    }

    fn drawEditorLine(self: *Ui, y: usize) !void {
        // pi: 1-col left padding, no prompt character
        const pad: usize = 1;
        if (self.frm.w <= pad) return;
        const room = self.frm.w - pad;
        const txt = try clipCols(self.ed.text(), room);
        _ = try self.frm.write(pad, y, txt, .{});
    }
};

fn clipCols(text: []const u8, cols: usize) error{InvalidUtf8}![]const u8 {
    if (cols == 0 or text.len == 0) return text[0..0];
    const wcwidth = @import("wcwidth.zig").wcwidth;

    var i: usize = 0;
    var used: usize = 0;
    while (i < text.len) {
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch return error.InvalidUtf8;
        const cp = std.unicode.utf8Decode(text[i .. i + n]) catch return error.InvalidUtf8;
        const w: usize = wcwidth(cp);
        if (used + w > cols) break;
        i += n;
        used += w;
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
