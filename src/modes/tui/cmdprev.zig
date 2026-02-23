const std = @import("std");
const frame_mod = @import("frame.zig");
const theme_mod = @import("theme.zig");
const fuzzy_mod = @import("fuzzy.zig");

const Frame = frame_mod.Frame;
const Style = frame_mod.Style;

pub const Cmd = struct {
    name: []const u8,
    desc: []const u8,
};

pub const cmds = [_]Cmd{
    .{ .name = "changelog", .desc = "What's new" },
    .{ .name = "clear", .desc = "Clear transcript" },
    .{ .name = "compact", .desc = "Compact session" },
    .{ .name = "copy", .desc = "Copy last response" },
    .{ .name = "cost", .desc = "Show token costs" },
    .{ .name = "exit", .desc = "Exit" },
    .{ .name = "export", .desc = "Export to markdown" },
    .{ .name = "fork", .desc = "Fork session" },
    .{ .name = "help", .desc = "Show commands" },
    .{ .name = "hotkeys", .desc = "Keyboard shortcuts" },
    .{ .name = "login", .desc = "Login (OAuth)" },
    .{ .name = "logout", .desc = "Logout" },
    .{ .name = "model", .desc = "Set model" },
    .{ .name = "name", .desc = "Name session" },
    .{ .name = "new", .desc = "New session" },
    .{ .name = "provider", .desc = "Set/show provider" },
    .{ .name = "quit", .desc = "Exit" },
    .{ .name = "reload", .desc = "Reload context" },
    .{ .name = "resume", .desc = "Resume session" },
    .{ .name = "session", .desc = "Session info" },
    .{ .name = "settings", .desc = "Current settings" },
    .{ .name = "share", .desc = "Share as gist" },
    .{ .name = "tools", .desc = "Set/show tools" },
    .{ .name = "tree", .desc = "List sessions" },
    .{ .name = "bg", .desc = "Background jobs" },
};

/// Max visible rows in the dropdown (pi uses 5).
const max_vis: u8 = 5;

/// Description column start (pi: prefix=2 + value padded to 30 → col 32).
const desc_col: usize = 32;

const max_match: u8 = 32;

