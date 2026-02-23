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
const FrameSnap = struct {
    row0: []const u8,
    row1: []const u8,
    row8: []const u8,
    row9: []const u8,
};

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
    // Usage/stop no longer shown in transcript
    var found_text = false;
    var r: usize = 0;
    while (r < 5) : (r += 1) {
        const row = try vs.rowText(std.testing.allocator, r);
        defer std.testing.allocator.free(row);
        if (std.mem.indexOf(u8, row, "Hello, how can I help?") != null) found_text = true;
    }
    try std.testing.expect(found_text);
}

test "e2e text + thinking + text" {
    // h=10: tx_h=5, enough for 3 blocks + 2 gaps
    var ui = try Ui.init(std.testing.allocator, 40, 10, "claude", "anthropic");
    defer ui.deinit();

    try ui.onProvider(.{ .text = "Let me think..." });
    try ui.onProvider(.{ .thinking = "analyzing the problem" });
    try ui.onProvider(.{ .text = "Here is my answer." });

    var vs = try VScreen.init(std.testing.allocator, 40, 10);
    defer vs.deinit();
    try renderToVs(&ui, &vs);

    // tx_h=5: Let me think (0), gap (1), analyzing (2), gap (3), Here is (4)
    {
        const row = try vs.rowText(std.testing.allocator, 0);
        defer std.testing.allocator.free(row);
        try std.testing.expect(std.mem.indexOf(u8, row, "Let me think") != null);
    }
    {
        const row = try vs.rowText(std.testing.allocator, 2);
        defer std.testing.allocator.free(row);
        try std.testing.expect(std.mem.indexOf(u8, row, "analyzing the problem") != null);
    }
    {
        const row = try vs.rowText(std.testing.allocator, 4);
        defer std.testing.allocator.free(row);
        try std.testing.expect(std.mem.indexOf(u8, row, "Here is my answer") != null);
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
    // Tool call now shows as "$ read main.zig" in dim
    var found_tool = false;
    var r: usize = 0;
    while (r < 5) : (r += 1) {
        const row = try vs.rowText(std.testing.allocator, r);
        defer std.testing.allocator.free(row);
        if (std.mem.indexOf(u8, row, "$ read main.zig") != null) {
            try vs.expectFg(r, 1, .{ .rgb = 0x666666 }); // theme.dim
            found_tool = true;
            break;
        }
    }
    try std.testing.expect(found_tool);

    // Find tool result row
    var found_result = false;
    r = 0;
    while (r < 5) : (r += 1) {
        const row = try vs.rowText(std.testing.allocator, r);
        defer std.testing.allocator.free(row);
        if (std.mem.indexOf(u8, row, "const std") != null) {
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

test "e2e markdown table draws aligned separators" {
    var ui = try Ui.init(std.testing.allocator, 80, 12, "m", "p");
    defer ui.deinit();

    try ui.onProvider(.{ .text = "| Name | Value |\n" ++
        "| --- | --- |\n" ++
        "| a | 1 |\n" ++
        "| longer-name | 12345 |" });

    var vs = try VScreen.init(std.testing.allocator, 80, 12);
    defer vs.deinit();
    try renderToVs(&ui, &vs);

    const S = struct {
        fn borderCols(vs_: *const VScreen, r: usize, out: *[8]usize) usize {
            var n: usize = 0;
            var c: usize = 0;
            while (c < vs_.w) : (c += 1) {
                const cp = vs_.cellAt(r, c).cp;
                const is_border = cp == 0x2502 or // │
                    cp == 0x251C or // ├
                    cp == 0x253C or // ┼
                    cp == 0x2524 or // ┤
                    cp == 0x250C or // ┌
                    cp == 0x252C or // ┬
                    cp == 0x2510 or // ┐
                    cp == 0x2514 or // └
                    cp == 0x2534 or // ┴
                    cp == 0x2518; // ┘
                if (!is_border) continue;
                if (n < out.len) out[n] = c;
                n += 1;
            }
            return n;
        }
    };

    var hcols: [8]usize = undefined;
    var hdr_cols: [8]usize = undefined;
    var d1cols: [8]usize = undefined;
    var d2cols: [8]usize = undefined;
    var bot_cols: [8]usize = undefined;
    const top_n = S.borderCols(&vs, 0, &hcols);
    const hdr_n = S.borderCols(&vs, 1, &hdr_cols);
    const d1n = S.borderCols(&vs, 3, &d1cols);
    const d2n = S.borderCols(&vs, 5, &d2cols);
    const bot_n = S.borderCols(&vs, 6, &bot_cols);

    try std.testing.expectEqual(@as(usize, 3), top_n);
    try std.testing.expectEqual(@as(usize, 3), hdr_n);
    try std.testing.expectEqual(@as(usize, 3), d1n);
    try std.testing.expectEqual(@as(usize, 3), d2n);
    try std.testing.expectEqual(@as(usize, 3), bot_n);

    try std.testing.expectEqual(hcols[0], hdr_cols[0]);
    try std.testing.expectEqual(hcols[1], hdr_cols[1]);
    try std.testing.expectEqual(hcols[2], hdr_cols[2]);
    try std.testing.expectEqual(hcols[0], d1cols[0]);
    try std.testing.expectEqual(hcols[1], d1cols[1]);
    try std.testing.expectEqual(hcols[2], d1cols[2]);
    try std.testing.expectEqual(hcols[0], d2cols[0]);
    try std.testing.expectEqual(hcols[1], d2cols[1]);
    try std.testing.expectEqual(hcols[2], d2cols[2]);
    try std.testing.expectEqual(hcols[0], bot_cols[0]);
    try std.testing.expectEqual(hcols[1], bot_cols[1]);
    try std.testing.expectEqual(hcols[2], bot_cols[2]);

    try std.testing.expectEqual(@as(u21, 0x250C), vs.cellAt(0, hcols[0]).cp); // ┌
    try std.testing.expectEqual(@as(u21, 0x252C), vs.cellAt(0, hcols[1]).cp); // ┬
    try std.testing.expectEqual(@as(u21, 0x2510), vs.cellAt(0, hcols[2]).cp); // ┐
    try std.testing.expectEqual(@as(u21, 0x251C), vs.cellAt(2, hcols[0]).cp); // ├
    try std.testing.expectEqual(@as(u21, 0x253C), vs.cellAt(2, hcols[1]).cp); // ┼
    try std.testing.expectEqual(@as(u21, 0x2524), vs.cellAt(2, hcols[2]).cp); // ┤
    try std.testing.expectEqual(@as(u21, 0x2514), vs.cellAt(6, hcols[0]).cp); // └
    try std.testing.expectEqual(@as(u21, 0x2534), vs.cellAt(6, hcols[1]).cp); // ┴
    try std.testing.expectEqual(@as(u21, 0x2518), vs.cellAt(6, hcols[2]).cp); // ┘

    // Rows keep explicit left/right padding inside each column.
    try std.testing.expectEqual(@as(u21, ' '), vs.cellAt(3, hcols[0] + 1).cp);
    try std.testing.expectEqual(@as(u21, 'a'), vs.cellAt(3, hcols[0] + 2).cp);
    try std.testing.expectEqual(@as(u21, ' '), vs.cellAt(3, hcols[1] - 1).cp);
    try std.testing.expectEqual(@as(u21, ' '), vs.cellAt(3, hcols[1] + 1).cp);
    try std.testing.expectEqual(@as(u21, '1'), vs.cellAt(3, hcols[1] + 2).cp);
    try std.testing.expectEqual(@as(u21, ' '), vs.cellAt(3, hcols[2] - 1).cp);
}

test "golden snapshot deterministic frame text" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap{};

    var ui = try Ui.init(std.testing.allocator, 40, 10, "m", "p");
    defer ui.deinit();
    try ui.onProvider(.{ .text = "hello world" });
    try ui.onProvider(.{ .stop = .{ .reason = .done } });

    var vs = try VScreen.init(std.testing.allocator, 40, 10);
    defer vs.deinit();
    try renderToVs(&ui, &vs);

    const r0_full = try vs.rowText(std.testing.allocator, 0);
    defer std.testing.allocator.free(r0_full);
    const r1_full = try vs.rowText(std.testing.allocator, 1);
    defer std.testing.allocator.free(r1_full);
    const r8_full = try vs.rowText(std.testing.allocator, 8);
    defer std.testing.allocator.free(r8_full);
    const r9_full = try vs.rowText(std.testing.allocator, 9);
    defer std.testing.allocator.free(r9_full);

    const norm = struct {
        fn run(text: []const u8, out: []u8) []const u8 {
            var w: usize = 0;
            var in_space = false;
            for (text) |ch| {
                if (ch == ' ') {
                    if (in_space) continue;
                    in_space = true;
                } else {
                    in_space = false;
                }
                if (w < out.len) {
                    out[w] = ch;
                    w += 1;
                }
            }
            return std.mem.trim(u8, out[0..w], " ");
        }
    };
    var n0: [64]u8 = undefined;
    var n1: [64]u8 = undefined;
    var n8: [64]u8 = undefined;
    var n9: [64]u8 = undefined;
    const snap = FrameSnap{
        .row0 = norm.run(r0_full, n0[0..]),
        .row1 = norm.run(r1_full, n1[0..]),
        .row8 = norm.run(r8_full, n8[0..]),
        .row9 = norm.run(r9_full, n9[0..]),
    };
    try oh.snap(@src(),
        \\modes.tui.fixture.FrameSnap
        \\  .row0: []const u8
        \\    "hello world"
        \\  .row1: []const u8
        \\    ""
        \\  .row8: []const u8
        \\    ""
        \\  .row9: []const u8
        \\    "1 turn m"
    ).expectEqual(snap);
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
    // Error tool result shows error text with err fg and error bg
    var found_err_result = false;
    var r: usize = 0;
    while (r < 9) : (r += 1) {
        const row = try vs.rowText(std.testing.allocator, r);
        defer std.testing.allocator.free(row);
        if (std.mem.indexOf(u8, row, "fail") != null) {
            // Check if this row has error styling
            vs.expectFg(r, 1, .{ .rgb = 0xcc6666 }) catch continue;
            vs.expectBg(r, 0, .{ .rgb = 0x3c2828 }) catch continue;
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

    // h=8: footer at rows 6-7. Check footer line 2 has model.
    const row7 = try vs.rowText(std.testing.allocator, 7);
    defer std.testing.allocator.free(row7);
    try std.testing.expect(std.mem.indexOf(u8, row7, "gpt-4") != null);
}

// ── Golden parity tests ──
// Full-frame style assertions: verify exact fg, bg, bold at each content position

test "golden: text block has default fg, no bg fill" {
    var ui = try Ui.init(std.testing.allocator, 30, 8, "m", "p");
    defer ui.deinit();

    try ui.onProvider(.{ .text = "hello" });

    var vs = try VScreen.init(std.testing.allocator, 30, 8);
    defer vs.deinit();
    try renderToVs(&ui, &vs);

    // h=8: tx_h=3 (rows 0..2). Text at row 0, col 1 (1-col padding).
    try vs.expectText(0, 1, "hello");
    try vs.expectFg(0, 1, .{ .default = {} }); // theme.text = default
    try vs.expectBg(0, 1, .{ .default = {} }); // no bg for text
    try vs.expectBg(0, 0, .{ .default = {} }); // padding col also default
}

test "golden: tool_call has dim fg with pending bg fill" {
    var ui = try Ui.init(std.testing.allocator, 30, 8, "m", "p");
    defer ui.deinit();

    try ui.onProvider(.{ .tool_call = .{ .id = "c1", .name = "read", .args = "{}" } });

    var vs = try VScreen.init(std.testing.allocator, 30, 8);
    defer vs.deinit();
    try renderToVs(&ui, &vs);

    // Find the tool row — now shows "$ read"
    var tool_row: ?usize = null;
    var r: usize = 0;
    while (r < 3) : (r += 1) {
        const row = try vs.rowText(std.testing.allocator, r);
        defer std.testing.allocator.free(row);
        if (std.mem.indexOf(u8, row, "$ read") != null) {
            tool_row = r;
            break;
        }
    }
    try std.testing.expect(tool_row != null);
    const tr = tool_row.?;

    // Content fg = dim
    try vs.expectFg(tr, 1, .{ .rgb = 0x666666 });
    // Pending bg fill across row
    try vs.expectBg(tr, 0, .{ .rgb = 0x282832 });
}

test "golden: tool_result success has readable fg with success bg" {
    var ui = try Ui.init(std.testing.allocator, 40, 8, "m", "p");
    defer ui.deinit();

    try ui.onProvider(.{ .tool_result = .{ .id = "c1", .out = "ok", .is_err = false } });

    var vs = try VScreen.init(std.testing.allocator, 40, 8);
    defer vs.deinit();
    try renderToVs(&ui, &vs);

    // Tool results use default fg over success background
    var result_row: ?usize = null;
    var r: usize = 0;
    while (r < 3) : (r += 1) {
        const row = try vs.rowText(std.testing.allocator, r);
        defer std.testing.allocator.free(row);
        if (std.mem.indexOf(u8, row, "ok") != null) {
            result_row = r;
            break;
        }
    }
    try std.testing.expect(result_row != null);
    const rr = result_row.?;

    try vs.expectFg(rr, 1, .{ .default = {} }); // tool_output/default
    try vs.expectBg(rr, 1, .{ .rgb = 0x283228 }); // success bg
}

test "golden: error block has err fg, bold, and error bg full row" {
    var ui = try Ui.init(std.testing.allocator, 30, 8, "m", "p");
    defer ui.deinit();

    try ui.onProvider(.{ .err = "fail" });

    var vs = try VScreen.init(std.testing.allocator, 30, 8);
    defer vs.deinit();
    try renderToVs(&ui, &vs);

    var err_row: ?usize = null;
    var r: usize = 0;
    while (r < 3) : (r += 1) {
        const row = try vs.rowText(std.testing.allocator, r);
        defer std.testing.allocator.free(row);
        if (std.mem.indexOf(u8, row, "[err] fail") != null) {
            err_row = r;
            break;
        }
    }
    try std.testing.expect(err_row != null);
    const er = err_row.?;

    try vs.expectFg(er, 1, .{ .rgb = 0xcc6666 }); // err
    try vs.expectBold(er, 1, true); // bold
    try vs.expectBg(er, 0, .{ .rgb = 0x3c2828 }); // error bg
    try vs.expectBg(er, 29, .{ .rgb = 0x3c2828 }); // last col
}

test "golden: user message has user_msg_bg full row" {
    var ui = try Ui.init(std.testing.allocator, 30, 8, "m", "p");
    defer ui.deinit();

    try ui.tr.userText("my prompt");

    var vs = try VScreen.init(std.testing.allocator, 30, 8);
    defer vs.deinit();
    try renderToVs(&ui, &vs);

    var user_row: ?usize = null;
    var r: usize = 0;
    while (r < 3) : (r += 1) {
        const row = try vs.rowText(std.testing.allocator, r);
        defer std.testing.allocator.free(row);
        if (std.mem.indexOf(u8, row, "my prompt") != null) {
            user_row = r;
            break;
        }
    }
    try std.testing.expect(user_row != null);
    const ur = user_row.?;

    try vs.expectBg(ur, 0, .{ .rgb = 0x343541 }); // user_msg_bg
    try vs.expectBg(ur, 29, .{ .rgb = 0x343541 }); // last col
}

test "golden: footer fg matches dim color" {
    var ui = try Ui.initFull(std.testing.allocator, 40, 8, "claude", "anthropic", "/tmp", "main", null);
    defer ui.deinit();

    var vs = try VScreen.init(std.testing.allocator, 40, 8);
    defer vs.deinit();
    try renderToVs(&ui, &vs);

    // Footer at rows 6-7. Line 1 (row 6) has cwd in dim.
    try vs.expectFg(6, 0, .{ .rgb = 0x666666 }); // dim
    // Footer line 2 has right-aligned model; find it
    const row7 = try vs.rowText(std.testing.allocator, 7);
    defer std.testing.allocator.free(row7);
    try std.testing.expect(std.mem.indexOf(u8, row7, "claude") != null);
}

test "golden: wide CJK in editor clips correctly" {
    var ui = try Ui.init(std.testing.allocator, 10, 6, "m", "p");
    defer ui.deinit();

    // Type wide CJK characters
    _ = try ui.ed.apply(.{ .char = 0x4E2D }); // 中 (width 2)
    _ = try ui.ed.apply(.{ .char = 0x6587 }); // 文 (width 2)
    _ = try ui.ed.apply(.{ .char = 'A' });

    var vs = try VScreen.init(std.testing.allocator, 10, 6);
    defer vs.deinit();
    try renderToVs(&ui, &vs);

    // Editor at row 1 (tx_h=1 for h=6, border=0, editor=1, border=2, footer=3-4... no)
    // h=6: reserved=5 → tx_h=1. Border row 1, editor row 2, border row 3, footer 4-5.
    const editor_row = 2;
    const row = try vs.rowText(std.testing.allocator, editor_row);
    defer std.testing.allocator.free(row);
    // Editor has 1-col padding, then "中文A" = 2+2+1 = 5 cols
    try std.testing.expect(std.mem.indexOf(u8, row, "A") != null);
}
