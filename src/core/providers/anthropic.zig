const std = @import("std");
const providers = @import("contract.zig");
const auth_mod = @import("auth.zig");

const api_version = "2023-06-01";
const api_host = "api.anthropic.com";
const api_path = "/v1/messages";
const default_max_tokens: u32 = 16384;

pub const Client = struct {
    alloc: std.mem.Allocator,
    auth: auth_mod.Result,
    http: std.http.Client,

    pub fn init(alloc: std.mem.Allocator) !Client {
        var auth_res = try auth_mod.load(alloc);
        errdefer auth_res.deinit();
        return .{
            .alloc = alloc,
            .auth = auth_res,
            .http = .{ .allocator = alloc },
        };
    }

    pub fn deinit(self: *Client) void {
        self.http.deinit();
        self.auth.deinit();
    }

    pub fn asProvider(self: *Client) providers.Provider {
        return providers.Provider.from(Client, self, Client.start);
    }

    const max_retries = 3;
    const base_delay_ms = 2000;
    const max_delay_ms = 60000;

    fn start(self: *Client, req: providers.Req) anyerror!providers.Stream {
        const stream = try self.alloc.create(SseStream);
        stream.* = SseStream.initFields(self.alloc);
        errdefer {
            stream.arena.deinit();
            self.alloc.destroy(stream);
        }

        const ar = stream.arena.allocator();

        // Build request body
        const body = try buildBody(ar, req);

        // Auth headers
        var hdrs = std.ArrayListUnmanaged(std.http.Header){};
        try hdrs.append(ar, .{ .name = "content-type", .value = "application/json" });
        try hdrs.append(ar, .{ .name = "anthropic-version", .value = api_version });

        switch (self.auth.auth) {
            .oauth => |token| {
                const bearer = try std.fmt.allocPrint(ar, "Bearer {s}", .{token});
                try hdrs.append(ar, .{ .name = "anthropic-beta", .value = "oauth-2025-04-20" });
                try hdrs.append(ar, .{ .name = "anthropic-dangerous-direct-browser-access", .value = "true" });
                try hdrs.append(ar, .{ .name = "authorization", .value = bearer });
            },
            .api_key => |key| {
                try hdrs.append(ar, .{ .name = "x-api-key", .value = key });
            },
        }

        const uri = std.Uri{
            .scheme = "https",
            .host = .{ .raw = api_host },
            .path = .{ .raw = api_path },
        };

        var attempt: u32 = 0;
        while (true) : (attempt += 1) {
            stream.req = try self.http.request(.POST, uri, .{
                .extra_headers = hdrs.items,
                .keep_alive = false,
            });

            // Send body
            stream.req.transfer_encoding = .{ .content_length = body.len };
            var bw = try stream.req.sendBodyUnflushed(&stream.send_buf);
            try bw.writer.writeAll(body);
            try bw.end();
            try stream.req.connection.?.flush();

            // Receive response head
            stream.response = try stream.req.receiveHead(&stream.redir_buf);

            const status_int: u16 = @intFromEnum(stream.response.head.status);
            const retryable = status_int == 429 or (status_int >= 500 and status_int < 600);

            if (!retryable or attempt >= max_retries) break;

            // Drain response body before retry
            const rdr = stream.response.reader(&stream.transfer_buf);
            _ = rdr.allocRemaining(ar, .limited(16384)) catch {};
            stream.req.deinit();

            // Backoff: min(base * 2^attempt, max)
            const delay: u64 = @min(max_delay_ms, base_delay_ms * (@as(u64, 1) << @intCast(attempt)));
            std.Thread.sleep(delay * std.time.ns_per_ms);
        }

        if (stream.response.head.status != .ok) {
            stream.err_mode = true;
            const rdr = stream.response.reader(&stream.transfer_buf);
            const err_body = rdr.allocRemaining(ar, .limited(16384)) catch
                try ar.dupe(u8, "unknown error");
            const status_int: u16 = @intFromEnum(stream.response.head.status);
            // Sanitize: response body may not be valid UTF-8
            const safe_body = sanitizeUtf8(ar, err_body) catch "unknown error";
            stream.err_text = try std.fmt.allocPrint(ar, "{d} {s}", .{ status_int, safe_body });
        } else {
            stream.body_rdr = stream.response.reader(&stream.transfer_buf);
        }

        return providers.Stream.from(SseStream, stream, SseStream.next, SseStream.deinit);
    }
};

