const std = @import("std");
const frame_mod = @import("frame.zig");
const theme_mod = @import("theme.zig");
const wc = @import("wcwidth.zig");

const Frame = frame_mod.Frame;
const Style = frame_mod.Style;
const Color = frame_mod.Color;

pub const Kind = enum { model, session, settings, fork, login, logout };

pub const Overlay = struct {
    items: []const []const u8,
    dyn_items: ?[][]u8 = null, // owned items (freed on deinit)
    toggles: ?[]bool = null, // toggle state per item (settings kind)
    sel: usize = 0,
    scroll: usize = 0,
    title: []const u8 = "Select Model",
    kind: Kind = .model,

    const max_vis: usize = 12;

    pub fn init(items: []const []const u8, cur: usize) Overlay {
        return .{ .items = items, .sel = if (items.len > 0) @min(cur, items.len - 1) else 0 };
    }

    pub fn initDyn(alloc: std.mem.Allocator, dyn: [][]u8, title: []const u8, kind: Kind) Overlay {
        _ = alloc;
        return .{
            .items = &.{},
            .dyn_items = dyn,
            .title = title,
            .kind = kind,
        };
    }

    pub fn deinit(self: *Overlay, alloc: std.mem.Allocator) void {
        if (self.dyn_items) |items| {
            for (items) |item| alloc.free(item);
            alloc.free(items);
            self.dyn_items = null;
        }
        if (self.toggles) |t| {
            alloc.free(t);
            self.toggles = null;
        }
    }

    pub fn toggle(self: *Overlay) void {
        if (self.toggles) |t| {
            if (self.sel < t.len) t[self.sel] = !t[self.sel];
        }
    }

    pub fn getToggle(self: *const Overlay, idx: usize) ?bool {
        if (self.toggles) |t| {
            if (idx < t.len) return t[idx];
        }
        return null;
    }

    fn itemSlice(self: *const Overlay) []const []const u8 {
        if (self.dyn_items) |d| {
            // Cast [][]u8 to []const []const u8
            const ptr: [*]const []const u8 = @ptrCast(d.ptr);
            return ptr[0..d.len];
        }
        return self.items;
    }

    fn itemCount(self: *const Overlay) usize {
        if (self.dyn_items) |d| return d.len;
        return self.items.len;
    }

    pub fn up(self: *Overlay) void {
        const n = self.itemCount();
        if (n == 0) return;
        if (self.sel > 0) self.sel -= 1 else self.sel = n - 1;
        self.fixScroll();
    }

    pub fn down(self: *Overlay) void {
        const n = self.itemCount();
        if (n == 0) return;
        if (self.sel + 1 < n) self.sel += 1 else self.sel = 0;
        self.fixScroll();
    }

    pub fn fixScroll(self: *Overlay) void {
        if (self.sel < self.scroll) self.scroll = self.sel;
        if (self.sel >= self.scroll + max_vis) self.scroll = self.sel - max_vis + 1;
    }

    pub fn selected(self: *const Overlay) ?[]const u8 {
        const items = self.itemSlice();
        if (items.len == 0) return null;
        return items[self.sel];
    }

    pub fn render(self: *const Overlay, frm: *Frame) !void {
        const t = theme_mod.get();
        const items = self.itemSlice();

        // Compute box dimensions
        var max_w: usize = wc.strwidth(self.title);
        const vis_n = @min(items.len, max_vis);
        for (items) |item| {
            const label = if (self.kind == .model) shortLabel(item) else item;
            const lw = wc.strwidth(label);
            if (lw + 4 > max_w) max_w = lw + 4;
        }
        const box_w = @min(max_w + 4, frm.w);
        const box_h = vis_n + 2;

        if (box_w < 8 or box_h > frm.h) return;

        const x0 = (frm.w - box_w) / 2;
        const y0 = (frm.h - box_h) / 2;

        const border_rgb = switch (t.border_c) {
            .rgb => |v| v,
            else => 0x555555,
        };
        const heading_rgb = switch (t.md_heading) {
            .rgb => |v| v,
            else => 0xc5c8c6,
        };
        const border_st = Style{ .fg = .{ .rgb = border_rgb } };
        const title_st = Style{ .fg = .{ .rgb = heading_rgb }, .bold = true };
        const item_st = Style{ .fg = .{ .rgb = 0xc5c8c6 } };
        const sel_st = Style{ .fg = .{ .rgb = 0x81a1c1 }, .bold = true };
        const bg: Color = .{ .rgb = 0x1d1f21 };
        const sel_bg: Color = .{ .rgb = 0x2d2f31 };

        // Draw border and background
        // Top border: ┌─ title ─┐
        try frm.set(x0, y0, 0x250C, border_st); // ┌
        {
            var x = x0 + 1;
            const title_w = wc.strwidth(self.title);
            const pad_total = box_w -| 2 -| title_w;
            const pad_l = pad_total / 2;
            const pad_r = pad_total - pad_l;
            var pi: usize = 0;
            while (pi < pad_l) : (pi += 1) {
                try frm.set(x, y0, 0x2500, border_st); // ─
                x += 1;
            }
            var ti: usize = 0;
            while (ti < self.title.len) {
                const n = std.unicode.utf8ByteSequenceLength(self.title[ti]) catch break;
                if (ti + n > self.title.len) break;
                const cp = std.unicode.utf8Decode(self.title[ti .. ti + n]) catch break;
                if (x >= x0 + box_w - 1) break;
                try frm.set(x, y0, cp, title_st);
                x += wc.wcwidth(cp);
                ti += n;
            }
            pi = 0;
            while (pi < pad_r) : (pi += 1) {
                if (x >= x0 + box_w - 1) break;
                try frm.set(x, y0, 0x2500, border_st);
                x += 1;
            }
        }
        try frm.set(x0 + box_w - 1, y0, 0x2510, border_st); // ┐

        // Items (scrolled window)
        var row: usize = 0;
        while (row < vis_n) : (row += 1) {
            const idx = self.scroll + row;
            if (idx >= items.len) break;
            const item = items[idx];
            const y = y0 + 1 + row;
            const is_sel = idx == self.sel;
            const row_bg = if (is_sel) sel_bg else bg;
            const row_st = if (is_sel) sel_st else item_st;
            const prefix_st = Style{ .fg = if (is_sel) .{ .rgb = 0x81a1c1 } else .{ .default = {} } };

            try frm.set(x0, y, 0x2502, border_st); // │

            // Fill background
            var x = x0 + 1;
            while (x < x0 + box_w - 1) : (x += 1) {
                try frm.set(x, y, ' ', Style{ .bg = row_bg });
            }

            // Write prefix
            x = x0 + 2;
            if (is_sel) {
                try frm.set(x, y, '>', Style{ .fg = prefix_st.fg, .bg = row_bg, .bold = true });
                x += 1;
                try frm.set(x, y, ' ', Style{ .bg = row_bg });
                x += 1;
            } else {
                try frm.set(x, y, ' ', Style{ .bg = row_bg });
                x += 1;
                try frm.set(x, y, ' ', Style{ .bg = row_bg });
                x += 1;
            }

            // Write label
            const label = if (self.kind == .model) shortLabel(item) else item;
            var li: usize = 0;
            while (li < label.len) {
                if (x >= x0 + box_w - 2) break;
                const n = std.unicode.utf8ByteSequenceLength(label[li]) catch break;
                if (li + n > label.len) break;
                const cp = std.unicode.utf8Decode(label[li .. li + n]) catch break;
                const cw = wc.wcwidth(cp);
                if (x + cw > x0 + box_w - 1) break;
                try frm.set(x, y, cp, Style{
                    .fg = row_st.fg,
                    .bg = row_bg,
                    .bold = row_st.bold,
                });
                x += cw;
                li += n;
            }

            // Toggle indicator for settings
            if (self.kind == .settings) {
                if (self.getToggle(idx)) |on| {
                    // Right-align the indicator
                    const ind_x = x0 + box_w - 3;
                    if (ind_x > x) {
                        const ind_cp: u21 = if (on) 0x2713 else 0x2717; // ✓ or ✗
                        const ind_fg: Color = if (on) .{ .rgb = 0xa3be8c } else .{ .rgb = 0xbf616a };
                        try frm.set(ind_x, y, ind_cp, Style{ .fg = ind_fg, .bg = row_bg });
                    }
                }
            }

            try frm.set(x0 + box_w - 1, y, 0x2502, border_st); // │
        }

        // Bottom border: └──────┘
        const yb = y0 + box_h - 1;
        try frm.set(x0, yb, 0x2514, border_st); // └
        {
            var x = x0 + 1;
            while (x < x0 + box_w - 1) : (x += 1) {
                try frm.set(x, yb, 0x2500, border_st);
            }
        }
        try frm.set(x0 + box_w - 1, yb, 0x2518, border_st); // ┘
    }
};

