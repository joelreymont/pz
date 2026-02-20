const std = @import("std");
const core = @import("../../core/mod.zig");
const frame = @import("frame.zig");

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
    usage: core.providers.Usage = .{},
    has_usage: bool = false,
    run_state: RunState = .idle,

    pub const InitError = std.mem.Allocator.Error || error{InvalidUtf8};
    pub const EventError = std.mem.Allocator.Error || error{InvalidUtf8};
    pub const RenderError = frame.Frame.PosError || error{
        InvalidUtf8,
        NoSpaceLeft,
    };

    pub fn init(alloc: std.mem.Allocator, model: []const u8, provider: []const u8) InitError!Panels {
        var out = Panels{
            .alloc = alloc,
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

    pub fn renderTools(self: *const Panels, frm: *frame.Frame, rect: Rect) RenderError!void {
        if (rect.w == 0 or rect.h == 0) return;

        const x_end = try rectEndX(frm, rect);
        _ = try rectEndY(frm, rect);
        try clearRect(frm, rect);

        var head_x = rect.x;
        try writePart(frm, &head_x, x_end, rect.y, "TOOLS", .{
            .fg = .bright_white,
            .bold = true,
        });

        if (rect.h == 1) return;

        const body_h = rect.h - 1;
        const shown = @min(body_h, self.rows.items.len);
        const src_start = self.rows.items.len - shown;
        const dst_start = rect.y + rect.h - shown;

        var row: usize = 0;
        while (row < shown) : (row += 1) {
            try drawToolRow(frm, rect, dst_start + row, self.rows.items[src_start + row]);
        }
    }

    pub fn renderStatus(self: *const Panels, frm: *frame.Frame, rect: Rect) RenderError!void {
        if (rect.w == 0 or rect.h == 0) return;

        const x_end = try rectEndX(frm, rect);
        _ = try rectEndY(frm, rect);
        try clearRect(frm, rect);

        const y = rect.y;
        var x = rect.x;

        const label_st = frame.Style{
            .fg = .bright_black,
        };

        try writePart(frm, &x, x_end, y, "model ", label_st);
        try writePart(frm, &x, x_end, y, self.model.items, .{
            .fg = .cyan,
            .bold = true,
        });

        try writePart(frm, &x, x_end, y, "  provider ", label_st);
        try writePart(frm, &x, x_end, y, self.provider.items, .{
            .fg = .yellow,
            .bold = true,
        });

        try writePart(frm, &x, x_end, y, "  status ", label_st);
        try writePart(frm, &x, x_end, y, runStateText(self.run_state), runStateStyle(self.run_state));

        var tool_buf: [64]u8 = undefined;
        const tool_txt = std.fmt.bufPrint(&tool_buf, "{}/{}", .{
            self.runningCount(),
            self.rows.items.len,
        }) catch |fmt_err| switch (fmt_err) {
            error.NoSpaceLeft => return error.NoSpaceLeft,
        };
        try writePart(frm, &x, x_end, y, "  tools ", label_st);
        try writePart(frm, &x, x_end, y, tool_txt, .{});

        if (self.has_usage) {
            var use_buf: [128]u8 = undefined;
            const use_txt = std.fmt.bufPrint(&use_buf, "{}/{}/{}", .{
                self.usage.in_tok,
                self.usage.out_tok,
                self.usage.tot_tok,
            }) catch |fmt_err| switch (fmt_err) {
                error.NoSpaceLeft => return error.NoSpaceLeft,
            };
            try writePart(frm, &x, x_end, y, "  tok ", label_st);
            try writePart(frm, &x, x_end, y, use_txt, .{
                .fg = .bright_white,
            });
        }

        if (self.run_state == .failed and self.last_err.items.len > 0) {
            try writePart(frm, &x, x_end, y, "  err ", label_st);
            try writePart(frm, &x, x_end, y, self.last_err.items, .{
                .fg = .red,
            });
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

fn drawToolRow(frm: *frame.Frame, rect: Rect, y: usize, row: ToolRow) Panels.RenderError!void {
    const x_end = try rectEndX(frm, rect);
    var x = rect.x;

    try writePart(frm, &x, x_end, y, toolStateText(row.state), toolStateStyle(row.state));
    try writePart(frm, &x, x_end, y, " ", .{});
    try writePart(frm, &x, x_end, y, row.name, .{});
    try writePart(frm, &x, x_end, y, " #", .{
        .fg = .bright_black,
    });
    try writePart(frm, &x, x_end, y, row.id, .{
        .fg = .bright_black,
    });
}

fn toolStateText(st: ToolState) []const u8 {
    return switch (st) {
        .running => "RUN",
        .ok => "OK",
        .failed => "ERR",
    };
}

fn toolStateStyle(st: ToolState) frame.Style {
    return switch (st) {
        .running => .{
            .fg = .yellow,
        },
        .ok => .{
            .fg = .green,
        },
        .failed => .{
            .fg = .red,
            .bold = true,
        },
    };
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
            .fg = .bright_black,
        },
        .streaming => .{
            .fg = .cyan,
        },
        .tool => .{
            .fg = .yellow,
            .bold = true,
        },
        .done => .{
            .fg = .green,
            .bold = true,
        },
        .canceled => .{
            .fg = .magenta,
        },
        .failed => .{
            .fg = .red,
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

test "panels render tool rows with clipping and styles" {
    var ps = try Panels.init(std.testing.allocator, "gpt-x", "prov-a");
    defer ps.deinit();

    try ps.append(.{ .tool_call = .{
        .id = "c1",
        .name = "read",
        .args = "{}",
    } });
    try ps.append(.{ .tool_result = .{
        .id = "c1",
        .out = "ok",
        .is_err = false,
    } });
    try ps.append(.{ .tool_call = .{
        .id = "c2",
        .name = "bash",
        .args = "{}",
    } });
    try ps.append(.{ .tool_call = .{
        .id = "c3",
        .name = "edit",
        .args = "{}",
    } });

    var frm = try frame.Frame.init(std.testing.allocator, 15, 4);
    defer frm.deinit(std.testing.allocator);

    try ps.renderTools(&frm, .{
        .x = 0,
        .y = 0,
        .w = 15,
        .h = 4,
    });

    try expectPrefix(&frm, 0, "TOOLS");
    try expectPrefix(&frm, 1, "OK read #c1");
    try expectPrefix(&frm, 2, "RUN bash #c2");
    try expectPrefix(&frm, 3, "RUN edit #c3");

    const ok_cell = try frm.cell(0, 1);
    try std.testing.expect(ok_cell.style.fg == .green);

    const run_cell = try frm.cell(0, 2);
    try std.testing.expect(run_cell.style.fg == .yellow);
}

test "panels render model status and usage indicators" {
    var ps = try Panels.init(std.testing.allocator, "gpt-5-mini", "claude");
    defer ps.deinit();

    try ps.append(.{ .tool_call = .{
        .id = "call-9",
        .name = "read",
        .args = "{}",
    } });
    try ps.append(.{ .usage = .{
        .in_tok = 10,
        .out_tok = 20,
        .tot_tok = 30,
    } });

    var frm = try frame.Frame.init(std.testing.allocator, 72, 1);
    defer frm.deinit(std.testing.allocator);

    try ps.renderStatus(&frm, .{
        .x = 0,
        .y = 0,
        .w = 72,
        .h = 1,
    });

    var raw: [72]u8 = undefined;
    const row = try rowAscii(&frm, 0, raw[0..]);
    try std.testing.expect(std.mem.indexOf(u8, row, "model gpt-5-mini") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "provider claude") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "status tool") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "tools 1/1") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "tok 10/20/30") != null);

    const model_idx = std.mem.indexOf(u8, row, "gpt-5-mini").?;
    const provider_idx = std.mem.indexOf(u8, row, "claude").?;
    const state_idx = std.mem.indexOf(u8, row, "tool").?;

    const model_cell = try frm.cell(model_idx, 0);
    try std.testing.expect(model_cell.style.fg == .cyan);
    try std.testing.expect(model_cell.style.bold);

    const provider_cell = try frm.cell(provider_idx, 0);
    try std.testing.expect(provider_cell.style.fg == .yellow);
    try std.testing.expect(provider_cell.style.bold);

    const state_cell = try frm.cell(state_idx, 0);
    try std.testing.expect(state_cell.style.fg == .yellow);
    try std.testing.expect(state_cell.style.bold);
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

    try std.testing.expectError(error.OutOfBounds, ps.renderTools(&frm, .{
        .x = 1,
        .y = 0,
        .w = 2,
        .h = 1,
    }));
    try std.testing.expectError(error.OutOfBounds, ps.renderStatus(&frm, .{
        .x = 0,
        .y = 1,
        .w = 1,
        .h = 2,
    }));
}