const SseStream = struct {
    alloc: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    req: std.http.Client.Request,
    response: std.http.Client.Response,
    send_buf: [1024]u8,
    transfer_buf: [16384]u8,
    redir_buf: [0]u8,
    body_rdr: *std.Io.Reader,

    // SSE state
    in_tok: u64,
    out_tok: u64,
    tool_id: std.ArrayListUnmanaged(u8),
    tool_name: std.ArrayListUnmanaged(u8),
    tool_args: std.ArrayListUnmanaged(u8),
    in_tool: bool,
    done: bool,
    err_mode: bool,
    err_text: ?[]const u8,
    pending: ?providers.Ev,

    fn initFields(alloc: std.mem.Allocator) SseStream {
        return .{
            .alloc = alloc,
            .arena = std.heap.ArenaAllocator.init(alloc),
            .req = undefined,
            .response = undefined,
            .send_buf = undefined,
            .transfer_buf = undefined,
            .redir_buf = .{},
            .body_rdr = undefined,
            .in_tok = 0,
            .out_tok = 0,
            .tool_id = .{},
            .tool_name = .{},
            .tool_args = .{},
            .in_tool = false,
            .done = false,
            .err_mode = false,
            .err_text = null,
            .pending = null,
        };
    }

    fn next(self: *SseStream) anyerror!?providers.Ev {
        if (self.pending) |ev| {
            self.pending = null;
            return ev;
        }

        if (self.done) return null;

        if (self.err_mode) {
            self.err_mode = false;
            self.done = true;
            self.pending = .{ .stop = .{ .reason = .err } };
            return .{ .err = self.err_text orelse "unknown error" };
        }

        while (true) {
            const line = self.body_rdr.takeDelimiter('\n') catch |err| switch (err) {
                error.ReadFailed => {
                    self.done = true;
                    return null;
                },
                error.StreamTooLong => continue,
            };

            const raw_line = line orelse {
                self.done = true;
                return null;
            };

            const raw = std.mem.trimRight(u8, raw_line, "\r");
            if (!std.mem.startsWith(u8, raw, "data: ")) continue;
            const data = raw["data: ".len..];
            if (std.mem.eql(u8, data, "[DONE]")) continue;

            // Copy data before parsing (takeDelimiter buffer is reused)
            const ar = self.arena.allocator();
            const data_copy = try ar.dupe(u8, data);

            const ev = self.parseSseData(data_copy) catch continue;
            if (ev) |e| return e;
        }
    }

    fn parseSseData(self: *SseStream, data: []const u8) !?providers.Ev {
        const ar = self.arena.allocator();

        var parsed = std.json.parseFromSlice(std.json.Value, ar, data, .{
            .allocate = .alloc_always,
        }) catch return null;
        _ = &parsed;

        const root = switch (parsed.value) {
            .object => |obj| obj,
            else => return null,
        };

        const ev_type = switch (root.get("type") orelse return null) {
            .string => |s| s,
            else => return null,
        };

        const SseEvType = enum { message_start, content_block_start, content_block_delta, content_block_stop, message_delta };
        const ev_map = std.StaticStringMap(SseEvType).initComptime(.{
            .{ "message_start", .message_start },
            .{ "content_block_start", .content_block_start },
            .{ "content_block_delta", .content_block_delta },
            .{ "content_block_stop", .content_block_stop },
            .{ "message_delta", .message_delta },
        });

        const resolved = ev_map.get(ev_type) orelse return null;
        return switch (resolved) {
            .message_start => self.onMessageStart(root),
            .content_block_start => self.onBlockStart(root),
            .content_block_delta => self.onBlockDelta(root),
            .content_block_stop => self.onBlockStop(),
            .message_delta => self.onMessageDelta(root),
        };
    }

    fn onMessageStart(self: *SseStream, root: std.json.ObjectMap) !?providers.Ev {
        const msg = objGet(root, "message") orelse return null;
        const usage = objGet(msg, "usage") orelse return null;
        self.in_tok = jsonU64(usage.get("input_tokens"));
        return null;
    }

    fn onBlockStart(self: *SseStream, root: std.json.ObjectMap) !?providers.Ev {
        const cb = objGet(root, "content_block") orelse return null;
        const cb_type = strGet(cb, "type") orelse return null;

        if (!std.mem.eql(u8, cb_type, "tool_use")) return null;

        self.tool_id.clearRetainingCapacity();
        self.tool_name.clearRetainingCapacity();
        self.tool_args.clearRetainingCapacity();

        if (strGet(cb, "id")) |id| try self.tool_id.appendSlice(self.alloc, id);
        if (strGet(cb, "name")) |name| try self.tool_name.appendSlice(self.alloc, name);
        self.in_tool = true;
        return null;
    }

    fn onBlockDelta(self: *SseStream, root: std.json.ObjectMap) !?providers.Ev {
        const delta = objGet(root, "delta") orelse return null;
        const delta_type = strGet(delta, "type") orelse return null;

        const DeltaType = enum { text_delta, thinking_delta, input_json_delta };
        const delta_map = std.StaticStringMap(DeltaType).initComptime(.{
            .{ "text_delta", .text_delta },
            .{ "thinking_delta", .thinking_delta },
            .{ "input_json_delta", .input_json_delta },
        });

        const dt = delta_map.get(delta_type) orelse return null;
        switch (dt) {
            .text_delta => if (strGet(delta, "text")) |text| return .{ .text = text },
            .thinking_delta => if (strGet(delta, "thinking")) |text| return .{ .thinking = text },
            .input_json_delta => if (self.in_tool) {
                if (strGet(delta, "partial_json")) |pj|
                    try self.tool_args.appendSlice(self.alloc, pj);
            },
        }
        return null;
    }

    fn onBlockStop(self: *SseStream) !?providers.Ev {
        if (!self.in_tool) return null;
        self.in_tool = false;
        const ar = self.arena.allocator();
        return .{ .tool_call = .{
            .id = try ar.dupe(u8, self.tool_id.items),
            .name = try ar.dupe(u8, self.tool_name.items),
            .args = try ar.dupe(u8, self.tool_args.items),
        } };
    }

    fn onMessageDelta(self: *SseStream, root: std.json.ObjectMap) !?providers.Ev {
        if (objGet(root, "usage")) |usage| {
            self.out_tok = jsonU64(usage.get("output_tokens"));
        }
        const delta = objGet(root, "delta") orelse return null;
        const reason_str = strGet(delta, "stop_reason") orelse return null;

        const usage_ev: providers.Ev = .{ .usage = .{
            .in_tok = self.in_tok,
            .out_tok = self.out_tok,
            .tot_tok = self.in_tok + self.out_tok,
        } };
        self.pending = .{ .stop = .{ .reason = mapStopReason(reason_str) } };
        self.done = true;
        return usage_ev;
    }

    fn deinit(self: *SseStream) void {
        const alloc = self.alloc;
        self.tool_id.deinit(alloc);
        self.tool_name.deinit(alloc);
        self.tool_args.deinit(alloc);
        self.req.deinit();
        self.arena.deinit();
        alloc.destroy(self);
    }
};

