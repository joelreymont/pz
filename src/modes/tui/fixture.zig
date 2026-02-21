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

    // Status bar row 0: model name
    try vs.expectText(0, 0, "gpt-4");

    // Find text and stop lines anywhere in body
    var found_text = false;
    var found_stop = false;
    var r: usize = 1;
    while (r < 9) : (r += 1) {
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

    // Thinking should have italic and thinking_fg color
    // Find the thinking line
    var found_thinking = false;
    var r: usize = 1;
    while (r < 7) : (r += 1) {
        const row = try vs.rowText(std.testing.allocator, r);
        defer std.testing.allocator.free(row);
        if (std.mem.indexOf(u8, row, "[thinking]") != null) {
            // Check italic styling
            try vs.expectItalic(r, 0, true);
            // Check fg color matches theme.thinking_fg (rgb 0x808080)
            try vs.expectFg(r, 0, .{ .rgb = 0x808080 });
            found_thinking = true;
            break;
        }
    }
    try std.testing.expect(found_thinking);
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

    // Find tool call line — should have warn fg color and pending bg
    var found_tool = false;
    var r: usize = 1;
    while (r < 9) : (r += 1) {
        const row = try vs.rowText(std.testing.allocator, r);
        defer std.testing.allocator.free(row);
        if (std.mem.indexOf(u8, row, "[tool read#c1]") != null) {
            try vs.expectFg(r, 0, .{ .rgb = 0xffff00 }); // theme.warn
            try vs.expectBg(r, 0, .{ .rgb = 0x282832 }); // theme.tool_pending_bg
            found_tool = true;
            break;
        }
    }
    try std.testing.expect(found_tool);

    // Find tool result — should have success fg and success bg
    var found_result = false;
    r = 1;
    while (r < 9) : (r += 1) {
        const row = try vs.rowText(std.testing.allocator, r);
        defer std.testing.allocator.free(row);
        if (std.mem.indexOf(u8, row, "[tool-result #c1") != null) {
            try vs.expectFg(r, 0, .{ .rgb = 0xb5bd68 }); // theme.success
            try vs.expectBg(r, 0, .{ .rgb = 0x283228 }); // theme.tool_success_bg
            found_result = true;
            break;
        }
    }
    try std.testing.expect(found_result);
}

test "e2e error response" {
    var ui = try Ui.init(std.testing.allocator, 40, 6, "m", "p");
    defer ui.deinit();

    try ui.onProvider(.{ .err = "rate limit exceeded" });

    var vs = try VScreen.init(std.testing.allocator, 40, 6);
    defer vs.deinit();
    try renderToVs(&ui, &vs);

    // Find error line
    var found_err = false;
    var r: usize = 1;
    while (r < 5) : (r += 1) {
        const row = try vs.rowText(std.testing.allocator, r);
        defer std.testing.allocator.free(row);
        if (std.mem.indexOf(u8, row, "[err] rate limit exceeded") != null) {
            try vs.expectFg(r, 0, .{ .rgb = 0xcc6666 }); // theme.err
            try vs.expectBold(r, 0, true);
            try vs.expectBg(r, 0, .{ .rgb = 0x3c2828 }); // theme.tool_error_bg
            found_err = true;
            break;
        }
    }
    try std.testing.expect(found_err);
}

