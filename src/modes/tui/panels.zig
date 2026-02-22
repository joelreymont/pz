const std = @import("std");
const core = @import("../../core/mod.zig");
const frame = @import("frame.zig");
const theme = @import("theme.zig");

pub const Rect = struct {
    x: usize,
    y: usize,
    w: usize,
    h: usize,
};

pub const RunState = enum {
    idle,
    streaming,
    tool,
    done,
    canceled,
    failed,
};

pub const ToolState = enum {
    running,
    ok,
    failed,
};

const ToolRow = struct {
    id: []u8,
    name: []u8,
    state: ToolState,
};

pub const ToolView = struct {
    id: []const u8,
    name: []const u8,
    state: ToolState,
};

pub const Panels = struct {
    alloc: std.mem.Allocator,
    rows: std.ArrayListUnmanaged(ToolRow) = .empty,
    model: std.ArrayListUnmanaged(u8) = .empty,
    provider: std.ArrayListUnmanaged(u8) = .empty,
    last_err: std.ArrayListUnmanaged(u8) = .empty,
    cwd: []const u8 = "",
    branch: []const u8 = "",
    usage: core.providers.Usage = .{},
    has_usage: bool = false,
    ctx_limit: u64 = 0,
    run_state: RunState = .idle,
    thinking_label: []const u8 = "",

    pub const InitError = std.mem.Allocator.Error || error{InvalidUtf8};
    pub const EventError = std.mem.Allocator.Error || error{InvalidUtf8};
    pub const RenderError = frame.Frame.PosError || error{
        InvalidUtf8,
        NoSpaceLeft,
    };

    pub fn init(alloc: std.mem.Allocator, model: []const u8, provider: []const u8) InitError!Panels {
        return initFull(alloc, model, provider, "", "");
    }

    pub fn initFull(
        alloc: std.mem.Allocator,
        model: []const u8,
        provider: []const u8,
        cwd: []const u8,
        branch: []const u8,
    ) InitError!Panels {
        var out = Panels{
            .alloc = alloc,
            .cwd = cwd,
            .branch = branch,
        };
        errdefer out.deinit();
        try out.setModel(model);
        try out.setProvider(provider);
        return out;
    }

    pub fn deinit(self: *Panels) void {
        for (self.rows.items) |row| {
            self.alloc.free(row.id);
            self.alloc.free(row.name);
        }
        self.rows.deinit(self.alloc);
        self.model.deinit(self.alloc);
        self.provider.deinit(self.alloc);
        self.last_err.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn setModel(self: *Panels, model: []const u8) EventError!void {
        try ensureUtf8(model);
        try self.model.resize(self.alloc, 0);
        try self.model.appendSlice(self.alloc, model);
    }

    pub fn setProvider(self: *Panels, provider: []const u8) EventError!void {
        try ensureUtf8(provider);
        try self.provider.resize(self.alloc, 0);
        try self.provider.appendSlice(self.alloc, provider);
    }

    pub fn state(self: *const Panels) RunState {
        return self.run_state;
    }

    pub fn modelName(self: *const Panels) []const u8 {
        return self.model.items;
    }

    pub fn providerName(self: *const Panels) []const u8 {
        return self.provider.items;
    }

    pub fn count(self: *const Panels) usize {
        return self.rows.items.len;
    }

    pub fn runningCount(self: *const Panels) usize {
        var ct: usize = 0;
        for (self.rows.items) |row| {
            if (row.state == .running) ct += 1;
        }
        return ct;
    }

    pub fn tool(self: *const Panels, idx: usize) ToolView {
        const row = self.rows.items[idx];
        return .{
            .id = row.id,
            .name = row.name,
            .state = row.state,
        };
    }

    pub fn append(self: *Panels, ev: core.providers.Ev) EventError!void {
        switch (ev) {
            .text, .thinking => {
                if (!isTerminal(self.run_state)) self.run_state = .streaming;
            },
            .tool_call => |tc| {
                try self.upsertCall(tc);
                try self.setErr("");
                self.run_state = .tool;
            },
            .tool_result => |tr| try self.applyResult(tr),
            .usage => |usage| {
                self.usage = usage;
                self.has_usage = true;
            },
            .stop => |stop| self.run_state = mapStop(stop.reason),
            .err => |msg| {
                try self.setErr(msg);
                self.run_state = .failed;
            },
        }
    }

    /// Render 2-line footer matching pi layout:
    ///   Line 1: cwd:branch • state [err]
    ///   Line 2: ↑in ↓out [pct%/Nk]  model
    /// All text dim unless otherwise noted.
    pub fn renderFooter(self: *const Panels, frm: *frame.Frame, rect: Rect) RenderError!void {
        if (rect.w == 0 or rect.h == 0) return;

        const x_end = try rectEndX(frm, rect);
        _ = try rectEndY(frm, rect);
        try clearRect(frm, rect);

        const dim_st = frame.Style{ .fg = theme.get().dim };
        const y1 = rect.y;

        // --- Line 1: cwd (branch) ---
        {
            var x = rect.x;
            if (self.cwd.len > 0) {
                try writePart(frm, &x, x_end, y1, self.cwd, dim_st);
                if (self.branch.len > 0) {
                    try writePart(frm, &x, x_end, y1, " (", dim_st);
                    try writePart(frm, &x, x_end, y1, self.branch, dim_st);
                    try writePart(frm, &x, x_end, y1, ")", dim_st);
                }
            }
        }

        if (rect.h < 2) return;
        const y2 = rect.y + 1;

        // --- Line 2: ↑in ↓out [pct%/Nk]   ...   model ---
        {
            var x = rect.x;

            // Left: usage stats
            if (self.has_usage) {
                try writePart(frm, &x, x_end, y2, "\xe2\x86\x91", dim_st);
                var ib: [16]u8 = undefined;
                const it = fmtBuf(&ib, "{d}", .{self.usage.in_tok}) catch return error.NoSpaceLeft;
                try writePart(frm, &x, x_end, y2, it, dim_st);

                try writePart(frm, &x, x_end, y2, " \xe2\x86\x93", dim_st);
                var ob: [16]u8 = undefined;
                const ot = fmtBuf(&ob, "{d}", .{self.usage.out_tok}) catch return error.NoSpaceLeft;
                try writePart(frm, &x, x_end, y2, ot, dim_st);

                if (self.ctx_limit > 0) {
                    const pct = self.usage.tot_tok * 100 / self.ctx_limit;
                    const pct_fg = if (pct >= 90) theme.get().err else if (pct >= 70) theme.get().warn else theme.get().accent;

                    try writePart(frm, &x, x_end, y2, " ", dim_st);
                    var pb: [8]u8 = undefined;
                    const pt = fmtBuf(&pb, "{d}%", .{pct}) catch return error.NoSpaceLeft;
                    try writePart(frm, &x, x_end, y2, pt, .{ .fg = pct_fg });
                    var lb: [16]u8 = undefined;
                    const lt = fmtBuf(&lb, "/{d}k", .{self.ctx_limit / 1000}) catch return error.NoSpaceLeft;
                    try writePart(frm, &x, x_end, y2, lt, dim_st);
                }
            }

            // Right: model • thinking-level
            const model_text = self.model.items;
            const prov_text = self.provider.items;
            if (model_text.len > 0) {
                // Calculate right-side width
                var right_cols = cpCountSlice(model_text);
                if (prov_text.len > 0)
                    right_cols += cpCountSlice(prov_text) + 3; // "(" + prov + ") "
                if (self.thinking_label.len > 0)
                    right_cols += 3 + self.thinking_label.len; // " • " + label
                if (right_cols < rect.w) {
                    var rx = x_end - right_cols;
                    if (prov_text.len > 0) {
                        try writePart(frm, &rx, x_end, y2, "(", dim_st);
                        try writePart(frm, &rx, x_end, y2, prov_text, dim_st);
                        try writePart(frm, &rx, x_end, y2, ") ", dim_st);
                    }
                    try writePart(frm, &rx, x_end, y2, model_text, dim_st);
                    if (self.thinking_label.len > 0) {
                        try writePart(frm, &rx, x_end, y2, " \xc2\xb7 ", dim_st); // " · "
                        try writePart(frm, &rx, x_end, y2, self.thinking_label, .{ .fg = theme.get().accent });
                    }
                }
            }
        }
    }

    fn setErr(self: *Panels, msg: []const u8) EventError!void {
        try ensureUtf8(msg);
        try self.last_err.resize(self.alloc, 0);
        try self.last_err.appendSlice(self.alloc, msg);
    }

    fn applyResult(self: *Panels, tr: core.providers.ToolResult) EventError!void {
        try ensureUtf8(tr.id);

        const st: ToolState = if (tr.is_err) .failed else .ok;
        if (self.findRow(tr.id)) |idx| {
            self.rows.items[idx].state = st;
            self.moveTail(idx);
        } else {
            _ = try self.pushRow(tr.id, "<unknown>", st);
        }

        if (tr.is_err) {
            try self.setErr(tr.out);
            self.run_state = .failed;
            return;
        }

        if (!isTerminal(self.run_state)) {
            self.run_state = if (self.runningCount() > 0) .tool else .streaming;
        }
    }

    fn upsertCall(self: *Panels, tc: core.providers.ToolCall) EventError!void {
        try ensureUtf8(tc.id);
        try ensureUtf8(tc.name);

        if (self.findRow(tc.id)) |idx| {
            const name = try self.alloc.dupe(u8, tc.name);
            self.alloc.free(self.rows.items[idx].name);
            self.rows.items[idx].name = name;
            self.rows.items[idx].state = .running;
            self.moveTail(idx);
            return;
        }

        _ = try self.pushRow(tc.id, tc.name, .running);
    }

    fn pushRow(self: *Panels, id: []const u8, name: []const u8, st: ToolState) EventError!usize {
        try ensureUtf8(id);
        try ensureUtf8(name);

        const id_copy = try self.alloc.dupe(u8, id);
        errdefer self.alloc.free(id_copy);

        const name_copy = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(name_copy);

        try self.rows.append(self.alloc, .{
            .id = id_copy,
            .name = name_copy,
            .state = st,
        });
        return self.rows.items.len - 1;
    }

    fn findRow(self: *const Panels, id: []const u8) ?usize {
        for (self.rows.items, 0..) |row, idx| {
            if (std.mem.eql(u8, row.id, id)) return idx;
        }
        return null;
    }

    fn moveTail(self: *Panels, idx: usize) void {
        const n = self.rows.items.len;
        if (idx + 1 >= n) return;

        const last = self.rows.items[idx];
        std.mem.copyForwards(ToolRow, self.rows.items[idx .. n - 1], self.rows.items[idx + 1 .. n]);
        self.rows.items[n - 1] = last;
    }
};

fn fmtBuf(buf: []u8, comptime fmt: []const u8, args: anytype) error{NoSpaceLeft}![]const u8 {
    return std.fmt.bufPrint(buf, fmt, args) catch return error.NoSpaceLeft;
}

fn digitCols(n: u64) usize {
    if (n == 0) return 1;
    var v = n;
    var c: usize = 0;
    while (v > 0) : (v /= 10) c += 1;
    return c;
}

fn usageCols(self: *const Panels) usize {
    // ↑N ↓N = 1+digits + 1 + 1+digits
    var c: usize = 0;
    c += 1 + digitCols(self.usage.in_tok); // ↑N (↑ is 1 col)
    c += 1; // space
    c += 1 + digitCols(self.usage.out_tok); // ↓N
    if (self.ctx_limit > 0) {
        const pct = self.usage.tot_tok * 100 / self.ctx_limit;
        c += 1; // space
        c += digitCols(pct) + 1; // N%
        c += 1 + digitCols(self.ctx_limit / 1000) + 1; // /Nk
    }
    return c;
}

fn cpCountSlice(text: []const u8) usize {
    var i: usize = 0;
    var cols: usize = 0;
    while (i < text.len) {
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        i += n;
        cols += 1;
    }
    return cols;
}

fn runStateText(st: RunState) []const u8 {
    return switch (st) {
        .idle => "idle",
        .streaming => "stream",
        .tool => "tool",
        .done => "done",
        .canceled => "canceled",
        .failed => "failed",
    };
}

fn runStateStyle(st: RunState) frame.Style {
    return switch (st) {
        .idle => .{
            .fg = theme.get().dim,
        },
        .streaming => .{
            .fg = theme.get().border_accent,
        },
        .tool => .{
            .fg = theme.get().warn,
            .bold = true,
        },
        .done => .{
            .fg = theme.get().success,
            .bold = true,
        },
        .canceled => .{
            .fg = theme.get().muted,
        },
        .failed => .{
            .fg = theme.get().err,
            .bold = true,
        },
    };
}

fn mapStop(reason: core.providers.StopReason) RunState {
    return switch (reason) {
        .done, .max_out => .done,
        .tool => .tool,
        .canceled => .canceled,
        .err => .failed,
    };
}

fn isTerminal(st: RunState) bool {
    return st == .done or st == .canceled or st == .failed;
}

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

fn writePart(
    frm: *frame.Frame,
    x: *usize,
    x_end: usize,
    y: usize,
    text: []const u8,
    st: frame.Style,
) Panels.RenderError!void {
    if (x.* >= x_end or text.len == 0) return;
    const fit = try clipCols(text, x_end - x.*);
    x.* += try frm.write(x.*, y, fit, st);
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

fn expectPrefix(frm: *const frame.Frame, y: usize, prefix: []const u8) !void {
    var x: usize = 0;
    while (x < prefix.len) : (x += 1) {
        const c = try frm.cell(x, y);
        try std.testing.expectEqual(@as(u21, prefix[x]), c.cp);
    }
}

test "panels track tool lifecycle and state transitions" {
    var ps = try Panels.init(std.testing.allocator, "gpt-4.1", "prov-a");
    defer ps.deinit();

    try std.testing.expect(ps.state() == .idle);
    try std.testing.expectEqual(@as(usize, 0), ps.count());

    try ps.append(.{ .text = "hello" });
    try std.testing.expect(ps.state() == .streaming);

    try ps.append(.{ .tool_call = .{
        .id = "call-1",
        .name = "read",
        .args = "{\"path\":\"a\"}",
    } });
    try std.testing.expect(ps.state() == .tool);
    try std.testing.expectEqual(@as(usize, 1), ps.count());
    try std.testing.expectEqual(@as(usize, 1), ps.runningCount());
    try std.testing.expectEqualStrings("call-1", ps.tool(0).id);
    try std.testing.expectEqualStrings("read", ps.tool(0).name);
    try std.testing.expect(ps.tool(0).state == .running);

    try ps.append(.{ .tool_result = .{
        .id = "call-1",
        .out = "ok",
        .is_err = false,
    } });
    try std.testing.expect(ps.state() == .streaming);
    try std.testing.expectEqual(@as(usize, 0), ps.runningCount());
    try std.testing.expect(ps.tool(0).state == .ok);

    try ps.append(.{ .stop = .{
        .reason = .done,
    } });
    try std.testing.expect(ps.state() == .done);
}

test "panels render 2-line footer with cwd and model" {
    var ps = try Panels.initFull(std.testing.allocator, "gpt-4", "prov", "myproj", "main");
    defer ps.deinit();
    ps.ctx_limit = 200000;

    try ps.append(.{ .usage = .{
        .in_tok = 10,
        .out_tok = 20,
        .tot_tok = 180000,
    } });

    var frm = try frame.Frame.init(std.testing.allocator, 60, 2);
    defer frm.deinit(std.testing.allocator);

    try ps.renderFooter(&frm, .{ .x = 0, .y = 0, .w = 60, .h = 2 });

    // Line 1: "myproj:main" at col 0 with dim color
    try expectPrefix(&frm, 0, "myproj");
    const cwd_cell = try frm.cell(0, 0);
    try std.testing.expect(frame.Color.eql(cwd_cell.style.fg, theme.get().dim));

    // Line 2: model name right-aligned
    // Find 'g' of "gpt-4" on line 2
    var found_model = false;
    var col: usize = 0;
    while (col < 60) : (col += 1) {
        const c = try frm.cell(col, 1);
        if (c.cp == 'g') {
            const c2 = try frm.cell(col + 1, 1);
            if (c2.cp == 'p') {
                found_model = true;
                break;
            }
        }
    }
    try std.testing.expect(found_model);

    // 90% context should use error color
    var pct_col: usize = 59;
    while (pct_col > 0) : (pct_col -= 1) {
        const c = try frm.cell(pct_col, 1);
        if (c.cp == '%') break;
    }
    if (pct_col > 0) {
        const digit = try frm.cell(pct_col - 1, 1);
        try std.testing.expect(frame.Color.eql(digit.style.fg, theme.get().err));
    }
}

test "panels render footer cwd only no branch" {
    var ps = try Panels.initFull(std.testing.allocator, "m", "p", "proj", "");
    defer ps.deinit();

    var frm = try frame.Frame.init(std.testing.allocator, 40, 2);
    defer frm.deinit(std.testing.allocator);

    try ps.renderFooter(&frm, .{ .x = 0, .y = 0, .w = 40, .h = 2 });

    // "proj" at col 0
    try expectPrefix(&frm, 0, "proj");
    const cwd_cell = try frm.cell(0, 0);
    try std.testing.expect(frame.Color.eql(cwd_cell.style.fg, theme.get().dim));

    // No parens at col 4 - should be space (no branch)
    const after = try frm.cell(4, 0);
    try std.testing.expectEqual(@as(u21, ' '), after.cp);
}

test "panels validate utf8 model and event fields" {
    const bad = [_]u8{0xff};
    try std.testing.expectError(error.InvalidUtf8, Panels.init(std.testing.allocator, bad[0..], "ok"));

    var ps = try Panels.init(std.testing.allocator, "ok", "prov");
    defer ps.deinit();

    try std.testing.expectError(error.InvalidUtf8, ps.append(.{ .tool_call = .{
        .id = bad[0..],
        .name = "read",
        .args = "{}",
    } }));
    try std.testing.expectError(error.InvalidUtf8, ps.setModel(bad[0..]));
    try std.testing.expectError(error.InvalidUtf8, ps.setProvider(bad[0..]));
}

test "panels render rejects out of bounds rect" {
    var ps = try Panels.init(std.testing.allocator, "gpt", "prov");
    defer ps.deinit();

    var frm = try frame.Frame.init(std.testing.allocator, 2, 2);
    defer frm.deinit(std.testing.allocator);

    try std.testing.expectError(error.OutOfBounds, ps.renderFooter(&frm, .{
        .x = 0,
        .y = 1,
        .w = 1,
        .h = 2,
    }));
}
