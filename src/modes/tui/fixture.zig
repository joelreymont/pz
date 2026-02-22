const std = @import("std");
const core = @import("../../core/mod.zig");
const frame = @import("frame.zig");
const harness = @import("harness.zig");
const render = @import("render.zig");
const theme = @import("theme.zig");
const vscreen = @import("vscreen.zig");

const Ev = core.providers.Ev;
const VScreen = vscreen.VScreen;
const Ui = harness.Ui;

/// Render a Ui into a VScreen via the renderer.
fn renderToVs(ui: *Ui, vs: *VScreen) !void {
    var buf: [16384]u8 = undefined;
    var out = BufWriter.init(&buf);
    try ui.draw(&out);
    vs.clear();
    vs.feed(out.view());
}

const BufWriter = struct {
    buf: []u8,
    len: usize = 0,

    fn init(buf: []u8) BufWriter {
        return .{ .buf = buf };
    }

    pub fn writeAll(self: *BufWriter, bytes: []const u8) !void {
        if (self.len + bytes.len > self.buf.len) return error.NoSpaceLeft;
        @memcpy(self.buf[self.len .. self.len + bytes.len], bytes);
        self.len += bytes.len;
    }

    fn view(self: *const BufWriter) []const u8 {
        return self.buf[0..self.len];
    }
};

// Layout helper: reserved = 5 (border + editor + border + 2 footer)
// tx_h = h - 5 for h >= 6

// ── Scenarios ──

test "e2e simple text response" {
    var ui = try Ui.init(std.testing.allocator, 60, 10, "gpt-4", "openai");
    defer ui.deinit();

    try ui.onProvider(.{ .text = "Hello, how can I help?" });
    try ui.onProvider(.{ .usage = .{ .in_tok = 10, .out_tok = 20, .tot_tok = 30 } });
    try ui.onProvider(.{ .stop = .{ .reason = .done } });

    var vs = try VScreen.init(std.testing.allocator, 60, 10);
    defer vs.deinit();
    try renderToVs(&ui, &vs);

    // h=10: tx_h=5 (rows 0..4), border 5, editor 6, border 7, footer 8-9
    var found_text = false;
    var found_stop = false;
    var r: usize = 0;
    while (r < 5) : (r += 1) {
        const row = try vs.rowText(std.testing.allocator, r);
        defer std.testing.allocator.free(row);
        if (std.mem.indexOf(u8, row, "Hello, how can I help?") != null) found_text = true;
        if (std.mem.indexOf(u8, row, "[stop done]") != null) found_stop = true;
    }
    try std.testing.expect(found_text);
    try std.testing.expect(found_stop);
}

test "e2e text + thinking + text" {
    var ui = try Ui.init(std.testing.allocator, 40, 8, "claude", "anthropic");
    defer ui.deinit();

    try ui.onProvider(.{ .text = "Let me think..." });
    try ui.onProvider(.{ .thinking = "analyzing the problem" });
    try ui.onProvider(.{ .text = "Here is my answer." });

    var vs = try VScreen.init(std.testing.allocator, 40, 8);
    defer vs.deinit();
    try renderToVs(&ui, &vs);

    // h=8: tx_h=3 (rows 0..2), border 3, editor 4, border 5, footer 6-7
    // Thinking hidden by default → collapsed "Thinking..." label with italic style
    var found_label = false;
    var r: usize = 0;
    while (r < 3) : (r += 1) {
        const row = try vs.rowText(std.testing.allocator, r);
        defer std.testing.allocator.free(row);
        if (std.mem.indexOf(u8, row, "Thinking...") != null) {
            try vs.expectItalic(r, 1, true);
            try vs.expectFg(r, 1, .{ .rgb = 0x808080 });
            found_label = true;
            break;
        }
    }
    try std.testing.expect(found_label);
    // Full thinking content should NOT appear
    r = 0;
    while (r < 3) : (r += 1) {
        const row = try vs.rowText(std.testing.allocator, r);
        defer std.testing.allocator.free(row);
        try std.testing.expect(std.mem.indexOf(u8, row, "analyzing the problem") == null);
    }
}

