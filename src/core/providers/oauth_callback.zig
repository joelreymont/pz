const std = @import("std");

pub const Opts = struct {
    bind_ip: []const u8 = "127.0.0.1",
    redirect_host: []const u8 = "127.0.0.1",
    path: []const u8 = "/callback",
};

pub const CodeState = struct {
    code: []u8,
    state: []u8,

    pub fn deinit(self: *CodeState, alloc: std.mem.Allocator) void {
        alloc.free(self.code);
        alloc.free(self.state);
        self.* = undefined;
    }
};

pub const Listener = struct {
    alloc: std.mem.Allocator,
    server: std.net.Server,
    redirect_uri: []u8,
    path: []u8,

    pub fn init(alloc: std.mem.Allocator, opts: Opts) !Listener {
        const addr = try std.net.Address.parseIp(opts.bind_ip, 0);
        var server = try addr.listen(.{ .reuse_address = true });
        errdefer server.deinit();

        const listen_port = server.listen_address.getPort();
        const redirect_uri = try std.fmt.allocPrint(alloc, "http://{s}:{d}{s}", .{
            opts.redirect_host,
            listen_port,
            opts.path,
        });
        errdefer alloc.free(redirect_uri);

        const path = try alloc.dupe(u8, opts.path);
        errdefer alloc.free(path);

        return .{
            .alloc = alloc,
            .server = server,
            .redirect_uri = redirect_uri,
            .path = path,
        };
    }

    pub fn deinit(self: *Listener) void {
        self.server.deinit();
        self.alloc.free(self.redirect_uri);
        self.alloc.free(self.path);
        self.* = undefined;
    }

    pub fn port(self: *const Listener) u16 {
        return self.server.listen_address.getPort();
    }

    pub fn waitForCodeState(
        self: *Listener,
        alloc: std.mem.Allocator,
        timeout_ms: i32,
    ) !CodeState {
        var fds = [_]std.posix.pollfd{.{
            .fd = self.server.stream.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = try std.posix.poll(&fds, timeout_ms);
        if (ready == 0) return error.OAuthCallbackTimeout;

        var conn = try self.server.accept();
        defer conn.stream.close();

        var req_buf: [8192]u8 = undefined;
        var req_len: usize = 0;
        while (req_len < req_buf.len) {
            const n = try std.posix.read(conn.stream.handle, req_buf[req_len..]);
            if (n == 0) break;
            req_len += n;
            if (std.mem.indexOf(u8, req_buf[0..req_len], "\r\n\r\n") != null) break;
        }
        if (req_len == 0) {
            writeHtml(conn.stream.handle, "400 Bad Request", callback_error_body);
            return error.InvalidOAuthCallbackRequest;
        }

        const query = parseQueryFromHttpRequest(req_buf[0..req_len], self.path) catch {
            writeHtml(conn.stream.handle, "400 Bad Request", callback_error_body);
            return error.InvalidOAuthCallbackRequest;
        };
        var out = parseCodeStateQuery(alloc, query) catch {
            writeHtml(conn.stream.handle, "400 Bad Request", callback_error_body);
            return error.InvalidOAuthCallbackRequest;
        };
        errdefer out.deinit(alloc);

        if (out.code.len == 0 or out.state.len == 0) {
            writeHtml(conn.stream.handle, "400 Bad Request", callback_error_body);
            return error.InvalidOAuthCallbackRequest;
        }

        writeHtml(conn.stream.handle, "200 OK", callback_ok_body);
        return out;
    }
};

pub fn parseCodeStateQuery(alloc: std.mem.Allocator, query: []const u8) !CodeState {
    var code: ?[]u8 = null;
    errdefer if (code) |v| alloc.free(v);
    var state: ?[]u8 = null;
    errdefer if (state) |v| alloc.free(v);

    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const name = pair[0..eq];
        const value = pair[eq + 1 ..];

        if (std.mem.eql(u8, name, "code") and code == null) {
            code = try decodeQueryValue(alloc, value);
            continue;
        }
        if (std.mem.eql(u8, name, "state") and state == null) {
            state = try decodeQueryValue(alloc, value);
            continue;
        }
    }

    return .{
        .code = code orelse return error.InvalidOAuthInput,
        .state = state orelse return error.InvalidOAuthInput,
    };
}

fn parseQueryFromHttpRequest(request: []const u8, expected_path: []const u8) ![]const u8 {
    const line_end = std.mem.indexOf(u8, request, "\r\n") orelse return error.InvalidOAuthCallbackRequest;
    const line = request[0..line_end];
    if (!std.mem.startsWith(u8, line, "GET ")) return error.InvalidOAuthCallbackRequest;

    const rest = line["GET ".len..];
    const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse return error.InvalidOAuthCallbackRequest;
    const target = rest[0..sp];

    const q = std.mem.indexOfScalar(u8, target, '?') orelse return error.InvalidOAuthCallbackRequest;
    if (q != expected_path.len) return error.InvalidOAuthCallbackRequest;
    if (!std.mem.eql(u8, target[0..q], expected_path)) return error.InvalidOAuthCallbackRequest;
    return target[q + 1 ..];
}

fn decodeQueryValue(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);

    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (c == '+') {
            try out.append(alloc, ' ');
            continue;
        }
        if (c != '%') {
            try out.append(alloc, c);
            continue;
        }
        if (i + 2 >= raw.len) return error.InvalidOAuthInput;
        const hi = fromHex(raw[i + 1]) orelse return error.InvalidOAuthInput;
        const lo = fromHex(raw[i + 2]) orelse return error.InvalidOAuthInput;
        try out.append(alloc, (hi << 4) | lo);
        i += 2;
    }
    return out.toOwnedSlice(alloc);
}