pub const CmdPreview = struct {
    matches: [max_match]u8,
    n: u8,
    sel: u8 = 0,
    scroll: u8 = 0,
    arg_src: ?[]const []const u8 = null, // non-null = arg mode

    pub fn update(prefix: []const u8) ?CmdPreview {
        var cp = CmdPreview{ .matches = undefined, .n = 0 };
        // Try prefix matching first
        for (cmds, 0..) |cmd, i| {
            if (cp.n >= max_match) break;
            if (prefix.len <= cmd.name.len and std.mem.startsWith(u8, cmd.name, prefix)) {
                cp.matches[cp.n] = @intCast(i);
                cp.n += 1;
            }
        }
        if (cp.n > 0) return cp;
        // Fallback to fuzzy matching
        var scores: [cmds.len]i32 = undefined;
        for (cmds, 0..) |cmd, i| {
            if (cp.n >= max_match) break;
            if (fuzzy_mod.score(prefix, cmd.name)) |s| {
                scores[cp.n] = s;
                cp.matches[cp.n] = @intCast(i);
                cp.n += 1;
            }
        }
        if (cp.n == 0) return null;
        // Sort by score (lower = better) using insertion sort
        var j: u8 = 1;
        while (j < cp.n) : (j += 1) {
            const key_score = scores[j];
            const key_match = cp.matches[j];
            var k: u8 = j;
            while (k > 0 and scores[k - 1] > key_score) : (k -= 1) {
                scores[k] = scores[k - 1];
                cp.matches[k] = cp.matches[k - 1];
            }
            scores[k] = key_score;
            cp.matches[k] = key_match;
        }
        return cp;
    }

    /// Filter arg items by prefix match.
    pub fn updateArgs(src: []const []const u8, prefix: []const u8) ?CmdPreview {
        var cp = CmdPreview{ .matches = undefined, .n = 0, .arg_src = src };
        for (src, 0..) |item, i| {
            if (cp.n >= max_match) break;
            if (prefix.len == 0 or (prefix.len <= item.len and std.mem.startsWith(u8, item, prefix))) {
                cp.matches[cp.n] = @intCast(i);
                cp.n += 1;
            }
        }
        if (cp.n > 0) return cp;
        // Fuzzy fallback
        for (src, 0..) |item, i| {
            if (cp.n >= max_match) break;
            if (fuzzy_mod.score(prefix, item) != null) {
                cp.matches[cp.n] = @intCast(i);
                cp.n += 1;
            }
        }
        if (cp.n == 0) return null;
        return cp;
    }

    /// Navigate up, wrapping to bottom (matches pi).
    pub fn up(self: *CmdPreview) void {
        if (self.n == 0) return;
        if (self.sel > 0) {
            self.sel -= 1;
        } else {
            self.sel = self.n - 1;
        }
        self.fixScroll();
    }

    /// Navigate down, wrapping to top (matches pi).
    pub fn down(self: *CmdPreview) void {
        if (self.n == 0) return;
        if (self.sel + 1 < self.n) {
            self.sel += 1;
        } else {
            self.sel = 0;
        }
        self.fixScroll();
    }

    fn fixScroll(self: *CmdPreview) void {
        // Center selection in visible window (pi: selectedIndex - floor(maxVisible/2))
        const half = max_vis / 2;
        if (self.n <= max_vis) {
            self.scroll = 0;
        } else if (self.sel < half) {
            self.scroll = 0;
        } else if (self.sel + max_vis - half > self.n) {
            self.scroll = self.n - max_vis;
        } else {
            self.scroll = self.sel - half;
        }
    }

    pub fn selected(self: *const CmdPreview) Cmd {
        return cmds[self.matches[self.sel]];
    }

    /// Return the selected arg text (arg mode only).
    pub fn selectedArg(self: *const CmdPreview) ?[]const u8 {
        const src = self.arg_src orelse return null;
        if (self.sel >= self.n) return null;
        const idx = self.matches[self.sel];
        if (idx >= src.len) return null;
        return src[idx];
    }

    /// Returns total visible rows (items + optional scroll indicator).
    pub fn visRows(self: *const CmdPreview) usize {
        const item_rows = @min(@as(usize, self.n) - self.scroll, max_vis);
        const has_scroll = self.scroll > 0 or self.scroll + max_vis < self.n;
        return item_rows + @as(usize, if (has_scroll) 1 else 0);
    }

    /// Render the dropdown downward from y_start, matching pi's layout.
    /// Visual format: "→ /name" (selected) or "  /name" + description at col 32.
    pub fn renderDown(self: *const CmdPreview, frm: *Frame, y_start: usize, w: usize, h: usize) !void {
        const avail = if (h > y_start) h - y_start else return;
        const t = theme_mod.get();
        const item_vis: usize = @min(@min(@as(usize, self.n) - self.scroll, max_vis), avail);
        const has_scroll = self.scroll > 0 or self.scroll + max_vis < self.n;
        const scroll_row = has_scroll and item_vis + 1 <= avail;
        if (item_vis == 0 or w < 6) return;

        const is_arg = self.arg_src != null;
        var i: usize = 0;
        while (i < item_vis) : (i += 1) {
            const idx = self.scroll + @as(u8, @intCast(i));
            const is_sel = idx == self.sel;
            const y = y_start + i;

            const sel_st = Style{ .fg = t.text, .bold = true };
            const name_st = if (is_sel) sel_st else Style{ .fg = t.text };
            const prefix_st = if (is_sel) sel_st else Style{};

            // Clear row
            var x: usize = 0;
            while (x < w) : (x += 1) {
                try frm.set(x, y, ' ', .{});
            }

            // Prefix: "→ " or "  "
            if (is_sel) {
                try frm.set(0, y, 0x2192, prefix_st); // →
                try frm.set(1, y, ' ', prefix_st);
            }

            x = 2;
            if (is_arg) {
                // Arg mode: just show the item text
                const src = self.arg_src.?;
                if (self.matches[idx] < src.len) {
                    for (src[self.matches[idx]]) |ch| {
                        if (x >= w -| 1) break;
                        try frm.set(x, y, ch, name_st);
                        x += 1;
                    }
                }
            } else {
                // Cmd mode: "/name" + description
                const cmd = cmds[self.matches[idx]];
                if (x < w) {
                    try frm.set(x, y, '/', name_st);
                    x += 1;
                }
                for (cmd.name) |ch| {
                    if (x >= w) break;
                    try frm.set(x, y, ch, name_st);
                    x += 1;
                }

                // Description at desc_col (only if terminal wide enough, pi: width > 40)
                if (w > 40) {
                    const desc_st = if (is_sel) sel_st else Style{ .fg = t.muted };
                    x = desc_col;
                    for (cmd.desc) |ch| {
                        if (x >= w -| 2) break;
                        try frm.set(x, y, ch, desc_st);
                        x += 1;
                    }
                }
            }
        }

        // Scroll indicator: "  (sel+1/total)" (pi format)
        if (scroll_row) {
            const y = y_start + item_vis;
            const dim_st = Style{ .fg = t.muted };
            var buf: [24]u8 = undefined;
            const txt = std.fmt.bufPrint(&buf, "  ({d}/{d})", .{
                @as(usize, self.sel) + 1,
                @as(usize, self.n),
            }) catch return error.Overflow;
            var sx: usize = 0;
            for (txt) |ch| {
                if (sx >= w) break;
                try frm.set(sx, y, ch, dim_st);
                sx += 1;
            }
        }
    }
};

