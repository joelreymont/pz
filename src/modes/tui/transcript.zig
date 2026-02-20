const std = @import("std");
const core = @import("../../core/mod.zig");
const frame = @import("frame.zig");

pub const Rect = struct {
    x: usize,
    y: usize,
    w: usize,
    h: usize,
};

const Line = struct {
    text: []u8,
    st: frame.Style,
};

pub const Transcript = struct {
    alloc: std.mem.Allocator,
    lines: std.ArrayListUnmanaged(Line) = .empty,

    pub const AppendError = std.mem.Allocator.Error || error{InvalidUtf8};
    pub const RenderError = frame.Frame.PosError || error{InvalidUtf8};

    pub fn init(alloc: std.mem.Allocator) Transcript {
        return .{
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *Transcript) void {
        for (self.lines.items) |line| self.alloc.free(line.text);
        self.lines.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn count(self: *const Transcript) usize {
        return self.lines.items.len;
    }

    pub fn append(self: *Transcript, ev: core.providers.Ev) AppendError!void {
        switch (ev) {
            .text => |text| try self.pushLine(text, .{}),
            .thinking => |text| try self.pushFmt("[thinking] {s}", .{text}, .{
                .fg = .bright_black,
            }),
            .tool_call => |tc| try self.pushFmt("[tool {s}#{s}] {s}", .{
                tc.name,
                tc.id,
                tc.args,
            }, .{
                .fg = .yellow,
            }),
            .tool_result => |tr| try self.pushFmt("[tool-result #{s} err={s}] {s}", .{
                tr.id,
                if (tr.is_err) "true" else "false",
                tr.out,
            }, .{
                .fg = if (tr.is_err) .red else .green,
            }),
            .err => |text| try self.pushFmt("[err] {s}", .{text}, .{
                .fg = .red,
                .bold = true,
            }),
            .usage => |usage| try self.pushFmt("[usage {d}/{d}/{d}]", .{
                usage.in_tok,
                usage.out_tok,
                usage.tot_tok,
            }, .{
                .fg = .bright_black,
            }),
            .stop => |stop| try self.pushFmt("[stop {s}]", .{
                @tagName(stop.reason),
            }, .{
                .fg = .bright_black,
            }),
        }
    }

    pub fn render(self: *const Transcript, frm: *frame.Frame, rect: Rect) RenderError!void {
        if (rect.w == 0 or rect.h == 0) return;

        const x_end = try rectEndX(frm, rect);
        _ = try rectEndY(frm, rect);
        try clearRect(frm, rect);

        const shown = @min(self.lines.items.len, rect.h);
        const src_start = self.lines.items.len - shown;
        const dst_start = rect.y + rect.h - shown;

        var i: usize = 0;
        while (i < shown) : (i += 1) {
            const line = self.lines.items[src_start + i];
            const fit = try clipCols(line.text, rect.w);
            _ = try frm.write(rect.x, dst_start + i, fit, line.st);

            if (fit.len < line.text.len and rect.w >= 1) {
                try frm.set(x_end - 1, dst_start + i, '.', line.st);
            }
        }
    }

    fn pushLine(self: *Transcript, text: []const u8, st: frame.Style) AppendError!void {
        try ensureUtf8(text);
        const dup = try self.alloc.dupe(u8, text);
        try self.lines.append(self.alloc, .{
            .text = dup,
            .st = st,
        });
    }

    fn pushFmt(
        self: *Transcript,
        comptime fmt: []const u8,
        args: anytype,
        st: frame.Style,
    ) AppendError!void {
        const txt = try std.fmt.allocPrint(self.alloc, fmt, args);
        errdefer self.alloc.free(txt);
        try ensureUtf8(txt);
        try self.lines.append(self.alloc, .{
            .text = txt,
            .st = st,
        });
    }
};

fn ensureUtf8(text: []const u8) error{InvalidUtf8}!void {
    _ = std.unicode.Utf8View.init(text) catch return error.InvalidUtf8;
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
        try std.testing.expect(c.cp <= 0x7f);
        out[x] = @intCast(c.cp);
    }
    return out[0..frm.w];
}

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

    try std.testing.expect(std.mem.indexOf(u8, r0, "[thinking] two") != null);
    try std.testing.expect(std.mem.indexOf(u8, r1, "[tool read#c1] {}") != null);
    try std.testing.expect(std.mem.indexOf(u8, r2, "three") != null);
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
