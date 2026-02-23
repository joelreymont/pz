const std = @import("std");
const cli = @import("cli.zig");

/// Semver triple for comparison.
pub const Ver = struct {
    major: u16,
    minor: u16,
    patch: u16,

    pub fn isNewer(self: Ver, other: Ver) bool {
        if (self.major != other.major) return self.major > other.major;
        if (self.minor != other.minor) return self.minor > other.minor;
        return self.patch > other.patch;
    }
};

/// Parse "v1.2.3", "1.2.3", or "1.2.3-rc1" into Ver.
pub fn parseVersion(raw: []const u8) ?Ver {
    var s = raw;
    if (s.len > 0 and s[0] == 'v') s = s[1..];
    // Strip suffix after dash
    if (std.mem.indexOfScalar(u8, s, '-')) |i| s = s[0..i];
    var it = std.mem.splitScalar(u8, s, '.');
    const major = std.fmt.parseInt(u16, it.next() orelse return null, 10) catch return null;
    const minor = std.fmt.parseInt(u16, it.next() orelse return null, 10) catch return null;
    const patch = std.fmt.parseInt(u16, it.next() orelse return null, 10) catch return null;
    return .{ .major = major, .minor = minor, .patch = patch };
}

/// Background version checker. Stack-allocatable.
pub const Check = struct {
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    result: ?[]u8 = null,
    alloc: std.mem.Allocator,
    thread: ?std.Thread = null,

    pub fn init(alloc: std.mem.Allocator) Check {
        return .{ .alloc = alloc };
    }

    pub fn spawn(self: *Check) void {
        self.thread = std.Thread.spawn(.{}, checkThread, .{self}) catch null;
    }

    pub fn poll(self: *Check) ?[]const u8 {
        if (!self.done.load(.acquire)) return null;
        return self.result;
    }

    pub fn isDone(self: *const Check) bool {
        return self.done.load(.acquire);
    }

    pub fn deinit(self: *Check) void {
        if (self.thread) |t| t.join();
        if (self.result) |r| self.alloc.free(r);
    }

    fn checkThread(self: *Check) void {
        self.result = checkLatest(self.alloc) catch null;
        self.done.store(true, .release);
    }
};

/// Check GitHub releases for a newer version. Returns version string if newer, null otherwise.
fn checkLatest(alloc: std.mem.Allocator) !?[]u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const ar = arena.allocator();

    var http = std.http.Client{ .allocator = ar };
    defer http.deinit();
    try http.initDefaultProxies(ar);

    const uri = std.Uri{
        .scheme = "https",
        .host = .{ .raw = "api.github.com" },
        .path = .{ .raw = "/repos/joelreymont/pz/releases/latest" },
    };

    const ua = "pz/" ++ cli.version;
    var req = try http.request(.GET, uri, .{
        .extra_headers = &.{
            .{ .name = "user-agent", .value = ua },
            .{ .name = "accept", .value = "application/vnd.github+json" },
        },
        .keep_alive = false,
    });
    defer req.deinit();

    try req.sendBodiless();

    var redir_buf: [4096]u8 = undefined;
    var resp = try req.receiveHead(&redir_buf);

    if (resp.head.status != .ok) return null;

    var transfer_buf: [16384]u8 = undefined;
    var decomp: std.http.Decompress = undefined;
    var decomp_buf: [std.compress.flate.max_window_len]u8 = undefined;
    const reader = resp.readerDecompressing(&transfer_buf, &decomp, &decomp_buf);
    const body = try reader.allocRemaining(ar, .limited(64 * 1024));

    // Parse just the tag_name field
    const tag = extractTagName(body) orelse return null;

    const current = parseVersion(cli.version) orelse return null;
    const latest = parseVersion(tag) orelse return null;

    if (!latest.isNewer(current)) return null;

    return try alloc.dupe(u8, tag);
}

/// Extract "tag_name":"..." from JSON without full parse.
fn extractTagName(json: []const u8) ?[]const u8 {
    const key = "\"tag_name\"";
    const pos = std.mem.indexOf(u8, json, key) orelse return null;
    const after = json[pos + key.len ..];
    // Skip whitespace and colon
    var i: usize = 0;
    while (i < after.len and (after[i] == ' ' or after[i] == ':' or after[i] == '\t' or after[i] == '\n')) : (i += 1) {}
    if (i >= after.len or after[i] != '"') return null;
    i += 1; // skip opening quote
    const start = i;
    while (i < after.len and after[i] != '"') : (i += 1) {}
    if (i >= after.len) return null;
    return after[start..i];
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "parseVersion basic" {
    const v = parseVersion("0.1.0").?;
    try testing.expectEqual(@as(u16, 0), v.major);
    try testing.expectEqual(@as(u16, 1), v.minor);
    try testing.expectEqual(@as(u16, 0), v.patch);
}

test "parseVersion strips v prefix" {
    const v = parseVersion("v1.2.3").?;
    try testing.expectEqual(@as(u16, 1), v.major);
    try testing.expectEqual(@as(u16, 2), v.minor);
    try testing.expectEqual(@as(u16, 3), v.patch);
}

test "parseVersion strips suffix" {
    const v = parseVersion("0.1.0-rc1").?;
    try testing.expectEqual(@as(u16, 0), v.major);
    try testing.expectEqual(@as(u16, 1), v.minor);
    try testing.expectEqual(@as(u16, 0), v.patch);
}

test "parseVersion bad input" {
    try testing.expect(parseVersion("bad") == null);
    try testing.expect(parseVersion("") == null);
    try testing.expect(parseVersion("1.2") == null);
}

test "isNewer comparisons" {
    const v010 = Ver{ .major = 0, .minor = 1, .patch = 0 };
    const v020 = Ver{ .major = 0, .minor = 2, .patch = 0 };
    const v100 = Ver{ .major = 1, .minor = 0, .patch = 0 };
    const v009 = Ver{ .major = 0, .minor = 0, .patch = 9 };
    try testing.expect(v020.isNewer(v010));
    try testing.expect(!v010.isNewer(v010));
    try testing.expect(!v009.isNewer(v010));
    try testing.expect(v100.isNewer(v020));
}

test "extractTagName from json" {
    const json =
        \\{"id":123,"tag_name":"v0.2.0","name":"Release 0.2.0"}
    ;
    const tag = extractTagName(json).?;
    try testing.expectEqualStrings("v0.2.0", tag);
}

test "extractTagName missing" {
    try testing.expect(extractTagName("{}") == null);
    try testing.expect(extractTagName("{\"other\":1}") == null);
}
