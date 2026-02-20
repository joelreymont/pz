const std = @import("std");
const core = @import("../../core/mod.zig");
const editor = @import("editor.zig");
const transcript = @import("transcript.zig");
const panels = @import("panels.zig");
const frame = @import("frame.zig");
const render = @import("render.zig");

pub const Ui = struct {
    alloc: std.mem.Allocator,
    ed: editor.Editor,
    tr: transcript.Transcript,
    pn: panels.Panels,
    frm: frame.Frame,
    rnd: render.Renderer,

    pub fn init(
        alloc: std.mem.Allocator,
        w: usize,
        h: usize,
        model: []const u8,
        provider: []const u8,
    ) !Ui {
        return .{
            .alloc = alloc,
            .ed = editor.Editor.init(alloc),
            .tr = transcript.Transcript.init(alloc),
            .pn = try panels.Panels.init(alloc, model, provider),
            .frm = try frame.Frame.init(alloc, w, h),
            .rnd = try render.Renderer.init(alloc, w, h),
        };
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
                try self.tr.append(.{ .text = self.ed.text() });
            }
            self.ed.clear();
        }
        return act;
    }

    pub fn draw(self: *Ui, out: anytype) !void {
        self.frm.clear();

        const w = self.frm.w;
        const h = self.frm.h;

        if (h >= 1) {
            try self.pn.renderStatus(&self.frm, .{
                .x = 0,
                .y = 0,
                .w = w,
                .h = 1,
            });
        }

        if (h >= 2) {
            const editor_y = h - 1;
            try self.drawEditorLine(editor_y);
        }

        if (h > 2 and w > 0) {
            const body_y: usize = 1;
            const body_h = h - 2;
            const tool_w = splitToolW(w);
            const tx_w = w - tool_w;

            if (tx_w > 0) {
                try self.tr.render(&self.frm, .{
                    .x = 0,
                    .y = body_y,
                    .w = tx_w,
                    .h = body_h,
                });
            }
            if (tool_w > 0) {
                try self.pn.renderTools(&self.frm, .{
                    .x = tx_w,
                    .y = body_y,
                    .w = tool_w,
                    .h = body_h,
                });
            }
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

    fn drawEditorLine(self: *Ui, y: usize) !void {
        const prompt = "> ";
        const st = frame.Style{
            .fg = .bright_white,
            .bold = true,
        };
        _ = try self.frm.write(0, y, prompt, st);

        if (self.frm.w <= prompt.len) return;
        const room = self.frm.w - prompt.len;
        const txt = try clipCols(self.ed.text(), room);
        _ = try self.frm.write(prompt.len, y, txt, .{});
    }
};

fn splitToolW(w: usize) usize {
    if (w <= 12) return @min(@as(usize, 4), w);
    const one_third = w / 3;
    return @max(@as(usize, 12), one_third);
}

fn clipCols(text: []const u8, cols: usize) error{InvalidUtf8}![]const u8 {
    if (cols == 0 or text.len == 0) return text[0..0];

    var i: usize = 0;
    var used: usize = 0;
    while (i < text.len and used < cols) {
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch return error.InvalidUtf8;
        _ = std.unicode.utf8Decode(text[i .. i + n]) catch return error.InvalidUtf8;
        i += n;
        used += 1;
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

test "harness renders fixed-size layout with transcript and tools" {
    var ui = try Ui.init(std.testing.allocator, 40, 8, "gpt-x", "prov-a");
    defer ui.deinit();

    try ui.onProvider(.{ .text = "hello" });
    try ui.onProvider(.{ .tool_call = .{
        .id = "c1",
        .name = "read",
        .args = "{}",
    } });
    try ui.onProvider(.{ .tool_result = .{
        .id = "c1",
        .out = "ok",
        .is_err = false,
    } });

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
