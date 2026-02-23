const std = @import("std");
const core = @import("../../core/mod.zig");
const frame = @import("frame.zig");
const theme = @import("theme.zig");
const spinner = @import("spinner.zig");

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

pub const InputMode = enum {
    steering,
    queue,
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
    cost_micents: u64 = 0, // cumulative cost in 1/100000 of a dollar
    cum_tok: u64 = 0, // latest turn tokens for context gauge
    tot_in: u64 = 0,
    tot_out: u64 = 0,
    tot_cr: u64 = 0,
    tot_cw: u64 = 0,
    ctx_limit: u64 = 0,
    run_state: RunState = .idle,
    turns: u32 = 0,
    compaction_until_ms: i64 = 0,
    bg_launched: u32 = 0,
    bg_running: u32 = 0,
    bg_done: u32 = 0,
    bg_spin: u8 = 0,
    input_mode: InputMode = .steering,
    queued_msgs: u32 = 0,
    thinking_label: []const u8 = "",
    is_sub: bool = false, // subscription (vs pay-per-token)

    pub const InitError = std.mem.Allocator.Error || error{InvalidUtf8};
    pub const EventError = std.mem.Allocator.Error || error{InvalidUtf8};
    pub const RenderError = frame.Frame.PosError || error{
        InvalidUtf8,
        NoSpaceLeft,
    };
    pub const compaction_indicator_ms: i64 = 2500;

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

    pub fn setBgStatus(self: *Panels, launched: u32, running: u32, done: u32) void {
        self.bg_launched = launched;
        self.bg_running = running;
        self.bg_done = done;
    }

    pub fn setInputStatus(self: *Panels, mode: InputMode, queued: u32) void {
        self.input_mode = mode;
        self.queued_msgs = queued;
    }

    pub fn tickBgSpinner(self: *Panels) void {
        if (self.bg_running == 0) return;
        self.bg_spin +%= 1;
    }

    pub fn noteCompaction(self: *Panels) void {
        self.noteCompactionAt(std.time.milliTimestamp());
    }

    pub fn compactionActive(self: *Panels, now_ms: i64) bool {
        if (self.compaction_until_ms == 0) return false;
        if (now_ms >= self.compaction_until_ms) {
            self.compaction_until_ms = 0;
            return false;
        }
        return true;
    }

    fn noteCompactionAt(self: *Panels, now_ms: i64) void {
        self.compaction_until_ms = now_ms + compaction_indicator_ms;
    }

    pub fn resetSessionView(self: *Panels) void {
        for (self.rows.items) |row| {
            self.alloc.free(row.id);
            self.alloc.free(row.name);
        }
        self.rows.items.len = 0;
        self.last_err.items.len = 0;
        self.usage = .{};
        self.has_usage = false;
        self.cost_micents = 0;
        self.cum_tok = 0;
        self.tot_in = 0;
        self.tot_out = 0;
        self.tot_cr = 0;
        self.tot_cw = 0;
        self.run_state = .idle;
        self.turns = 0;
        self.compaction_until_ms = 0;
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
                self.cost_micents +|= calcCost(self.model.items, usage);
                self.cum_tok = usage.tot_tok;
                self.tot_in +|= usage.in_tok;
                self.tot_out +|= usage.out_tok;
                self.tot_cr +|= usage.cache_read;
                self.tot_cw +|= usage.cache_write;
                self.usage = usage;
                self.has_usage = true;
            },
            .stop => |stop| {
                self.run_state = mapStop(stop.reason);
                if (stop.reason == .done or stop.reason == .max_out) self.turns += 1;
            },
            .err => |msg| {
                try self.setErr(msg);
                self.run_state = .failed;
            },
        }
    }

    /// Render footer matching pi layout:
    ///   Line 1: dim(cwd (branch))
    ///   Line 2: dim(↓in ↑out Rcache Wcache $0.05 (sub) 2.9%/200k)  dim(model • thinking)
    pub fn renderFooter(self: *const Panels, frm: *frame.Frame, rect: Rect) RenderError!void {
        if (rect.w == 0 or rect.h == 0) return;

        const x_end = try rectEndX(frm, rect);
        _ = try rectEndY(frm, rect);
        try clearRect(frm, rect);

        const dim_st = frame.Style{ .fg = theme.get().dim };
        const y1 = rect.y;

        // --- Line 1: dim(project path + branch) ---
        {
            var x = rect.x;
            if (self.branch.len == 0) {
                if (self.cwd.len > 0) try writePart(frm, &x, x_end, y1, self.cwd, dim_st);
            } else {
                const branch_cols = cpCountSlice(self.branch) + 2; // "(" + branch + ")"
                const has_cwd = self.cwd.len > 0;
                const sep_cols: usize = if (has_cwd) 1 else 0;
                const reserve_cols = branch_cols + sep_cols;
                if (reserve_cols >= rect.w) {
                    // Extremely narrow terminal: render branch only.
                    try writePart(frm, &x, x_end, y1, "(", dim_st);
                    try writePart(frm, &x, x_end, y1, self.branch, dim_st);
                    try writePart(frm, &x, x_end, y1, ")", dim_st);
                } else {
                    var path_text = self.cwd;
                    const path_cols = cpCountSlice(path_text);
                    const max_path_cols = rect.w - reserve_cols;
                    if (path_cols > max_path_cols) path_text = try clipLeftCols(path_text, max_path_cols);
                    if (path_text.len > 0) {
                        try writePart(frm, &x, x_end, y1, path_text, dim_st);
                        try writePart(frm, &x, x_end, y1, " ", dim_st);
                    }
                    try writePart(frm, &x, x_end, y1, "(", dim_st);
                    try writePart(frm, &x, x_end, y1, self.branch, dim_st);
                    try writePart(frm, &x, x_end, y1, ")", dim_st);
                }
            }
        }

        if (rect.h < 2) return;
        const y2 = rect.y + 1;

        // --- Line 2: stats on left, model on right ---
        {
            var x = rect.x;

            // Left: turn count + usage stats

            if (self.has_usage) {
                try writePart(frm, &x, x_end, y2, "\xe2\x86\x93", dim_st); // ↓
                var ib: [16]u8 = undefined;
                const it = fmtCompact(&ib, self.tot_in) catch return error.NoSpaceLeft;
                try writePart(frm, &x, x_end, y2, it, dim_st);

                try writePart(frm, &x, x_end, y2, " \xe2\x86\x91", dim_st); // ↑
                var ob: [16]u8 = undefined;
                const ot = fmtCompact(&ob, self.tot_out) catch return error.NoSpaceLeft;
                try writePart(frm, &x, x_end, y2, ot, dim_st);

                // Cache read/write tokens (pi-style: R/W)
                if (self.tot_cr > 0) {
                    try writePart(frm, &x, x_end, y2, " R", dim_st);
                    var rb: [16]u8 = undefined;
                    const rt = fmtCompact(&rb, self.tot_cr) catch return error.NoSpaceLeft;
                    try writePart(frm, &x, x_end, y2, rt, dim_st);
                }
                if (self.tot_cw > 0) {
                    try writePart(frm, &x, x_end, y2, " W", dim_st);
                    var wb: [16]u8 = undefined;
                    const wt = fmtCompact(&wb, self.tot_cw) catch return error.NoSpaceLeft;
                    try writePart(frm, &x, x_end, y2, wt, dim_st);
                }

                // Cost: $N.NNN
                if (self.cost_micents > 0) {
                    var cb: [16]u8 = undefined;
                    const ct = fmtCost(&cb, self.cost_micents) catch return error.NoSpaceLeft;
                    try writePart(frm, &x, x_end, y2, " $", dim_st);
                    try writePart(frm, &x, x_end, y2, ct, dim_st);
                }
                // Subscription indicator
                if (self.is_sub) {
                    try writePart(frm, &x, x_end, y2, " (sub)", dim_st);
                }

                if (self.ctx_limit > 0) {
                    // Decimal percent: N.N%
                    const pct_x10 = self.cum_tok *| 1000 / self.ctx_limit;
                    const pct = pct_x10 / 10;
                    const pct_fg = if (pct >= 90) theme.get().err else if (pct >= 70) theme.get().warn else theme.get().accent;

                    try writePart(frm, &x, x_end, y2, " ", dim_st);
                    var pb: [16]u8 = undefined;
                    const pt = fmtBuf(&pb, "{d}.{d}%", .{ pct_x10 / 10, pct_x10 % 10 }) catch return error.NoSpaceLeft;
                    try writePart(frm, &x, x_end, y2, pt, .{ .fg = pct_fg });
                    var lb: [16]u8 = undefined;
                    const lt = fmtBuf(&lb, "/{d}k", .{self.ctx_limit / 1000}) catch return error.NoSpaceLeft;
                    try writePart(frm, &x, x_end, y2, lt, dim_st);
                }
            } else if (self.ctx_limit > 0) {
                // No usage yet — show 0.0%/Nk
                try writePart(frm, &x, x_end, y2, "0.0%", dim_st);
                var lb: [16]u8 = undefined;
                const lt = fmtBuf(&lb, "/{d}k", .{self.ctx_limit / 1000}) catch return error.NoSpaceLeft;
                try writePart(frm, &x, x_end, y2, lt, dim_st);
            }

            if (self.bg_launched > 0) {
                try writePart(frm, &x, x_end, y2, " bg L", dim_st);
                var lbuf: [16]u8 = undefined;
                const ltxt = fmtBuf(&lbuf, "{d}", .{self.bg_launched}) catch return error.NoSpaceLeft;
                try writePart(frm, &x, x_end, y2, ltxt, dim_st);
                try writePart(frm, &x, x_end, y2, " R", dim_st);
                var rbuf: [16]u8 = undefined;
                const rtxt = fmtBuf(&rbuf, "{d}", .{self.bg_running}) catch return error.NoSpaceLeft;
                try writePart(frm, &x, x_end, y2, rtxt, dim_st);
                try writePart(frm, &x, x_end, y2, " D", dim_st);
                var dbuf: [16]u8 = undefined;
                const dtxt = fmtBuf(&dbuf, "{d}", .{self.bg_done}) catch return error.NoSpaceLeft;
                try writePart(frm, &x, x_end, y2, dtxt, dim_st);
                if (self.bg_running > 0) {
                    var sbuf: [4]u8 = undefined;
                    try writePart(frm, &x, x_end, y2, " ", dim_st);
                    try writePart(frm, &x, x_end, y2, spinner.utf8(self.bg_spin, &sbuf), dim_st);
                }
            }
            if (self.turns > 0) {
                var tb: [16]u8 = undefined;
                const tt = fmtBuf(&tb, "{d}", .{self.turns}) catch return error.NoSpaceLeft;
                try writePart(frm, &x, x_end, y2, " ", dim_st);
                try writePart(frm, &x, x_end, y2, tt, dim_st);
                try writePart(frm, &x, x_end, y2, if (self.turns == 1) " turn" else " turns", dim_st);
            }

            // Right: model • thinking-level
            const model_text = self.model.items;
            if (model_text.len > 0) {
                var right_cols = cpCountSlice(model_text);
                if (self.thinking_label.len > 0)
                    right_cols += 3 + self.thinking_label.len; // " • " + label
                if (right_cols < rect.w) {
                    var rx = x_end - right_cols;
                    if (rx > x) {
                        try writePart(frm, &rx, x_end, y2, model_text, dim_st);
                        if (self.thinking_label.len > 0) {
                            try writePart(frm, &rx, x_end, y2, " \xe2\x80\xa2 ", dim_st); // " • "
                            try writePart(frm, &rx, x_end, y2, self.thinking_label, .{ .fg = theme.get().accent });
                        }
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

/// Cost in micents (1/100000 $) from usage + model name.
/// Prices per million tokens: opus in=$15 out=$75, sonnet in=$3 out=$15, haiku in=$0.80 out=$4.
/// Cache read: opus=$1.50, sonnet=$0.30, haiku=$0.08. Cache write: opus=$18.75, sonnet=$3.75, haiku=$1.00.
/// Returns micents to add to cumulative total.
fn calcCost(model: []const u8, u: core.providers.Usage) u64 {
    // Detect model tier from name substring
    const Rates = struct { in: u64, out: u64, cr: u64, cw: u64 };
    const rates: Rates = if (std.mem.indexOf(u8, model, "opus") != null)
        .{ .in = 1500, .out = 7500, .cr = 150, .cw = 1875 }
    else if (std.mem.indexOf(u8, model, "haiku") != null)
        .{ .in = 80, .out = 400, .cr = 8, .cw = 100 }
    else // sonnet or unknown → sonnet rates
        .{ .in = 300, .out = 1500, .cr = 30, .cw = 375 };

    // rates in cents/MTok. micents = tokens * cents / MTok * (100000/100) = tokens * rate / 1000
    // Use saturating math to prevent overflow on extreme token counts
    return (u.in_tok *| rates.in +| u.out_tok *| rates.out +| u.cache_read *| rates.cr +| u.cache_write *| rates.cw) / 1000;
}

/// Format micents as "N.NNN" (dollars with 3 decimal places).
fn fmtCost(buf: []u8, micents: u64) error{NoSpaceLeft}![]const u8 {
    const dollars = micents / 100_000;
    const frac = (micents % 100_000) / 100; // 3 decimal places
    return fmtBuf(buf, "{d}.{d:0>3}", .{ dollars, frac });
}

/// Format token count compactly: 500, 1.2k, 45k, 1.5M
fn fmtCompact(buf: []u8, n: u64) error{NoSpaceLeft}![]const u8 {
    if (n >= 1_000_000) {
        return fmtBuf(buf, "{d}.{d}M", .{ n / 1_000_000, (n % 1_000_000) / 100_000 });
    } else if (n >= 1000) {
        return fmtBuf(buf, "{d}.{d}k", .{ n / 1000, (n % 1000) / 100 });
    } else {
        return fmtBuf(buf, "{d}", .{n});
    }
}

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
    // RN WN = 1+digits + 2 + digits
    var c: usize = 0;
    c += 1 + digitCols(self.usage.in_tok); // RN
    c += 2 + digitCols(self.usage.out_tok); // WN (with leading " W")
    if (self.ctx_limit > 0) {
        const pct = self.cum_tok *| 100 / self.ctx_limit;
        c += 1; // space
        c += digitCols(pct) + 1; // N%
        c += 1 + digitCols(self.ctx_limit / 1000) + 1; // /Nk
    }
    return c;
}

fn cpCountSlice(text: []const u8) usize {
    const wc = @import("wcwidth.zig");
    return wc.strwidth(text);
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
    const wc = @import("wcwidth.zig");

    var i: usize = 0;
    var used: usize = 0;
    while (i < text.len) {
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch return error.InvalidUtf8;
        if (i + n > text.len) return error.InvalidUtf8;
        const cp = std.unicode.utf8Decode(text[i .. i + n]) catch return error.InvalidUtf8;
        const w = wc.wcwidth(cp);
        if (used + w > cols) break;
        i += n;
        used += w;
    }
    return text[0..i];
}

fn clipLeftCols(text: []const u8, cols: usize) error{InvalidUtf8}![]const u8 {
    if (cols == 0 or text.len == 0) return text[0..0];
    const wc = @import("wcwidth.zig");

    const total = cpCountSlice(text);
    if (total <= cols) return text;
    const skip = total - cols;

    var i: usize = 0;
    var used: usize = 0;
    while (i < text.len and used < skip) {
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch return error.InvalidUtf8;
        if (i + n > text.len) return error.InvalidUtf8;
        const cp = std.unicode.utf8Decode(text[i .. i + n]) catch return error.InvalidUtf8;
        used += wc.wcwidth(cp);
        i += n;
    }
    return text[i..];
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
    try std.testing.expectEqual(@as(u32, 1), ps.turns);
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

    // Line 1: "myproj (main)" with dim color
    try expectPrefix(&frm, 0, "myproj");
    const cwd_cell = try frm.cell(0, 0);
    try std.testing.expect(frame.Color.eql(cwd_cell.style.fg, theme.get().dim));
    try std.testing.expect(findAsciiSeq(&frm, 0, "(main)"));

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

test "panels footer keeps branch visible with long path" {
    var ps = try Panels.initFull(std.testing.allocator, "m", "p", "/Users/joel/Work/really/long/project/path", "main");
    defer ps.deinit();

    var frm = try frame.Frame.init(std.testing.allocator, 24, 2);
    defer frm.deinit(std.testing.allocator);

    try ps.renderFooter(&frm, .{ .x = 0, .y = 0, .w = 24, .h = 2 });
    try std.testing.expect(findAsciiSeq(&frm, 0, "(main)"));
}

test "panels footer shows initial 0.0%" {
    var ps = try Panels.initFull(std.testing.allocator, "claude", "anthropic", "~/proj", "");
    defer ps.deinit();
    ps.ctx_limit = 200000;

    var frm = try frame.Frame.init(std.testing.allocator, 60, 2);
    defer frm.deinit(std.testing.allocator);

    try ps.renderFooter(&frm, .{ .x = 0, .y = 0, .w = 60, .h = 2 });

    var buf: [60]u8 = undefined;
    const row = try rowAscii(&frm, 1, buf[0..]);
    // Should have 0.0% and never show the old auto badge in footer.
    try std.testing.expect(std.mem.indexOf(u8, row, "0.0%") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "(auto)") == null);
}

test "panels footer uses pi style R/W cache labels" {
    var ps = try Panels.initFull(std.testing.allocator, "claude-sonnet-4-6", "anthropic", "", "");
    defer ps.deinit();

    try ps.append(.{ .usage = .{
        .in_tok = 1200,
        .out_tok = 345,
        .tot_tok = 1545,
        .cache_read = 5500,
        .cache_write = 1200,
    } });

    var frm = try frame.Frame.init(std.testing.allocator, 90, 2);
    defer frm.deinit(std.testing.allocator);
    try ps.renderFooter(&frm, .{ .x = 0, .y = 0, .w = 90, .h = 2 });

    try std.testing.expect(findAsciiSeq(&frm, 1, " R5.5k"));
    try std.testing.expect(findAsciiSeq(&frm, 1, " W1.2k"));
    try std.testing.expect(!findAsciiSeq(&frm, 1, " CR"));
    try std.testing.expect(!findAsciiSeq(&frm, 1, " CW"));
}

test "panels footer accumulates token totals across usage events" {
    var ps = try Panels.initFull(std.testing.allocator, "claude-sonnet-4-6", "anthropic", "", "");
    defer ps.deinit();

    try ps.append(.{ .usage = .{
        .in_tok = 1500,
        .out_tok = 800,
        .tot_tok = 2300,
        .cache_read = 300,
        .cache_write = 100,
    } });
    try ps.append(.{ .usage = .{
        .in_tok = 500,
        .out_tok = 200,
        .tot_tok = 700,
        .cache_read = 700,
        .cache_write = 900,
    } });

    var frm = try frame.Frame.init(std.testing.allocator, 100, 2);
    defer frm.deinit(std.testing.allocator);
    try ps.renderFooter(&frm, .{ .x = 0, .y = 0, .w = 100, .h = 2 });

    // cumulative: in=2.0k out=1.0k R1.0k W1.0k
    try std.testing.expect(hasCp(&frm, 1, 0x2193)); // ↓
    try std.testing.expect(hasCp(&frm, 1, 0x2191)); // ↑
    try std.testing.expect(findAsciiSeq(&frm, 1, "2.0k"));
    try std.testing.expect(findAsciiSeq(&frm, 1, "1.0k"));
    try std.testing.expect(findAsciiSeq(&frm, 1, " R1.0k"));
    try std.testing.expect(findAsciiSeq(&frm, 1, " W1.0k"));
}

test "panels compaction indicator expires" {
    var ps = try Panels.initFull(std.testing.allocator, "m", "p", "", "");
    defer ps.deinit();

    const t0 = std.time.milliTimestamp();
    try std.testing.expect(!ps.compactionActive(t0));

    ps.noteCompactionAt(t0);
    try std.testing.expect(ps.compactionActive(t0));
    try std.testing.expect(ps.compactionActive(t0 + Panels.compaction_indicator_ms - 1));
    try std.testing.expect(!ps.compactionActive(t0 + Panels.compaction_indicator_ms));
    try std.testing.expect(!ps.compactionActive(t0 + Panels.compaction_indicator_ms + 1));
}

fn findAsciiSeq(frm: *const frame.Frame, y: usize, needle: []const u8) bool {
    if (needle.len == 0) return true;
    var x: usize = 0;
    while (x + needle.len <= frm.w) : (x += 1) {
        var ok = true;
        for (needle, 0..) |ch, j| {
            const c = frm.cell(x + j, y) catch return false;
            if (c.cp != @as(u21, ch)) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

fn firstSpinnerCp(frm: *const frame.Frame, y: usize) ?u21 {
    var x: usize = 0;
    while (x < frm.w) : (x += 1) {
        const c = frm.cell(x, y) catch return null;
        for (spinner.chars) |sp| {
            if (c.cp == sp) return c.cp;
        }
    }
    return null;
}

fn hasCp(frm: *const frame.Frame, y: usize, needle: u21) bool {
    var x: usize = 0;
    while (x < frm.w) : (x += 1) {
        const c = frm.cell(x, y) catch return false;
        if (c.cp == needle) return true;
    }
    return false;
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

test "calcCost opus pricing" {
    const u = core.providers.Usage{ .in_tok = 1_000_000, .out_tok = 1_000_000 };
    // opus: $15/MTok in + $75/MTok out = $90 = 9_000_000 micents
    const cost = calcCost("claude-opus-4-6", u);
    try std.testing.expectEqual(@as(u64, 9_000_000), cost);
}

test "calcCost sonnet pricing" {
    const u = core.providers.Usage{ .in_tok = 1_000_000, .out_tok = 1_000_000 };
    // sonnet: $3/MTok in + $15/MTok out = $18 = 1_800_000 micents
    const cost = calcCost("claude-sonnet-4-6", u);
    try std.testing.expectEqual(@as(u64, 1_800_000), cost);
}

test "calcCost includes cache_write" {
    const u = core.providers.Usage{ .in_tok = 0, .out_tok = 0, .cache_write = 1_000_000 };
    // sonnet cache_write: $3.75/MTok = 375 cents = 375_000 micents
    const cost = calcCost("claude-sonnet-4-6", u);
    try std.testing.expectEqual(@as(u64, 375_000), cost);
}

test "fmtCost formats dollars" {
    var buf: [16]u8 = undefined;
    // 4_600 micents = $0.046
    const r1 = try fmtCost(&buf, 4_600);
    try std.testing.expectEqualStrings("0.046", r1);
    // 3_000_000 micents = $30.000
    const r2 = try fmtCost(&buf, 3_000_000);
    try std.testing.expectEqualStrings("30.000", r2);
}

test "panels footer shows cost and sub" {
    var ps = try Panels.initFull(std.testing.allocator, "claude-opus-4-6", "anthropic", "~/proj", "main");
    defer ps.deinit();
    ps.ctx_limit = 200000;
    ps.is_sub = true;

    try ps.append(.{ .usage = .{ .in_tok = 1000, .out_tok = 200, .tot_tok = 1200 } });

    var frm = try frame.Frame.init(std.testing.allocator, 80, 2);
    defer frm.deinit(std.testing.allocator);
    try ps.renderFooter(&frm, .{ .x = 0, .y = 0, .w = 80, .h = 2 });

    // Should have "$" and "(sub)" in line 2
    try std.testing.expect(findAsciiSeq(&frm, 1, "$"));
    try std.testing.expect(findAsciiSeq(&frm, 1, "(sub)"));
}

test "panels footer shows turn count" {
    var ps = try Panels.initFull(std.testing.allocator, "m", "p", "", "");
    defer ps.deinit();
    ps.turns = 5;

    var frm = try frame.Frame.init(std.testing.allocator, 40, 2);
    defer frm.deinit(std.testing.allocator);
    try ps.renderFooter(&frm, .{ .x = 0, .y = 0, .w = 40, .h = 2 });

    try std.testing.expect(findAsciiSeq(&frm, 1, "5 turns"));
}

test "panels footer hides input mode and queue count and starts with arrows+counts" {
    var ps = try Panels.initFull(std.testing.allocator, "m", "p", "", "");
    defer ps.deinit();
    ps.setInputStatus(.queue, 3);
    try ps.append(.{ .usage = .{ .in_tok = 12, .out_tok = 3, .tot_tok = 15 } });

    var frm = try frame.Frame.init(std.testing.allocator, 60, 2);
    defer frm.deinit(std.testing.allocator);
    try ps.renderFooter(&frm, .{ .x = 0, .y = 0, .w = 60, .h = 2 });

    const first = try frm.cell(0, 1);
    try std.testing.expectEqual(@as(u21, 0x2193), first.cp); // ↓ at beginning
    try std.testing.expect(hasCp(&frm, 1, 0x2191)); // ↑ present
    try std.testing.expect(findAsciiSeq(&frm, 1, "12"));
    try std.testing.expect(findAsciiSeq(&frm, 1, "3"));
    try std.testing.expect(!findAsciiSeq(&frm, 1, "queue"));
    try std.testing.expect(!findAsciiSeq(&frm, 1, "q3"));

    ps.setInputStatus(.steering, 0);
    try ps.renderFooter(&frm, .{ .x = 0, .y = 0, .w = 60, .h = 2 });
    try std.testing.expect(!findAsciiSeq(&frm, 1, "steering"));
    try std.testing.expect(!findAsciiSeq(&frm, 1, "q0"));
}

test "panels footer shows background job counts" {
    var ps = try Panels.initFull(std.testing.allocator, "m", "p", "", "");
    defer ps.deinit();
    ps.setBgStatus(3, 1, 2);

    var frm = try frame.Frame.init(std.testing.allocator, 50, 2);
    defer frm.deinit(std.testing.allocator);
    try ps.renderFooter(&frm, .{ .x = 0, .y = 0, .w = 50, .h = 2 });

    try std.testing.expect(findAsciiSeq(&frm, 1, "bg L3 R1 D2"));
}

test "panels footer animates background spinner while running" {
    var ps = try Panels.initFull(std.testing.allocator, "m", "p", "", "");
    defer ps.deinit();
    ps.setBgStatus(2, 1, 1);

    var frm = try frame.Frame.init(std.testing.allocator, 50, 2);
    defer frm.deinit(std.testing.allocator);
    try ps.renderFooter(&frm, .{ .x = 0, .y = 0, .w = 50, .h = 2 });
    const first = firstSpinnerCp(&frm, 1) orelse return error.TestUnexpectedResult;

    ps.tickBgSpinner();
    try ps.renderFooter(&frm, .{ .x = 0, .y = 0, .w = 50, .h = 2 });
    const second = firstSpinnerCp(&frm, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expect(first != second);
}