// -- Tests --

test "update empty prefix returns all" {
    const cp = CmdPreview.update("").?;
    try std.testing.expectEqual(@as(u8, cmds.len), cp.n);
    try std.testing.expectEqual(@as(u8, 0), cp.sel);
}

test "update filters by prefix" {
    const cp = CmdPreview.update("co").?;
    // compact, copy, cost
    try std.testing.expectEqual(@as(u8, 3), cp.n);
    try std.testing.expectEqualStrings("compact", cp.selected().name);
}

test "update ex matches exit and export" {
    const cp = CmdPreview.update("ex").?;
    try std.testing.expectEqual(@as(u8, 2), cp.n);
    try std.testing.expectEqualStrings("exit", cmds[cp.matches[0]].name);
    try std.testing.expectEqualStrings("export", cmds[cp.matches[1]].name);
}

test "update no match returns null" {
    try std.testing.expect(CmdPreview.update("zzz") == null);
}

test "update fuzzy fallback" {
    // "mdl" doesn't prefix-match any cmd, but fuzzy matches "model"
    const cp = CmdPreview.update("mdl").?;
    try std.testing.expect(cp.n > 0);
    // "model" should be in the results
    var found = false;
    for (cp.matches[0..cp.n]) |idx| {
        if (std.mem.eql(u8, cmds[idx].name, "model")) found = true;
    }
    try std.testing.expect(found);
}

test "update exact match" {
    const cp = CmdPreview.update("help").?;
    try std.testing.expectEqual(@as(u8, 1), cp.n);
    try std.testing.expectEqualStrings("help", cp.selected().name);
}

test "up wraps to bottom" {
    var cp = CmdPreview.update("").?;
    cp.up();
    try std.testing.expectEqual(cmds.len - 1, @as(usize, cp.sel));
}

test "down wraps to top" {
    var cp = CmdPreview.update("ex").?; // 2 items
    cp.down(); // sel=1
    cp.down(); // wrap to 0
    try std.testing.expectEqual(@as(u8, 0), cp.sel);
}

test "down scrolls window" {
    var cp = CmdPreview.update("").?; // 22 items, max_vis=5
    var i: u8 = 0;
    while (i < max_vis) : (i += 1) cp.down();
    try std.testing.expectEqual(max_vis, cp.sel);
    try std.testing.expect(cp.scroll > 0);
}

test "up scrolls back" {
    var cp = CmdPreview.update("").?;
    var i: u8 = 0;
    while (i < max_vis + 2) : (i += 1) cp.down();
    while (i > 0) : (i -= 1) cp.up();
    try std.testing.expectEqual(@as(u8, 0), cp.sel);
    try std.testing.expectEqual(@as(u8, 0), cp.scroll);
}

test "selected returns correct cmd" {
    var cp = CmdPreview.update("").?;
    try std.testing.expectEqualStrings("changelog", cp.selected().name);
    cp.down();
    try std.testing.expectEqualStrings("clear", cp.selected().name);
}