fn fromHex(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

fn writeHtml(fd: std.posix.fd_t, status: []const u8, body: []const u8) void {
    var header: [256]u8 = undefined;
    const hdr = std.fmt.bufPrint(
        &header,
        "HTTP/1.1 {s}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ status, body.len },
    ) catch return;
    _ = std.posix.write(fd, hdr) catch {};
    _ = std.posix.write(fd, body) catch {};
}

const callback_ok_body =
    "<!doctype html><html><body><h1>Login complete</h1><p>You can return to pz.</p></body></html>";
const callback_error_body =
    "<!doctype html><html><body><h1>Login failed</h1><p>Missing or invalid OAuth callback parameters.</p></body></html>";

fn sendTestCallback(port: u16, req: []const u8) void {
    std.Thread.sleep(20 * std.time.ns_per_ms);
    const addr = std.net.Address.parseIp("127.0.0.1", port) catch return;
    var stream = std.net.tcpConnectToAddress(addr) catch return;
    defer stream.close();
    _ = std.posix.write(stream.handle, req) catch return;
    var sink: [256]u8 = undefined;
    _ = std.posix.read(stream.handle, &sink) catch {};
}

test "parseCodeStateQuery decodes URL-encoded params" {
    var got = try parseCodeStateQuery(std.testing.allocator, "code=abc123&state=state%20456");
    defer got.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("abc123", got.code);
    try std.testing.expectEqualStrings("state 456", got.state);
}

test "parseCodeStateQuery rejects missing state" {
    try std.testing.expectError(error.InvalidOAuthInput, parseCodeStateQuery(std.testing.allocator, "code=abc123"));
}

test "listener captures callback code and state" {
    var listener = try Listener.init(std.testing.allocator, .{});
    defer listener.deinit();

    const req = "GET /callback?code=abc&state=def HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
    const t = try std.Thread.spawn(.{}, sendTestCallback, .{ listener.port(), req });
    defer t.join();

    var got = try listener.waitForCodeState(std.testing.allocator, 3000);
    defer got.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("abc", got.code);
    try std.testing.expectEqualStrings("def", got.state);
}

test "listener times out when callback is not received" {
    var listener = try Listener.init(std.testing.allocator, .{});
    defer listener.deinit();

    try std.testing.expectError(error.OAuthCallbackTimeout, listener.waitForCodeState(std.testing.allocator, 25));
}

test "listener rejects callback on wrong path" {
    var listener = try Listener.init(std.testing.allocator, .{});
    defer listener.deinit();

    const req = "GET /callbackx?code=abc&state=def HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
    const t = try std.Thread.spawn(.{}, sendTestCallback, .{ listener.port(), req });
    defer t.join();

    try std.testing.expectError(error.InvalidOAuthCallbackRequest, listener.waitForCodeState(std.testing.allocator, 3000));
}

test "listener rejects callback missing state param" {
    var listener = try Listener.init(std.testing.allocator, .{});
    defer listener.deinit();

    const req = "GET /callback?code=abc HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
    const t = try std.Thread.spawn(.{}, sendTestCallback, .{ listener.port(), req });
    defer t.join();

    try std.testing.expectError(error.InvalidOAuthCallbackRequest, listener.waitForCodeState(std.testing.allocator, 3000));
}