test "e2e tool call and result" {
    var ui = try Ui.init(std.testing.allocator, 50, 10, "gpt-4", "openai");
    defer ui.deinit();

    try ui.onProvider(.{ .text = "I'll read the file." });
    try ui.onProvider(.{ .tool_call = .{
        .id = "c1",
        .name = "read",
        .args = "{\"path\":\"main.zig\"}",
    } });
    try ui.onProvider(.{ .tool_result = .{
        .id = "c1",
        .out = "const std = @import(\"std\");",
        .is_err = false,
    } });
    try ui.onProvider(.{ .text = "The file imports std." });

    var vs = try VScreen.init(std.testing.allocator, 50, 10);
    defer vs.deinit();
    try renderToVs(&ui, &vs);

    // h=10: tx_h=5 (rows 0..4)
    // Content at col 1 (padding). Bg fills from col 0.
    var found_tool = false;
    var r: usize = 0;
    while (r < 5) : (r += 1) {
        const row = try vs.rowText(std.testing.allocator, r);
        defer std.testing.allocator.free(row);
        if (std.mem.indexOf(u8, row, "[tool read#c1]") != null) {
            try vs.expectFg(r, 1, .{ .rgb = 0xffff00 }); // theme.warn
            try vs.expectBg(r, 0, .{ .rgb = 0x282832 }); // theme.tool_pending_bg
            found_tool = true;
            break;
        }
    }
    try std.testing.expect(found_tool);

    // Find tool result
    var found_result = false;
    r = 0;
    while (r < 5) : (r += 1) {
        const row = try vs.rowText(std.testing.allocator, r);
        defer std.testing.allocator.free(row);
        if (std.mem.indexOf(u8, row, "[tool-result #c1") != null) {
            try vs.expectFg(r, 1, .{ .rgb = 0xb5bd68 }); // theme.success
            try vs.expectBg(r, 0, .{ .rgb = 0x283228 }); // theme.tool_success_bg
            found_result = true;
            break;
        }
    }
    try std.testing.expect(found_result);
}

test "e2e error response" {
    // Use larger terminal so error fits in transcript area
    var ui = try Ui.init(std.testing.allocator, 40, 8, "m", "p");
    defer ui.deinit();

    try ui.onProvider(.{ .err = "rate limit exceeded" });

    var vs = try VScreen.init(std.testing.allocator, 40, 8);
    defer vs.deinit();
    try renderToVs(&ui, &vs);

    // h=8: tx_h=3 (rows 0..2)
    var found_err = false;
    var r: usize = 0;
    while (r < 3) : (r += 1) {
        const row = try vs.rowText(std.testing.allocator, r);
        defer std.testing.allocator.free(row);
        if (std.mem.indexOf(u8, row, "[err] rate limit exceeded") != null) {
            try vs.expectFg(r, 1, .{ .rgb = 0xcc6666 }); // theme.err
            try vs.expectBold(r, 1, true);
            try vs.expectBg(r, 0, .{ .rgb = 0x3c2828 }); // theme.tool_error_bg
            found_err = true;
            break;
        }
    }
    try std.testing.expect(found_err);
}

test "e2e tool result with ANSI is stripped" {
    var ui = try Ui.init(std.testing.allocator, 50, 8, "m", "p");
    defer ui.deinit();

    try ui.onProvider(.{ .tool_result = .{
        .id = "c1",
        .out = "\x1b[31mred text\x1b[0m normal",
        .is_err = false,
    } });

    var vs = try VScreen.init(std.testing.allocator, 50, 8);
    defer vs.deinit();
    try renderToVs(&ui, &vs);

    // h=8: tx_h=3 (rows 0..2)
    var found_stripped = false;
    var r: usize = 0;
    while (r < 3) : (r += 1) {
        const row = try vs.rowText(std.testing.allocator, r);
        defer std.testing.allocator.free(row);
        // Should not contain raw ESC byte
        try std.testing.expect(std.mem.indexOfScalar(u8, row, 0x1b) == null);
        // Check for stripped content (may be word-wrapped across lines)
        if (std.mem.indexOf(u8, row, "red text") != null or
            std.mem.indexOf(u8, row, "text normal") != null)
            found_stripped = true;
    }
    try std.testing.expect(found_stripped);
}