test "renderDown selected row has arrow and bold" {
    var frm = try Frame.init(std.testing.allocator, 50, 10);
    defer frm.deinit(std.testing.allocator);

    const cp = CmdPreview.update("co").?; // 3 items, sel=0
    try cp.renderDown(&frm, 2, 50, 10);

    // First row (sel=0) at y=2: "→ /compact"
    const arrow = try frm.cell(0, 2);
    try std.testing.expectEqual(@as(u21, 0x2192), arrow.cp); // →
    try std.testing.expect(arrow.style.bold);

    const slash = try frm.cell(2, 2);
    try std.testing.expectEqual(@as(u21, '/'), slash.cp);
    try std.testing.expect(slash.style.bold);

    // Second row (unselected) at y=3: "  /copy"
    const sp = try frm.cell(0, 3);
    try std.testing.expectEqual(@as(u21, ' '), sp.cp);
    const c2 = try frm.cell(3, 3);
    try std.testing.expectEqual(@as(u21, 'c'), c2.cp);
    try std.testing.expect(!c2.style.bold);
}

test "renderDown description at col 32 when wide" {
    var frm = try Frame.init(std.testing.allocator, 60, 10);
    defer frm.deinit(std.testing.allocator);

    const cp = CmdPreview.update("help").?; // 1 item
    try cp.renderDown(&frm, 3, 60, 10);

    // desc "Show commands" at col 32, y=3
    const c = try frm.cell(32, 3);
    try std.testing.expectEqual(@as(u21, 'S'), c.cp);
}

test "renderDown no description when narrow" {
    var frm = try Frame.init(std.testing.allocator, 35, 10);
    defer frm.deinit(std.testing.allocator);

    const cp = CmdPreview.update("help").?;
    try cp.renderDown(&frm, 3, 35, 10);

    // At col 32 should be space (no desc rendered when w <= 40)
    const c = try frm.cell(32, 3);
    try std.testing.expectEqual(@as(u21, ' '), c.cp);
}

test "renderDown with limited height" {
    var frm = try Frame.init(std.testing.allocator, 50, 4);
    defer frm.deinit(std.testing.allocator);

    const cp = CmdPreview.update("").?; // 22 items, only 2 rows available (h=4, start=2)
    try cp.renderDown(&frm, 2, 50, 4);

    // Should render 2 rows at y=2,3
    const c = try frm.cell(2, 2);
    try std.testing.expectEqual(@as(u21, '/'), c.cp);
}

test "renderDown scroll indicator shown" {
    var frm = try Frame.init(std.testing.allocator, 50, 10);
    defer frm.deinit(std.testing.allocator);

    const cp = CmdPreview.update("").?; // 22 items > max_vis=5
    try cp.renderDown(&frm, 1, 50, 10);

    // 5 item rows at y=1..5, scroll indicator at y=6: "  (1/22)"
    const c0 = try frm.cell(2, 6);
    try std.testing.expectEqual(@as(u21, '('), c0.cp);
}

test "visRows accounts for scroll indicator" {
    const cp = CmdPreview.update("").?; // 22 items
    // 5 visible + 1 scroll indicator = 6
    try std.testing.expectEqual(@as(usize, 6), cp.visRows());

    // 2 items, no scroll indicator
    const cp2 = CmdPreview.update("ex").?;
    try std.testing.expectEqual(@as(usize, 2), cp2.visRows());
}

test "updateArgs filters by prefix" {
    const items = [_][]const u8{ "anthropic", "openai", "google" };
    const cp = CmdPreview.updateArgs(&items, "an").?;
    try std.testing.expectEqual(@as(u8, 1), cp.n);
    try std.testing.expectEqualStrings("anthropic", cp.selectedArg().?);
}

test "updateArgs empty prefix returns all" {
    const items = [_][]const u8{ "anthropic", "openai", "google" };
    const cp = CmdPreview.updateArgs(&items, "").?;
    try std.testing.expectEqual(@as(u8, 3), cp.n);
}

test "updateArgs no match returns null" {
    const items = [_][]const u8{ "anthropic", "openai", "google" };
    try std.testing.expect(CmdPreview.updateArgs(&items, "zzz") == null);
}

test "updateArgs renders without slash" {
    const items = [_][]const u8{ "all", "none", "read" };
    const cp = CmdPreview.updateArgs(&items, "").?;

    var frm = try Frame.init(std.testing.allocator, 40, 10);
    defer frm.deinit(std.testing.allocator);
    try cp.renderDown(&frm, 1, 40, 10);

    // First row at y=1: "→ all" (no slash)
    const arrow = try frm.cell(0, 1);
    try std.testing.expectEqual(@as(u21, 0x2192), arrow.cp);
    // 'a' at col 2 (no slash)
    const a = try frm.cell(2, 1);
    try std.testing.expectEqual(@as(u21, 'a'), a.cp);
}