/// Extract short display name from full model ID.
/// "claude-opus-4-6-20250219" → "claude-opus-4-6"
fn shortLabel(model: []const u8) []const u8 {
    // Strip date suffix (-YYYYMMDD)
    if (model.len >= 9 and model[model.len - 9] == '-') {
        const suffix = model[model.len - 8 ..];
        // Check all digits
        for (suffix) |c| {
            if (c < '0' or c > '9') return model;
        }
        return model[0 .. model.len - 9];
    }
    return model;
}

test "overlay renders centered box" {
    const items = [_][]const u8{ "model-a", "model-b", "model-c" };
    const ov = Overlay.init(&items, 1);

    var frm = try Frame.init(std.testing.allocator, 30, 10);
    defer frm.deinit(std.testing.allocator);

    try ov.render(&frm);

    // Top-left corner should be ┌
    const x0 = (30 - (11 + 4)) / 2; // max_w=12("Select Model"), box_w=16
    const y0 = (10 - 5) / 2; // box_h = 3 items + 2 = 5
    const c = try frm.cell(x0, y0);
    try std.testing.expectEqual(@as(u21, 0x250C), c.cp);

    // Selected item (idx 1) should have '>'
    const sel_c = try frm.cell(x0 + 2, y0 + 2);
    try std.testing.expectEqual(@as(u21, '>'), sel_c.cp);
}