fn objGet(map: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const val = map.get(key) orelse return null;
    return switch (val) {
        .object => |obj| obj,
        else => null,
    };
}

fn strGet(map: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = map.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

fn supportsThinking(model: []const u8) bool {
    // Models that support extended thinking
    return std.mem.indexOf(u8, model, "opus") != null or
        std.mem.indexOf(u8, model, "sonnet-4") != null;
}

fn sanitizeUtf8(alloc: std.mem.Allocator, raw: []const u8) ![]const u8 {
    // If already valid UTF-8, return as-is
    if (std.unicode.Utf8View.init(raw)) |_| return raw else |_| {}
    // Replace invalid bytes with '?'
    var out = try alloc.alloc(u8, raw.len);
    var i: usize = 0;
    var o: usize = 0;
    while (i < raw.len) {
        const n = std.unicode.utf8ByteSequenceLength(raw[i]) catch {
            out[o] = '?';
            o += 1;
            i += 1;
            continue;
        };
        if (i + n > raw.len) {
            out[o] = '?';
            o += 1;
            i += 1;
            continue;
        }
        _ = std.unicode.utf8Decode(raw[i .. i + n]) catch {
            out[o] = '?';
            o += 1;
            i += 1;
            continue;
        };
        @memcpy(out[o .. o + n], raw[i .. i + n]);
        o += n;
        i += n;
    }
    return out[0..o];
}

fn mapStopReason(reason: []const u8) providers.StopReason {
    const map = std.StaticStringMap(providers.StopReason).initComptime(.{
        .{ "end_turn", .done },
        .{ "max_tokens", .max_out },
        .{ "tool_use", .tool },
    });
    return map.get(reason) orelse .done;
}

fn jsonU64(val: ?std.json.Value) u64 {
    const v = val orelse return 0;
    return switch (v) {
        .integer => |i| if (i >= 0) @intCast(i) else 0,
        .float => |f| if (f >= 0) @intFromFloat(f) else 0,
        else => 0,
    };
}

fn buildBody(alloc: std.mem.Allocator, req: providers.Req) ![]u8 {
    var out: std.io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    var js: std.json.Stringify = .{
        .writer = &out.writer,
        .options = .{},
    };

    try js.beginObject();

    try js.objectField("model");
    try js.write(req.model);

    try js.objectField("max_tokens");
    try js.write(req.opts.max_out orelse default_max_tokens);

    try js.objectField("stream");
    try js.write(true);

    // Thinking configuration
    switch (req.opts.thinking) {
        .off => {},
        .adaptive => if (supportsThinking(req.model)) {
            try js.objectField("thinking");
            try js.beginObject();
            try js.objectField("type");
            try js.write("adaptive");
            try js.endObject();
        },
        .budget => if (supportsThinking(req.model)) {
            const budget = if (req.opts.thinking_budget > 0) req.opts.thinking_budget else 4096;
            try js.objectField("thinking");
            try js.beginObject();
            try js.objectField("type");
            try js.write("enabled");
            try js.objectField("budget_tokens");
            try js.write(budget);
            try js.endObject();
        },
    }

    // Extract system messages as top-level "system" field
    try writeSystem(&js, req.msgs);

    try js.objectField("messages");
    try writeMessages(&js, req.msgs);

    if (req.tools.len > 0) {
        try js.objectField("tools");
        try js.beginArray();
        for (req.tools) |tool| {
            try js.beginObject();
            try js.objectField("name");
            try js.write(tool.name);
            try js.objectField("description");
            try js.write(tool.desc);
            try js.objectField("input_schema");
            if (tool.schema.len > 0) {
                try js.beginWriteRaw();
                try js.writer.writeAll(tool.schema);
                js.endWriteRaw();
            } else {
                try js.beginObject();
                try js.objectField("type");
                try js.write("object");
                try js.endObject();
            }
            try js.endObject();
        }
        try js.endArray();
    }

    try js.endObject();

    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn writeSystem(js: *std.json.Stringify, msgs: []const providers.Msg) !void {
    // Collect system message text parts into top-level "system" field
    var has_sys = false;
    for (msgs) |msg| {
        if (msg.role != .system) continue;
        for (msg.parts) |part| {
            switch (part) {
                .text => {
                    has_sys = true;
                    break;
                },
                else => {},
            }
            if (has_sys) break;
        }
        if (has_sys) break;
    }
    if (!has_sys) return;

    try js.objectField("system");
    try js.beginArray();
    for (msgs) |msg| {
        if (msg.role != .system) continue;
        for (msg.parts) |part| {
            switch (part) {
                .text => |text| {
                    try js.beginObject();
                    try js.objectField("type");
                    try js.write("text");
                    try js.objectField("text");
                    try js.write(text);
                    try js.endObject();
                },
                else => {},
            }
        }
    }
    try js.endArray();
}

fn writeMessages(js: *std.json.Stringify, msgs: []const providers.Msg) !void {
    try js.beginArray();

    var prev_role: ?[]const u8 = null;
    var content_open = false;

    for (msgs) |msg| {
        if (msg.role == .system) continue; // handled by writeSystem

        const role: []const u8 = switch (msg.role) {
            .system => unreachable,
            .user => "user",
            .assistant => "assistant",
            .tool => "user",
        };

        const same = prev_role != null and std.mem.eql(u8, prev_role.?, role);
        if (!same) {
            if (content_open) {
                try js.endArray();
                try js.endObject();
            }
            try js.beginObject();
            try js.objectField("role");
            try js.write(role);
            try js.objectField("content");
            try js.beginArray();
            content_open = true;
        }

        for (msg.parts) |part| {
            try js.beginObject();
            switch (part) {
                .text => |text| {
                    try js.objectField("type");
                    try js.write("text");
                    try js.objectField("text");
                    try js.write(text);
                },
                .tool_call => |tc| {
                    try js.objectField("type");
                    try js.write("tool_use");
                    try js.objectField("id");
                    try js.write(tc.id);
                    try js.objectField("name");
                    try js.write(tc.name);
                    try js.objectField("input");
                    if (tc.args.len > 0) {
                        try js.beginWriteRaw();
                        try js.writer.writeAll(tc.args);
                        js.endWriteRaw();
                    } else {
                        try js.beginObject();
                        try js.endObject();
                    }
                },
                .tool_result => |tr| {
                    try js.objectField("type");
                    try js.write("tool_result");
                    try js.objectField("tool_use_id");
                    try js.write(tr.id);
                    try js.objectField("content");
                    try js.write(tr.out);
                    if (tr.is_err) {
                        try js.objectField("is_error");
                        try js.write(true);
                    }
                },
            }
            try js.endObject();
        }

        prev_role = role;
    }

    if (content_open) {
        try js.endArray();
        try js.endObject();
    }

    try js.endArray();
}