test "e2e word wrap in narrow terminal" {
    var ui = try Ui.init(std.testing.allocator, 20, 10, "m", "p");
    defer ui.deinit();

    // Text wider than transcript area should wrap
    try ui.onProvider(.{ .text = "hello world this is a long response" });

    var vs = try VScreen.init(std.testing.allocator, 20, 10);
    defer vs.deinit();
    try renderToVs(&ui, &vs);

    // h=10: tx_h=5 (rows 0..4)
    // w=20, 1-col pad → 19 cols for text. "hello world this is a long response" wraps.
    var non_empty: usize = 0;
    var r: usize = 0;
    while (r < 5) : (r += 1) {
        const row = try vs.rowText(std.testing.allocator, r);
        defer std.testing.allocator.free(row);
        if (row.len > 0) non_empty += 1;
    }
    try std.testing.expect(non_empty >= 2);
}

test "e2e multiple parallel tool calls" {
    var ui = try Ui.init(std.testing.allocator, 60, 14, "claude", "anthropic");
    defer ui.deinit();

    try ui.onProvider(.{ .text = "Reading files..." });
    try ui.onProvider(.{ .tool_call = .{ .id = "c1", .name = "read", .args = "{}" } });
    try ui.onProvider(.{ .tool_call = .{ .id = "c2", .name = "write", .args = "{}" } });
    try ui.onProvider(.{ .tool_call = .{ .id = "c3", .name = "bash", .args = "{}" } });
    try ui.onProvider(.{ .tool_result = .{ .id = "c1", .out = "ok", .is_err = false } });
    try ui.onProvider(.{ .tool_result = .{ .id = "c2", .out = "ok", .is_err = false } });
    try ui.onProvider(.{ .tool_result = .{ .id = "c3", .out = "fail", .is_err = true } });
    try ui.onProvider(.{ .text = "Done." });

    var vs = try VScreen.init(std.testing.allocator, 60, 14);
    defer vs.deinit();
    try renderToVs(&ui, &vs);

    // h=14: tx_h=9 (rows 0..8)
    var found_err_result = false;
    var r: usize = 0;
    while (r < 9) : (r += 1) {
        const row = try vs.rowText(std.testing.allocator, r);
        defer std.testing.allocator.free(row);
        if (std.mem.indexOf(u8, row, "[tool-result #c3") != null) {
            try vs.expectFg(r, 1, .{ .rgb = 0xcc6666 }); // theme.err
            try vs.expectBg(r, 0, .{ .rgb = 0x3c2828 }); // theme.tool_error_bg
            found_err_result = true;
            break;
        }
    }
    try std.testing.expect(found_err_result);
}

test "e2e editor border visible" {
    var ui = try Ui.init(std.testing.allocator, 30, 8, "m", "p");
    defer ui.deinit();

    var vs = try VScreen.init(std.testing.allocator, 30, 8);
    defer vs.deinit();
    try renderToVs(&ui, &vs);

    // h=8: tx_h=3, border row 3, editor row 4, border row 5, footer 6-7
    // Border should be ─ (U+2500) in default border_fg (thinking_med / adaptive)
    try vs.expectText(3, 0, "\xe2\x94\x80"); // ─
    try vs.expectFg(3, 0, .{ .rgb = 0x81a2be }); // thinking_med (adaptive default)
    try vs.expectText(5, 0, "\xe2\x94\x80"); // bottom border too
    try vs.expectFg(5, 0, .{ .rgb = 0x81a2be });
}

test "e2e footer visible at bottom" {
    var ui = try Ui.init(std.testing.allocator, 40, 8, "gpt-4", "openai");
    defer ui.deinit();

    try ui.onProvider(.{ .usage = .{ .in_tok = 100, .out_tok = 50, .tot_tok = 150 } });

    var vs = try VScreen.init(std.testing.allocator, 40, 8);
    defer vs.deinit();
    try renderToVs(&ui, &vs);

    // h=8: footer at rows 6-7. Check footer line 2 has (provider) model.
    const row7 = try vs.rowText(std.testing.allocator, 7);
    defer std.testing.allocator.free(row7);
    try std.testing.expect(std.mem.indexOf(u8, row7, "gpt-4") != null);
    try std.testing.expect(std.mem.indexOf(u8, row7, "(openai)") != null);
}
