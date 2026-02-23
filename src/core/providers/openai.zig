const std = @import("std");
const providers = @import("contract.zig");
const auth_mod = @import("auth.zig");

const api_host = "api.openai.com";
const api_path = "/v1/responses";
const default_max_output_tokens: u32 = 16384;

pub const Client = struct {
    alloc: std.mem.Allocator,
    auth: auth_mod.Result,
    http: std.http.Client,

    pub fn init(alloc: std.mem.Allocator) !Client {
        var auth_res = try auth_mod.loadForProvider(alloc, .openai);
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

    pub fn isSub(self: *const Client) bool {
        return self.auth.auth == .oauth;
    }

    pub fn asProvider(self: *Client) providers.Provider {
        return providers.Provider.from(Client, self, Client.start);
    }

    const max_retries = 3;
    const base_delay_ms = 2000;
    const max_delay_ms = 60000;

    fn tryProactiveRefresh(self: *Client, ar: std.mem.Allocator) void {
        if (self.auth.auth != .oauth) return;
        const now = std.time.milliTimestamp();
        if (now < self.auth.auth.oauth.expires) return;
        if (self.refreshAuth(ar)) |_| {} else |err| {
            std.debug.print("warning: proactive token refresh failed: {s}\n", .{@errorName(err)});
        }
    }

    fn refreshAuth(self: *Client, ar: std.mem.Allocator) !void {
        const old = self.auth.auth.oauth;

        if (auth_mod.refreshOAuthForProvider(ar, .openai, old)) |new_oauth| {
            const auth_ar = self.auth.arena.allocator();
            const new_access = try auth_ar.dupe(u8, new_oauth.access);
            const new_refresh = try auth_ar.dupe(u8, new_oauth.refresh);
            ar.free(new_oauth.access);
            ar.free(new_oauth.refresh);
            self.auth.auth = .{ .oauth = .{
                .access = new_access,
                .refresh = new_refresh,
                .expires = new_oauth.expires,
            } };
            return;
        } else |_| {}

        var reloaded = auth_mod.loadForProvider(self.alloc, .openai) catch return error.RefreshFailed;
        switch (reloaded.auth) {
            .oauth => |oauth| {
                const now = std.time.milliTimestamp();
                if (now < oauth.expires) {
                    self.auth.deinit();
                    self.auth = reloaded;
                    return;
                }
            },
            else => {},
        }
        reloaded.deinit();
        return error.RefreshFailed;
    }

    fn buildAuthHeaders(self: *Client, ar: std.mem.Allocator) !std.ArrayListUnmanaged(std.http.Header) {
        var hdrs = std.ArrayListUnmanaged(std.http.Header){};
        try hdrs.append(ar, .{ .name = "content-type", .value = "application/json" });
        switch (self.auth.auth) {
            .oauth => |oauth| {
                const bearer = try std.fmt.allocPrint(ar, "Bearer {s}", .{oauth.access});
                try hdrs.append(ar, .{ .name = "authorization", .value = bearer });
            },
            .api_key => |key| {
                const bearer = try std.fmt.allocPrint(ar, "Bearer {s}", .{key});
                try hdrs.append(ar, .{ .name = "authorization", .value = bearer });
            },
        }
        return hdrs;
    }

    fn start(self: *Client, req: providers.Req) anyerror!providers.Stream {
        const stream = try self.alloc.create(SseStream);
        stream.* = SseStream.initFields(self.alloc);
        errdefer {
            stream.arena.deinit();
            self.alloc.destroy(stream);
        }

        const ar = stream.arena.allocator();
        self.tryProactiveRefresh(ar);

        const body = try buildBody(ar, req);
        var hdrs = try self.buildAuthHeaders(ar);

        const uri = std.Uri{
            .scheme = "https",
            .host = .{ .raw = api_host },
            .path = .{ .raw = api_path },
        };

        var attempt: u32 = 0;
        var did_refresh = false;
        while (true) : (attempt += 1) {
            stream.req = try self.http.request(.POST, uri, .{
                .extra_headers = hdrs.items,
                .keep_alive = false,
            });

            stream.req.transfer_encoding = .{ .content_length = body.len };
            var bw = try stream.req.sendBodyUnflushed(&stream.send_buf);
            try bw.writer.writeAll(body);
            try bw.end();
            try stream.req.connection.?.flush();

            stream.response = try stream.req.receiveHead(&stream.redir_buf);
            const status_int: u16 = @intFromEnum(stream.response.head.status);

            if (status_int == 401 and self.auth.auth == .oauth and !did_refresh) {
                did_refresh = true;
                const refreshed = if (self.refreshAuth(ar)) true else |_| false;
                if (refreshed) {
                    const rdr = stream.response.reader(&stream.transfer_buf);
                    _ = rdr.allocRemaining(ar, .limited(16384)) catch |err| {
                        std.debug.print("warning: drain failed: {s}\n", .{@errorName(err)});
                    };
                    stream.req.deinit();
                    hdrs = try self.buildAuthHeaders(ar);
                    continue;
                }
            }

            const retryable = status_int == 429 or (status_int >= 500 and status_int < 600);
            if (!retryable or attempt >= max_retries) break;

            const rdr = stream.response.reader(&stream.transfer_buf);
            _ = rdr.allocRemaining(ar, .limited(16384)) catch |err| {
                std.debug.print("warning: drain failed: {s}\n", .{@errorName(err)});
            };
            stream.req.deinit();

            const delay: u64 = @min(max_delay_ms, base_delay_ms * (@as(u64, 1) << @intCast(attempt)));
            std.Thread.sleep(delay * std.time.ns_per_ms);
        }

        if (stream.response.head.status != .ok) {
            stream.err_mode = true;
            var decomp: std.http.Decompress = undefined;
            var decomp_buf: [std.compress.flate.max_window_len]u8 = undefined;
            const rdr = stream.response.readerDecompressing(
                &stream.transfer_buf,
                &decomp,
                &decomp_buf,
            );
            const err_body = rdr.allocRemaining(ar, .limited(16384)) catch
                try ar.dupe(u8, "unknown error");
            const status_int: u16 = @intFromEnum(stream.response.head.status);
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
    body_rdr: ?*std.Io.Reader,

    in_tok: u64,
    out_tok: u64,
    cache_read: u64,
    saw_tool_call: bool,
    tool_call_id: std.ArrayListUnmanaged(u8),
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
            .body_rdr = null,
            .in_tok = 0,
            .out_tok = 0,
            .cache_read = 0,
            .saw_tool_call = false,
            .tool_call_id = .{},
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

        _ = self.arena.reset(.retain_capacity);

        while (true) {
            const rdr = self.body_rdr orelse {
                self.done = true;
                return null;
            };

            const line = rdr.takeDelimiter('\n') catch |err| switch (err) {
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
            if (raw.len == 0) continue;

            const data = if (std.mem.startsWith(u8, raw, "data: "))
                raw["data: ".len..]
            else if (std.mem.startsWith(u8, raw, "data:"))
                std.mem.trimLeft(u8, raw["data:".len..], " ")
            else
                continue;

            if (std.mem.eql(u8, data, "[DONE]")) continue;

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

        const ev_type = strGet(root, "type") orelse return null;
        const EventType = enum {
            output_item_added,
            output_item_done,
            tool_args_delta,
            tool_args_done,
            output_text_delta,
            refusal_delta,
            reasoning_delta,
            completed,
            failed,
            error_ev,
        };
        const event_map = std.StaticStringMap(EventType).initComptime(.{
            .{ "response.output_item.added", .output_item_added },
            .{ "response.output_item.done", .output_item_done },
            .{ "response.function_call_arguments.delta", .tool_args_delta },
            .{ "response.function_call_arguments.done", .tool_args_done },
            .{ "response.output_text.delta", .output_text_delta },
            .{ "response.refusal.delta", .refusal_delta },
            .{ "response.reasoning_summary_text.delta", .reasoning_delta },
            .{ "response.completed", .completed },
            .{ "response.failed", .failed },
            .{ "error", .error_ev },
        });

        const resolved = event_map.get(ev_type) orelse return null;
        return switch (resolved) {
            .output_item_added => self.onOutputItemAdded(root),
            .output_item_done => self.onOutputItemDone(root),
            .tool_args_delta => self.onToolArgsDelta(root),
            .tool_args_done => self.onToolArgsDone(root),
            .output_text_delta => self.onTextDelta(root),
            .refusal_delta => self.onTextDelta(root),
            .reasoning_delta => self.onReasoningDelta(root),
            .completed => self.onCompleted(root),
            .failed => self.onFailed(),
            .error_ev => self.onError(root),
        };
    }

    fn onOutputItemAdded(self: *SseStream, root: std.json.ObjectMap) !?providers.Ev {
        const item = objGet(root, "item") orelse return null;
        const item_type = strGet(item, "type") orelse return null;
        if (!std.mem.eql(u8, item_type, "function_call")) return null;

        self.tool_call_id.clearRetainingCapacity();
        self.tool_name.clearRetainingCapacity();
        self.tool_args.clearRetainingCapacity();

        if (strGet(item, "call_id")) |call_id| try self.tool_call_id.appendSlice(self.alloc, call_id);
        if (strGet(item, "name")) |name| try self.tool_name.appendSlice(self.alloc, name);
        if (strGet(item, "arguments")) |args| try self.tool_args.appendSlice(self.alloc, args);
        self.in_tool = true;
        return null;
    }

    fn onToolArgsDelta(self: *SseStream, root: std.json.ObjectMap) !?providers.Ev {
        if (!self.in_tool) return null;
        const delta = strGet(root, "delta") orelse return null;
        try self.tool_args.appendSlice(self.alloc, delta);
        return null;
    }

    fn onToolArgsDone(self: *SseStream, root: std.json.ObjectMap) !?providers.Ev {
        if (!self.in_tool) return null;
        const args = strGet(root, "arguments") orelse return null;
        self.tool_args.clearRetainingCapacity();
        try self.tool_args.appendSlice(self.alloc, args);
        return null;
    }

    fn onOutputItemDone(self: *SseStream, root: std.json.ObjectMap) !?providers.Ev {
        const item = objGet(root, "item") orelse return null;
        const item_type = strGet(item, "type") orelse return null;
        if (!std.mem.eql(u8, item_type, "function_call")) return null;

        if (strGet(item, "call_id")) |call_id| {
            self.tool_call_id.clearRetainingCapacity();
            try self.tool_call_id.appendSlice(self.alloc, call_id);
        }
        if (strGet(item, "name")) |name| {
            self.tool_name.clearRetainingCapacity();
            try self.tool_name.appendSlice(self.alloc, name);
        }
        if (strGet(item, "arguments")) |args| {
            self.tool_args.clearRetainingCapacity();
            try self.tool_args.appendSlice(self.alloc, args);
        }

        const id = self.tool_call_id.items;
        if (id.len == 0) return null;

        const name = self.tool_name.items;
        const args = if (self.tool_args.items.len > 0) self.tool_args.items else "{}";

        self.in_tool = false;
        self.saw_tool_call = true;

        const ar = self.arena.allocator();
        return .{ .tool_call = .{
            .id = try ar.dupe(u8, id),
            .name = try ar.dupe(u8, name),
            .args = try ar.dupe(u8, args),
        } };
    }

    fn onTextDelta(_: *SseStream, root: std.json.ObjectMap) !?providers.Ev {
        const delta = strGet(root, "delta") orelse return null;
        return .{ .text = delta };
    }

    fn onReasoningDelta(_: *SseStream, root: std.json.ObjectMap) !?providers.Ev {
        const delta = strGet(root, "delta") orelse return null;
        return .{ .thinking = delta };
    }

    fn onCompleted(self: *SseStream, root: std.json.ObjectMap) !?providers.Ev {
        const response = objGet(root, "response") orelse return null;
        const usage = objGet(response, "usage");

        const in_tok = if (usage) |u| jsonU64(u.get("input_tokens")) else 0;
        const out_tok = if (usage) |u| jsonU64(u.get("output_tokens")) else 0;
        const total_tok = if (usage) |u| jsonU64(u.get("total_tokens")) else 0;
        const cache_read = if (usage) |u| blk: {
            const details = objGet(u, "input_tokens_details") orelse break :blk 0;
            break :blk jsonU64(details.get("cached_tokens"));
        } else 0;

        self.in_tok = in_tok;
        self.out_tok = out_tok;
        self.cache_read = cache_read;

        var stop_reason = mapStopStatus(strGet(response, "status"));
        if (self.saw_tool_call and stop_reason == .done) stop_reason = .tool;

        self.pending = .{ .stop = .{ .reason = stop_reason } };
        self.done = true;

        const usage_ev: providers.Ev = .{ .usage = .{
            .in_tok = in_tok,
            .out_tok = out_tok,
            .tot_tok = if (total_tok > 0) total_tok else in_tok + out_tok + cache_read,
            .cache_read = cache_read,
            .cache_write = 0,
        } };
        return usage_ev;
    }

    fn onFailed(self: *SseStream) !?providers.Ev {
        self.done = true;
        self.pending = .{ .stop = .{ .reason = .err } };
        return .{ .err = "response failed" };
    }

    fn onError(self: *SseStream, root: std.json.ObjectMap) !?providers.Ev {
        const err_obj = objGet(root, "error");
        const msg = if (strGet(root, "message")) |m|
            m
        else if (err_obj) |eo|
            strGet(eo, "message") orelse "unknown error"
        else
            "unknown error";
        self.done = true;
        self.pending = .{ .stop = .{ .reason = .err } };
        return .{ .err = msg };
    }

    fn deinit(self: *SseStream) void {
        const alloc = self.alloc;
        self.tool_call_id.deinit(alloc);
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

fn jsonU64(val: ?std.json.Value) u64 {
    const v = val orelse return 0;
    return switch (v) {
        .integer => |i| if (i >= 0) @intCast(i) else 0,
        .float => |f| if (f >= 0) @intFromFloat(f) else 0,
        else => 0,
    };
}

fn sanitizeUtf8(alloc: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (std.unicode.Utf8View.init(raw)) |_| return raw else |_| {}
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

fn mapStopStatus(status: ?[]const u8) providers.StopReason {
    const st = status orelse return .done;
    const map = std.StaticStringMap(providers.StopReason).initComptime(.{
        .{ "completed", .done },
        .{ "incomplete", .max_out },
        .{ "cancelled", .canceled },
        .{ "failed", .err },
        .{ "in_progress", .done },
        .{ "queued", .done },
    });
    return map.get(st) orelse .done;
}

fn callIdFromToolId(id: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, id, '|')) |idx| return id[0..idx];
    return id;
}

fn reasoningEffort(opts: providers.Opts) ?[]const u8 {
    return switch (opts.thinking) {
        .off => null,
        .adaptive => "medium",
        .budget => blk: {
            const b = opts.thinking_budget;
            if (b <= 1024) break :blk "minimal";
            if (b <= 4096) break :blk "low";
            if (b <= 16384) break :blk "medium";
            break :blk "high";
        },
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

    try js.objectField("stream");
    try js.write(true);

    try js.objectField("store");
    try js.write(false);

    try js.objectField("max_output_tokens");
    try js.write(req.opts.max_out orelse default_max_output_tokens);

    if (req.opts.temp) |temp| {
        try js.objectField("temperature");
        try js.write(temp);
    }
    if (req.opts.top_p) |top_p| {
        try js.objectField("top_p");
        try js.write(top_p);
    }

    if (reasoningEffort(req.opts)) |effort| {
        try js.objectField("reasoning");
        try js.beginObject();
        try js.objectField("effort");
        try js.write(effort);
        try js.objectField("summary");
        try js.write("auto");
        try js.endObject();
    }

    try js.objectField("input");
    try writeInput(&js, req.msgs);

    if (req.tools.len > 0) {
        try js.objectField("tools");
        try writeTools(&js, req.tools);
    }

    try js.endObject();

    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn writeInput(js: *std.json.Stringify, msgs: []const providers.Msg) !void {
    try js.beginArray();
    for (msgs) |msg| {
        switch (msg.role) {
            .system => try writeSystemInput(js, msg.parts),
            .user => try writeUserInput(js, msg.parts),
            .assistant => try writeAssistantInput(js, msg.parts),
            .tool => try writeToolInput(js, msg.parts),
        }
    }
    try js.endArray();
}

fn writeSystemInput(js: *std.json.Stringify, parts: []const providers.Part) !void {
    var text_count: usize = 0;
    for (parts) |part| {
        if (part == .text) text_count += 1;
    }
    if (text_count == 0) return;

    try js.beginObject();
    try js.objectField("role");
    try js.write("developer");
    try js.objectField("content");
    try js.beginArray();
    for (parts) |part| switch (part) {
        .text => |text| {
            try js.beginObject();
            try js.objectField("type");
            try js.write("input_text");
            try js.objectField("text");
            try js.write(text);
            try js.endObject();
        },
        else => {},
    };
    try js.endArray();
    try js.endObject();
}

fn writeUserInput(js: *std.json.Stringify, parts: []const providers.Part) !void {
    var text_count: usize = 0;
    for (parts) |part| {
        if (part == .text) text_count += 1;
    }
    if (text_count == 0) return;

    try js.beginObject();
    try js.objectField("role");
    try js.write("user");
    try js.objectField("content");
    try js.beginArray();
    for (parts) |part| switch (part) {
        .text => |text| {
            try js.beginObject();
            try js.objectField("type");
            try js.write("input_text");
            try js.objectField("text");
            try js.write(text);
            try js.endObject();
        },
        else => {},
    };
    try js.endArray();
    try js.endObject();
}

fn writeAssistantInput(js: *std.json.Stringify, parts: []const providers.Part) !void {
    for (parts) |part| switch (part) {
        .text => |text| {
            try js.beginObject();
            try js.objectField("type");
            try js.write("message");
            try js.objectField("role");
            try js.write("assistant");
            try js.objectField("status");
            try js.write("completed");
            try js.objectField("content");
            try js.beginArray();
            try js.beginObject();
            try js.objectField("type");
            try js.write("output_text");
            try js.objectField("text");
            try js.write(text);
            try js.objectField("annotations");
            try js.beginArray();
            try js.endArray();
            try js.endObject();
            try js.endArray();
            try js.endObject();
        },
        .tool_call => |tc| {
            try js.beginObject();
            try js.objectField("type");
            try js.write("function_call");
            try js.objectField("call_id");
            try js.write(callIdFromToolId(tc.id));
            try js.objectField("name");
            try js.write(tc.name);
            try js.objectField("arguments");
            try js.write(tc.args);
            try js.endObject();
        },
        else => {},
    };
}

fn writeToolInput(js: *std.json.Stringify, parts: []const providers.Part) !void {
    for (parts) |part| switch (part) {
        .tool_result => |tr| {
            try js.beginObject();
            try js.objectField("type");
            try js.write("function_call_output");
            try js.objectField("call_id");
            try js.write(callIdFromToolId(tr.id));
            try js.objectField("output");
            try js.write(tr.out);
            try js.endObject();
        },
        else => {},
    };
}

fn writeTools(js: *std.json.Stringify, tools: []const providers.Tool) !void {
    try js.beginArray();
    for (tools) |tool| {
        try js.beginObject();
        try js.objectField("type");
        try js.write("function");
        try js.objectField("name");
        try js.write(tool.name);
        try js.objectField("description");
        try js.write(tool.desc);
        try js.objectField("parameters");
        if (tool.schema.len > 0) {
            try js.beginWriteRaw();
            try js.writer.writeAll(tool.schema);
            js.endWriteRaw();
        } else {
            try js.beginObject();
            try js.objectField("type");
            try js.write("object");
            try js.objectField("properties");
            try js.beginObject();
            try js.endObject();
            try js.endObject();
        }
        try js.objectField("strict");
        try js.write(false);
        try js.endObject();
    }
    try js.endArray();
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn testStream() SseStream {
    return SseStream.initFields(testing.allocator);
}

fn testParse(stream: *SseStream, data: []const u8) !?providers.Ev {
    const ar = stream.arena.allocator();
    const copy = try ar.dupe(u8, data);
    return stream.parseSseData(copy);
}

test "mapStopStatus maps known statuses" {
    try testing.expectEqual(providers.StopReason.done, mapStopStatus("completed"));
    try testing.expectEqual(providers.StopReason.max_out, mapStopStatus("incomplete"));
    try testing.expectEqual(providers.StopReason.canceled, mapStopStatus("cancelled"));
    try testing.expectEqual(providers.StopReason.err, mapStopStatus("failed"));
}

test "mapStopStatus unknown defaults to done" {
    try testing.expectEqual(providers.StopReason.done, mapStopStatus("mystery"));
    try testing.expectEqual(providers.StopReason.done, mapStopStatus(null));
}

test "jsonU64 handles integer float and invalid" {
    try testing.expectEqual(@as(u64, 9), jsonU64(.{ .integer = 9 }));
    try testing.expectEqual(@as(u64, 3), jsonU64(.{ .float = 3.5 }));
    try testing.expectEqual(@as(u64, 0), jsonU64(.{ .integer = -1 }));
    try testing.expectEqual(@as(u64, 0), jsonU64(.{ .bool = true }));
}

test "sanitizeUtf8 invalid bytes replaced" {
    const input = "ab\xfe\xffcd";
    const out = try sanitizeUtf8(testing.allocator, input);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("ab??cd", out);
}

test "parseSseData output_text.delta emits text event" {
    var stream = testStream();
    defer stream.arena.deinit();
    const ev = try testParse(&stream,
        \\{"type":"response.output_text.delta","delta":"hello"}
    );
    try testing.expect(ev != null);
    try testing.expectEqualStrings("hello", ev.?.text);
}

test "parseSseData refusal delta emits text event" {
    var stream = testStream();
    defer stream.arena.deinit();
    const ev = try testParse(&stream,
        \\{"type":"response.refusal.delta","delta":"nope"}
    );
    try testing.expect(ev != null);
    try testing.expectEqualStrings("nope", ev.?.text);
}

test "parseSseData reasoning delta emits thinking event" {
    var stream = testStream();
    defer stream.arena.deinit();
    const ev = try testParse(&stream,
        \\{"type":"response.reasoning_summary_text.delta","delta":"hmm"}
    );
    try testing.expect(ev != null);
    try testing.expectEqualStrings("hmm", ev.?.thinking);
}

test "parseSseData function call lifecycle emits tool_call" {
    var stream = testStream();
    defer stream.arena.deinit();
    defer stream.tool_call_id.deinit(testing.allocator);
    defer stream.tool_name.deinit(testing.allocator);
    defer stream.tool_args.deinit(testing.allocator);

    _ = try testParse(&stream,
        \\{"type":"response.output_item.added","item":{"type":"function_call","call_id":"c1","name":"bash","arguments":"{\"cmd\":\"ls"}}
    );
    _ = try testParse(&stream,
        \\{"type":"response.function_call_arguments.delta","delta":"\" -la\""}}
    );
    _ = try testParse(&stream,
        \\{"type":"response.function_call_arguments.done","arguments":"{\"cmd\":\"ls -la\"}"}
    );
    const ev = try testParse(&stream,
        \\{"type":"response.output_item.done","item":{"type":"function_call","call_id":"c1","name":"bash","arguments":"{\"cmd\":\"ls -la\"}"}}
    );
    try testing.expect(ev != null);
    const tc = ev.?.tool_call;
    try testing.expectEqualStrings("c1", tc.id);
    try testing.expectEqualStrings("bash", tc.name);
    try testing.expectEqualStrings("{\"cmd\":\"ls -la\"}", tc.args);
}

test "parseSseData completed emits usage and pending stop done" {
    var stream = testStream();
    defer stream.arena.deinit();
    const ev = try testParse(&stream,
        \\{"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":10,"output_tokens":4,"total_tokens":14,"input_tokens_details":{"cached_tokens":3}}}}
    );
    try testing.expect(ev != null);
    const usage = ev.?.usage;
    try testing.expectEqual(@as(u64, 10), usage.in_tok);
    try testing.expectEqual(@as(u64, 4), usage.out_tok);
    try testing.expectEqual(@as(u64, 14), usage.tot_tok);
    try testing.expectEqual(@as(u64, 3), usage.cache_read);
    try testing.expect(stream.pending != null);
    try testing.expectEqual(providers.StopReason.done, stream.pending.?.stop.reason);
    try testing.expect(stream.done);
}

test "parseSseData completed maps tool stop when tool call seen" {
    var stream = testStream();
    defer stream.arena.deinit();
    stream.saw_tool_call = true;
    const ev = try testParse(&stream,
        \\{"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":1,"output_tokens":1}}}
    );
    try testing.expect(ev != null);
    try testing.expect(stream.pending != null);
    try testing.expectEqual(providers.StopReason.tool, stream.pending.?.stop.reason);
}

test "parseSseData error emits err and stop" {
    var stream = testStream();
    defer stream.arena.deinit();
    const ev = try testParse(&stream,
        \\{"type":"error","message":"boom"}
    );
    try testing.expect(ev != null);
    try testing.expectEqualStrings("boom", ev.?.err);
    try testing.expect(stream.pending != null);
    try testing.expectEqual(providers.StopReason.err, stream.pending.?.stop.reason);
}

test "parseSseData unknown and invalid return null" {
    var stream = testStream();
    defer stream.arena.deinit();
    try testing.expect((try testParse(&stream, "{\"type\":\"noop\"}")) == null);
    try testing.expect((try testParse(&stream, "not json")) == null);
}

test "callIdFromToolId strips item suffix" {
    try testing.expectEqualStrings("call-1", callIdFromToolId("call-1|fc_123"));
    try testing.expectEqualStrings("call-2", callIdFromToolId("call-2"));
}

test "buildBody minimal request has model stream and input" {
    const msgs = [_]providers.Msg{
        .{ .role = .user, .parts = &.{.{ .text = "hi" }} },
    };
    const body = try buildBody(testing.allocator, .{
        .model = "gpt-5",
        .msgs = &msgs,
        .opts = .{ .thinking = .off },
    });
    defer testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const root = parsed.value.object;
    try testing.expectEqualStrings("gpt-5", root.get("model").?.string);
    try testing.expect(root.get("stream").?.bool);
    try testing.expect(!root.get("store").?.bool);
    try testing.expectEqual(@as(i64, 16384), root.get("max_output_tokens").?.integer);
    try testing.expect(root.get("input") != null);
    try testing.expect(root.get("reasoning") == null);
}

test "buildBody includes reasoning for adaptive and budget" {
    const msgs = [_]providers.Msg{
        .{ .role = .user, .parts = &.{.{ .text = "hi" }} },
    };
    const adaptive = try buildBody(testing.allocator, .{
        .model = "gpt-5",
        .msgs = &msgs,
        .opts = .{ .thinking = .adaptive },
    });
    defer testing.allocator.free(adaptive);
    const parsed_ad = try std.json.parseFromSlice(std.json.Value, testing.allocator, adaptive, .{
        .allocate = .alloc_always,
    });
    defer parsed_ad.deinit();
    const reasoning_ad = parsed_ad.value.object.get("reasoning").?.object;
    try testing.expectEqualStrings("medium", reasoning_ad.get("effort").?.string);

    const budget = try buildBody(testing.allocator, .{
        .model = "gpt-5",
        .msgs = &msgs,
        .opts = .{ .thinking = .budget, .thinking_budget = 500 },
    });
    defer testing.allocator.free(budget);
    const parsed_bg = try std.json.parseFromSlice(std.json.Value, testing.allocator, budget, .{
        .allocate = .alloc_always,
    });
    defer parsed_bg.deinit();
    const reasoning_bg = parsed_bg.value.object.get("reasoning").?.object;
    try testing.expectEqualStrings("minimal", reasoning_bg.get("effort").?.string);
}

test "buildBody includes system assistant tool history and tool definitions" {
    const msgs = [_]providers.Msg{
        .{ .role = .system, .parts = &.{.{ .text = "sys" }} },
        .{ .role = .user, .parts = &.{.{ .text = "run" }} },
        .{ .role = .assistant, .parts = &.{.{ .tool_call = .{
            .id = "call-1|fc_1",
            .name = "bash",
            .args = "{\"cmd\":\"ls\"}",
        } }} },
        .{ .role = .tool, .parts = &.{.{ .tool_result = .{
            .id = "call-1|fc_1",
            .out = "ok",
        } }} },
    };
    const tools = [_]providers.Tool{
        .{ .name = "bash", .desc = "Run shell", .schema = "{\"type\":\"object\"}" },
    };
    const body = try buildBody(testing.allocator, .{
        .model = "gpt-5",
        .msgs = &msgs,
        .tools = &tools,
        .opts = .{ .thinking = .off },
    });
    defer testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const root = parsed.value.object;
    const input = root.get("input").?.array;
    try testing.expect(input.items.len >= 4);
    const tools_arr = root.get("tools").?.array;
    try testing.expectEqual(@as(usize, 1), tools_arr.items.len);
    const t0 = tools_arr.items[0].object;
    try testing.expectEqualStrings("function", t0.get("type").?.string);
    try testing.expectEqualStrings("bash", t0.get("name").?.string);
}