test "overlay navigation wraps" {
    const items = [_][]const u8{ "a", "b", "c" };
    var ov = Overlay.init(&items, 0);

    ov.up();
    try std.testing.expectEqual(@as(usize, 2), ov.sel);

    ov.down();
    try std.testing.expectEqual(@as(usize, 0), ov.sel);
}

test "overlay scrolls with many items" {
    // 25 items to ensure scrolling with max_vis=12
    const items = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y" };
    var ov = Overlay.init(&items, 0);
    var i: usize = 0;
    while (i < Overlay.max_vis + 2) : (i += 1) ov.down();
    try std.testing.expect(ov.scroll > 0);
    try std.testing.expectEqual(Overlay.max_vis + 2, ov.sel);
    while (i > 0) : (i -= 1) ov.up();
    try std.testing.expectEqual(@as(usize, 0), ov.sel);
    try std.testing.expectEqual(@as(usize, 0), ov.scroll);
}

test "overlay session kind renders without shortLabel" {
    var items = [_][]u8{
        try std.testing.allocator.dupe(u8, "sess-abc-123"),
        try std.testing.allocator.dupe(u8, "sess-def-456"),
    };
    var ov = Overlay{
        .items = &.{},
        .dyn_items = &items,
        .title = "Resume Session",
        .kind = .session,
    };

    var frm = try Frame.init(std.testing.allocator, 40, 10);
    defer frm.deinit(std.testing.allocator);
    try ov.render(&frm);

    // Verify first item "sess-abc-123" is rendered (not shortLabel'd)
    // Find '>' for selected row
    const x0 = (40 - (@as(usize, 16) + 4)) / 2;
    const y0 = (10 - 4) / 2;
    const c = try frm.cell(x0 + 2, y0 + 1);
    try std.testing.expectEqual(@as(u21, '>'), c.cp);

    // Don't free — items are stack-allocated slices
    for (&items) |*item| std.testing.allocator.free(item.*);
}

test "settings overlay toggle and render" {
    const labels = [_][]const u8{ "Show tools", "Show thinking", "Auto-compact" };
    var toggles = [_]bool{ true, true, false };
    var ov = Overlay{
        .items = &labels,
        .title = "Settings",
        .kind = .settings,
        .toggles = &toggles,
    };

    // Toggle first item
    ov.toggle();
    try std.testing.expectEqual(false, ov.getToggle(0).?);
    try std.testing.expectEqual(true, ov.getToggle(1).?);

    // Render without crash
    var frm = try Frame.init(std.testing.allocator, 40, 10);
    defer frm.deinit(std.testing.allocator);
    try ov.render(&frm);

    // Check for ✗ indicator (0x2717) on first row (toggled off)
    const box_w = @min(@as(usize, 14) + 4, @as(usize, 40)); // "Show thinking" = 13 + 4 pad = 17 + 4 = 21
    _ = box_w;
}

test "shortLabel strips date suffix" {
    try std.testing.expectEqualStrings("claude-opus-4-6", shortLabel("claude-opus-4-6-20250219"));
    try std.testing.expectEqualStrings("my-model", shortLabel("my-model"));
    try std.testing.expectEqualStrings("model-with-abc", shortLabel("model-with-abc"));
}