test "e2e tool result with ANSI is stripped" {
    var ui = try Ui.init(std.testing.allocator, 50, 6, "m", "p");
    defer ui.deinit();

    try ui.onProvider(.{ .tool_result = .{
        .id = "c1",
        .out = "\x1b[31mred text\x1b[0m normal",
        .is_err = false,
    } });

    var vs = try VScreen.init(std.testing.allocator, 50, 6);
    defer vs.deinit();
    try renderToVs(&ui, &vs);

    // ANSI should be stripped — text visible without ESC sequences
    var found_stripped = false;
    var r: usize = 1;
    while (r < 5) : (r += 1) {
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
    var ui = try Ui.init(std.testing.allocator, 20, 8, "m", "p");
    defer ui.deinit();

    // Text wider than transcript area should wrap
    try ui.onProvider(.{ .text = "hello world this is a long response" });

    var vs = try VScreen.init(std.testing.allocator, 20, 8);
    defer vs.deinit();
    try renderToVs(&ui, &vs);

    // The transcript area is the left portion (w - tool_w).
    // At w=20: tool_w = splitToolW(20) = max(12, 20/3=6) = 12.
    // But that leaves tx_w = 20-12 = 8. With separator: tool_w = 12-1 = 11.
    // So transcript gets 8 cols. "hello world..." wraps.
    // Just verify no crash and multiple rows have content.
    var non_empty: usize = 0;
    var r: usize = 1;
    while (r < 7) : (r += 1) {
        const row = try vs.rowText(std.testing.allocator, r);
        defer std.testing.allocator.free(row);
        if (row.len > 0) non_empty += 1;
    }
    // With 8-col transcript and ~35 char text, expect at least 4 wrapped lines
    try std.testing.expect(non_empty >= 4);
}

test "e2e multiple parallel tool calls" {
    var ui = try Ui.init(std.testing.allocator, 60, 12, "claude", "anthropic");
    defer ui.deinit();

    try ui.onProvider(.{ .text = "Reading files..." });
    try ui.onProvider(.{ .tool_call = .{ .id = "c1", .name = "read", .args = "{}" } });
    try ui.onProvider(.{ .tool_call = .{ .id = "c2", .name = "write", .args = "{}" } });
    try ui.onProvider(.{ .tool_call = .{ .id = "c3", .name = "bash", .args = "{}" } });
    try ui.onProvider(.{ .tool_result = .{ .id = "c1", .out = "ok", .is_err = false } });
    try ui.onProvider(.{ .tool_result = .{ .id = "c2", .out = "ok", .is_err = false } });
    try ui.onProvider(.{ .tool_result = .{ .id = "c3", .out = "fail", .is_err = true } });
    try ui.onProvider(.{ .text = "Done." });

    var vs = try VScreen.init(std.testing.allocator, 60, 12);
    defer vs.deinit();
    try renderToVs(&ui, &vs);

    // Find the error result — should have error bg
    var found_err_result = false;
    var r: usize = 1;
    while (r < 11) : (r += 1) {
        const row = try vs.rowText(std.testing.allocator, r);
        defer std.testing.allocator.free(row);
        if (std.mem.indexOf(u8, row, "[tool-result #c3") != null) {
            try vs.expectFg(r, 0, .{ .rgb = 0xcc6666 }); // theme.err
            try vs.expectBg(r, 0, .{ .rgb = 0x3c2828 }); // theme.tool_error_bg
            found_err_result = true;
            break;
        }
    }
    try std.testing.expect(found_err_result);
}

test "e2e editor prompt visible" {
    var ui = try Ui.init(std.testing.allocator, 30, 5, "m", "p");
    defer ui.deinit();

    var vs = try VScreen.init(std.testing.allocator, 30, 5);
    defer vs.deinit();
    try renderToVs(&ui, &vs);

    // Last row should have the "> " prompt
    try vs.expectText(4, 0, ">");
    // Prompt should be accent colored and bold
    try vs.expectFg(4, 0, .{ .rgb = 0x8abeb7 }); // theme.accent
    try vs.expectBold(4, 0, true);
}

test "e2e separator between transcript and tools" {
    var ui = try Ui.init(std.testing.allocator, 40, 8, "m", "p");
    defer ui.deinit();

    try ui.onProvider(.{ .tool_call = .{ .id = "c1", .name = "read", .args = "{}" } });

    var vs = try VScreen.init(std.testing.allocator, 40, 8);
    defer vs.deinit();
    try renderToVs(&ui, &vs);

    // At w=40: tool_w = splitToolW(40) = max(12, 40/3=13) = 13.
    // tx_w = 40 - 13 = 27. Separator at col 27.
    // Separator char is U+2502 (│)
    const sep_cell = vs.cellAt(1, 27);
    try std.testing.expectEqual(@as(u21, 0x2502), sep_cell.cp);
    try vs.expectFg(1, 27, .{ .rgb = 0x505050 }); // theme.border_muted
}
