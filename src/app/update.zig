const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli.zig");
const version = @import("version.zig");

const ReleaseAsset = struct {
    name: []const u8,
    browser_download_url: []const u8,
};

const ReleasePayload = struct {
    tag_name: []const u8,
    assets: []ReleaseAsset = &.{},
};

const release_latest_url = "https://api.github.com/repos/joelreymont/pz/releases/latest";
const release_accept = "application/vnd.github+json";
const asset_accept = "application/octet-stream";
const release_limit = 256 * 1024;
const asset_limit = 256 * 1024 * 1024;
const body_snip_limit = 220;
const any_accept = "*/*";

const HeaderMode = enum {
    full,
    wgetish,
    bare,
};

pub const Outcome = struct {
    ok: bool,
    msg: []u8,

    pub fn deinit(self: Outcome, alloc: std.mem.Allocator) void {
        alloc.free(self.msg);
    }
};

pub const UpdateError = error{
    InvalidCurrentVersion,
    InvalidLatestVersion,
    UnsupportedTarget,
    MissingAsset,
    ReleaseApiFailed,
    ArchiveMissingBinary,
    InvalidExecutablePath,
};

const HttpResult = union(enum) {
    ok: []u8,
    status: struct {
        code: u16,
        body: []u8,
    },

    fn deinit(self: HttpResult, alloc: std.mem.Allocator) void {
        switch (self) {
            .ok => |body| alloc.free(body),
            .status => |resp| alloc.free(resp.body),
        }
    }
};

pub fn run(alloc: std.mem.Allocator) ![]u8 {
    const out = try runOutcome(alloc);
    return out.msg;
}

pub fn runOutcome(alloc: std.mem.Allocator) !Outcome {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const ar = arena.allocator();

    const release_http = httpGetResult(alloc, release_latest_url, release_accept, release_limit) catch |err| {
        if (err == error.OutOfMemory) return err;
        return .{
            .ok = false,
            .msg = try formatTransportFailure(
                alloc,
                "fetch latest release metadata",
                release_latest_url,
                err,
            ),
        };
    };
    defer release_http.deinit(alloc);

    const release_body = switch (release_http) {
        .ok => |body| body,
        .status => |resp| {
            return .{
                .ok = false,
                .msg = try formatHttpFailure(
                    alloc,
                    "fetch latest release metadata",
                    release_latest_url,
                    resp.code,
                    resp.body,
                ),
            };
        },
    };

    const release_parsed = std.json.parseFromSlice(ReleasePayload, ar, release_body, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        if (err == error.OutOfMemory) return err;
        return .{
            .ok = false,
            .msg = try formatParseFailure(alloc, release_body),
        };
    };
    const release = release_parsed.value;

    const current = version.parseVersion(cli.version) orelse return error.InvalidCurrentVersion;
    const latest = version.parseVersion(release.tag_name) orelse return error.InvalidLatestVersion;
    if (!latest.isNewer(current)) {
        return .{
            .ok = true,
            .msg = try std.fmt.allocPrint(alloc, "already up to date ({s})\n", .{cli.version}),
        };
    }

    const asset_name = targetAssetName() orelse {
        const target = try targetLabelAlloc(alloc);
        defer alloc.free(target);
        return .{
            .ok = false,
            .msg = try std.fmt.allocPrint(
                alloc,
                "upgrade failed: no prebuilt binary for target {s}\nsupported targets: x86_64-linux, aarch64-linux, aarch64-macos\nmanual install: https://github.com/joelreymont/pz/releases/latest\n",
                .{target},
            ),
        };
    };
    const asset_url = findAssetUrl(release.assets, asset_name) orelse {
        const list = try assetListAlloc(alloc, release.assets);
        defer alloc.free(list);
        return .{
            .ok = false,
            .msg = try std.fmt.allocPrint(
                alloc,
                "upgrade failed: release {s} does not contain asset {s}\navailable assets: {s}\nmanual install: https://github.com/joelreymont/pz/releases/latest\n",
                .{ release.tag_name, asset_name, list },
            ),
        };
    };

    const archive_http = httpGetResult(alloc, asset_url, asset_accept, asset_limit) catch |err| {
        if (err == error.OutOfMemory) return err;
        return .{
            .ok = false,
            .msg = try formatTransportFailure(alloc, "download release archive", asset_url, err),
        };
    };
    defer archive_http.deinit(alloc);

    const archive = switch (archive_http) {
        .ok => |body| body,
        .status => |resp| {
            return .{
                .ok = false,
                .msg = try formatHttpFailure(
                    alloc,
                    "download release archive",
                    asset_url,
                    resp.code,
                    resp.body,
                ),
            };
        },
    };

    const next_bin = extractPzBinary(alloc, archive) catch |err| {
        if (err == error.OutOfMemory) return err;
        return .{
            .ok = false,
            .msg = try formatExtractFailure(alloc, err, asset_name),
        };
    };
    defer alloc.free(next_bin);

    const exe_path = try std.fs.selfExePathAlloc(alloc);
    defer alloc.free(exe_path);
    installBinary(alloc, exe_path, next_bin) catch |err| {
        if (err == error.OutOfMemory) return err;
        return .{
            .ok = false,
            .msg = try formatInstallFailure(alloc, err, exe_path),
        };
    };

    return .{
        .ok = true,
        .msg = try std.fmt.allocPrint(
            alloc,
            "updated {s} -> {s}; restart pz to use the new binary\n",
            .{ cli.version, release.tag_name },
        ),
    };
}

fn httpGetResult(
    alloc: std.mem.Allocator,
    url: []const u8,
    accept: []const u8,
    limit: usize,
) !HttpResult {
    const modes = [_]HeaderMode{ .full, .wgetish, .bare };
    var i: usize = 0;
    while (i < modes.len) : (i += 1) {
        const mode = modes[i];
        var res = httpGetResultOnce(alloc, url, accept, limit, mode) catch |err| {
            if (i + 1 < modes.len and isBadHeaderTransport(err)) continue;
            return err;
        };
        if (i + 1 < modes.len and shouldRetryForBadHeaderResponse(res)) {
            res.deinit(alloc);
            continue;
        }
        return res;
    }
    unreachable;
}

fn httpGetResultOnce(
    alloc: std.mem.Allocator,
    url: []const u8,
    accept: []const u8,
    limit: usize,
    mode: HeaderMode,
) !HttpResult {
    var http = std.http.Client{ .allocator = alloc };
    defer http.deinit();
    var proxy_arena = std.heap.ArenaAllocator.init(alloc);
    defer proxy_arena.deinit();
    try http.initDefaultProxies(proxy_arena.allocator());

    const uri = try std.Uri.parse(url);
    const ua = "pz/" ++ cli.version;
    const h_ua = std.http.Header{ .name = "User-Agent", .value = ua };
    const h_accept_full = std.http.Header{ .name = "Accept", .value = accept };
    const h_accept_any = std.http.Header{ .name = "Accept", .value = any_accept };
    const extra_headers: []const std.http.Header = switch (mode) {
        .full => &.{ h_ua, h_accept_full },
        .wgetish => &.{ h_ua, h_accept_any },
        .bare => &.{},
    };
    var req = try http.request(.GET, uri, .{
        .extra_headers = extra_headers,
        .keep_alive = false,
    });
    defer req.deinit();

    try req.sendBodiless();

    var redir_buf: [4096]u8 = undefined;
    var resp = try req.receiveHead(&redir_buf);

    var transfer_buf: [16384]u8 = undefined;
    var decomp: std.http.Decompress = undefined;
    var decomp_buf: [std.compress.flate.max_window_len]u8 = undefined;
    const reader = resp.readerDecompressing(&transfer_buf, &decomp, &decomp_buf);
    const body = try reader.allocRemaining(alloc, .limited(limit));

    if (resp.head.status != .ok) {
        return .{
            .status = .{
                .code = @intFromEnum(resp.head.status),
                .body = body,
            },
        };
    }

    return .{ .ok = body };
}

fn isBadHeaderTransport(err: anyerror) bool {
    return std.mem.eql(u8, @errorName(err), "BadHeaderName");
}

fn isBadHeaderBody(body: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(body, "invalid header name") != null or
        std.ascii.indexOfIgnoreCase(body, "bad header name") != null or
        std.ascii.indexOfIgnoreCase(body, "invalid http header name") != null;
}

fn shouldRetryForBadHeaderResponse(res: HttpResult) bool {
    return switch (res) {
        .status => |st| st.code == 400 and isBadHeaderBody(st.body),
        else => false,
    };
}

fn targetLabelAlloc(alloc: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "{s}-{s}",
        .{ @tagName(builtin.target.cpu.arch), @tagName(builtin.target.os.tag) },
    );
}

fn assetListAlloc(alloc: std.mem.Allocator, assets: []const ReleaseAsset) ![]u8 {
    if (assets.len == 0) return alloc.dupe(u8, "<none>");
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    const max_items: usize = 6;
    const lim = @min(assets.len, max_items);
    for (assets[0..lim], 0..) |asset, i| {
        if (i != 0) try out.appendSlice(alloc, ", ");
        try out.appendSlice(alloc, asset.name);
    }
    if (assets.len > lim) try out.appendSlice(alloc, ", ...");
    return out.toOwnedSlice(alloc);
}

fn sanitizeSnippetAlloc(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    const lim = @min(raw.len, body_snip_limit);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    for (raw[0..lim]) |b| {
        if (b >= 0x20 and b <= 0x7e) {
            try out.append(alloc, b);
        } else if (b == '\n' or b == '\r' or b == '\t') {
            try out.append(alloc, ' ');
        } else {
            try out.append(alloc, '.');
        }
    }
    if (out.items.len == 0) try out.appendSlice(alloc, "<empty>");
    if (raw.len > lim) try out.appendSlice(alloc, "...");
    return out.toOwnedSlice(alloc);
}

fn statusHint(status: u16) []const u8 {
    return switch (status) {
        400 => "bad request from upstream (often proxy/header rewriting).",
        401 => "GitHub rejected the request as unauthorized.",
        403 => "GitHub denied the request (possibly rate-limited or blocked).",
        404 => "Release endpoint not found.",
        429 => "GitHub rate limit exceeded. Retry later.",
        500...599 => "GitHub returned a server error. Retry shortly.",
        else => "GitHub returned an unexpected response.",
    };
}

fn indexOfIgnoreCasePos(hay: []const u8, start: usize, needle: []const u8) ?usize {
    if (start >= hay.len) return null;
    const rel = std.ascii.indexOfIgnoreCase(hay[start..], needle) orelse return null;
    return start + rel;
}

fn stripHtmlTagsCollapseAlloc(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    var in_tag = false;
    var pending_sp = false;
    while (i < raw.len) : (i += 1) {
        const b = raw[i];
        if (b == '<') {
            in_tag = true;
            continue;
        }
        if (b == '>') {
            in_tag = false;
            pending_sp = true;
            continue;
        }
        if (in_tag) continue;
        if (b == '\n' or b == '\r' or b == '\t' or b == ' ') {
            pending_sp = true;
            continue;
        }
        if (pending_sp and out.items.len != 0) {
            try out.append(alloc, ' ');
        }
        pending_sp = false;
        try out.append(alloc, b);
    }
    const owned = try out.toOwnedSlice(alloc);
    const trimmed = std.mem.trim(u8, owned, " ");
    if (trimmed.ptr == owned.ptr and trimmed.len == owned.len) return owned;
    const dup = try alloc.dupe(u8, trimmed);
    alloc.free(owned);
    return dup;
}

fn htmlTagTextAlloc(alloc: std.mem.Allocator, body: []const u8, tag: []const u8) !?[]u8 {
    var open_buf: [16]u8 = undefined;
    var close_buf: [20]u8 = undefined;
    const open = std.fmt.bufPrint(&open_buf, "<{s}", .{tag}) catch return null;
    const close = std.fmt.bufPrint(&close_buf, "</{s}>", .{tag}) catch return null;
    const open_idx = std.ascii.indexOfIgnoreCase(body, open) orelse return null;
    const gt_rel = std.mem.indexOfScalar(u8, body[open_idx..], '>') orelse return null;
    const val_start = open_idx + gt_rel + 1;
    const close_idx = indexOfIgnoreCasePos(body, val_start, close) orelse return null;
    if (close_idx <= val_start) return null;
    const raw = body[val_start..close_idx];
    const txt = try stripHtmlTagsCollapseAlloc(alloc, raw);
    if (txt.len == 0) {
        alloc.free(txt);
        return null;
    }
    return txt;
}

fn responseDetailAlloc(alloc: std.mem.Allocator, body: []const u8) ![]u8 {
    if (std.ascii.indexOfIgnoreCase(body, "<html") != null) {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(alloc);
        const tags = [_][]const u8{ "title", "h1", "h2", "p" };
        for (tags) |tag| {
            const part = try htmlTagTextAlloc(alloc, body, tag) orelse continue;
            defer alloc.free(part);
            if (out.items.len != 0) try out.appendSlice(alloc, " | ");
            try out.appendSlice(alloc, part);
        }
        if (out.items.len != 0) return out.toOwnedSlice(alloc);
        out.deinit(alloc);
    }
    return sanitizeSnippetAlloc(alloc, body);
}

fn formatTransportFailure(
    alloc: std.mem.Allocator,
    step: []const u8,
    url: []const u8,
    err: anyerror,
) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "upgrade failed: could not {s}\nreason: {s}\nurl: {s}\nnext: check network/DNS/firewall/proxy settings and retry\n",
        .{ step, @errorName(err), url },
    );
}

fn formatHttpFailure(
    alloc: std.mem.Allocator,
    step: []const u8,
    url: []const u8,
    status: u16,
    body: []const u8,
) ![]u8 {
    const detail = try responseDetailAlloc(alloc, body);
    defer alloc.free(detail);
    return std.fmt.allocPrint(
        alloc,
        "upgrade failed: could not {s}\nhttp status: {d}\nreason: {s}\nurl: {s}\nresponse: {s}\nnext: retry later or install manually from https://github.com/joelreymont/pz/releases/latest\n",
        .{ step, status, statusHint(status), url, detail },
    );
}

fn formatParseFailure(alloc: std.mem.Allocator, body: []const u8) ![]u8 {
    const snip = try sanitizeSnippetAlloc(alloc, body);
    defer alloc.free(snip);
    return std.fmt.allocPrint(
        alloc,
        "upgrade failed: release metadata could not be parsed\nresponse: {s}\nnext: retry later or install manually from https://github.com/joelreymont/pz/releases/latest\n",
        .{snip},
    );
}

fn formatExtractFailure(alloc: std.mem.Allocator, err: anyerror, asset_name: []const u8) ![]u8 {
    if (err == error.ArchiveMissingBinary) {
        return std.fmt.allocPrint(
            alloc,
            "upgrade failed: downloaded archive {s} did not contain a pz binary\nnext: retry later or install manually from https://github.com/joelreymont/pz/releases/latest\n",
            .{asset_name},
        );
    }
    return std.fmt.allocPrint(
        alloc,
        "upgrade failed: could not unpack archive {s}\nreason: {s}\nnext: retry later or install manually from https://github.com/joelreymont/pz/releases/latest\n",
        .{ asset_name, @errorName(err) },
    );
}

fn formatInstallFailure(alloc: std.mem.Allocator, err: anyerror, exe_path: []const u8) ![]u8 {
    return switch (err) {
        error.AccessDenied => std.fmt.allocPrint(
            alloc,
            "upgrade failed: permission denied while replacing {s}\nnext: run with permissions that can write this path or reinstall manually\n",
            .{exe_path},
        ),
        else => std.fmt.allocPrint(
            alloc,
            "upgrade failed: could not replace {s}\nreason: {s}\nnext: retry or reinstall manually\n",
            .{ exe_path, @errorName(err) },
        ),
    };
}

fn targetAssetName() ?[]const u8 {
    return switch (builtin.target.os.tag) {
        .linux => switch (builtin.target.cpu.arch) {
            .x86_64 => "pz-x86_64-linux.tar.gz",
            .aarch64 => "pz-aarch64-linux.tar.gz",
            else => null,
        },
        .macos => switch (builtin.target.cpu.arch) {
            .aarch64 => "pz-aarch64-macos.tar.gz",
            else => null,
        },
        else => null,
    };
}

fn findAssetUrl(assets: []const ReleaseAsset, want_name: []const u8) ?[]const u8 {
    for (assets) |asset| {
        if (std.mem.eql(u8, asset.name, want_name)) return asset.browser_download_url;
    }
    return null;
}

fn extractPzBinary(alloc: std.mem.Allocator, archive_gz: []const u8) ![]u8 {
    var gz_reader: std.Io.Reader = .fixed(archive_gz);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decomp = std.compress.flate.Decompress.init(&gz_reader, .gzip, &window);

    var tar_buf: std.Io.Writer.Allocating = .init(alloc);
    defer tar_buf.deinit();
    _ = try decomp.reader.streamRemaining(&tar_buf.writer);
    const tar_bytes = try tar_buf.toOwnedSlice();
    defer alloc.free(tar_bytes);

    var tar_reader: std.Io.Reader = .fixed(tar_bytes);
    var file_name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var link_name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(&tar_reader, .{
        .file_name_buffer = &file_name_buf,
        .link_name_buffer = &link_name_buf,
    });

    while (try it.next()) |file| {
        if (file.kind != .file) continue;
        if (!std.mem.eql(u8, file.name, "pz") and !std.mem.endsWith(u8, file.name, "/pz")) continue;

        var out: std.Io.Writer.Allocating = .init(alloc);
        errdefer out.deinit();
        try it.streamRemaining(file, &out.writer);
        return out.toOwnedSlice();
    }

    return error.ArchiveMissingBinary;
}

fn installBinary(alloc: std.mem.Allocator, exe_path: []const u8, binary: []const u8) !void {
    const exe_dir = std.fs.path.dirname(exe_path) orelse return error.InvalidExecutablePath;
    const tmp_path = try std.fs.path.join(alloc, &.{ exe_dir, ".pz-self-update.tmp" });
    defer alloc.free(tmp_path);

    var moved = false;
    defer if (!moved) std.fs.deleteFileAbsolute(tmp_path) catch {};

    const f = try std.fs.createFileAbsolute(tmp_path, .{ .truncate = true });
    defer f.close();

    try f.writeAll(binary);
    if (std.fs.has_executable_bit) try f.chmod(0o755);

    try std.fs.renameAbsolute(tmp_path, exe_path);
    moved = true;
}

fn makeTarGzAlloc(alloc: std.mem.Allocator, name: []const u8, data: []const u8) ![]u8 {
    const blk: usize = 512;
    if (name.len == 0 or name.len > 100) return error.NameTooLong;

    const data_pad = (blk - (data.len % blk)) % blk;
    const tar_len = blk + data.len + data_pad + (2 * blk);
    if (tar_len > std.math.maxInt(u16)) return error.TestUnexpectedResult;

    const tar = try alloc.alloc(u8, tar_len);
    defer alloc.free(tar);
    @memset(tar, 0);

    var hdr = tar[0..blk];
    @memcpy(hdr[0..name.len], name);
    writeOctal(hdr[100..108], 0o755);
    writeOctal(hdr[108..116], 0);
    writeOctal(hdr[116..124], 0);
    writeOctal(hdr[124..136], data.len);
    writeOctal(hdr[136..148], 0);
    @memset(hdr[148..156], ' ');
    hdr[156] = '0';
    @memcpy(hdr[257..263], "ustar\x00");
    @memcpy(hdr[263..265], "00");

    var sum: u32 = 0;
    for (hdr) |b| sum +%= b;
    writeChecksum(hdr[148..156], sum);

    const data_off = blk;
    @memcpy(tar[data_off .. data_off + data.len], data);

    const gz_len = 10 + 1 + 2 + 2 + tar_len + 8;
    const gz = try alloc.alloc(u8, gz_len);
    errdefer alloc.free(gz);

    @memcpy(gz[0..10], "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03");
    var pos: usize = 10;
    gz[pos] = 0x01;
    pos += 1;

    const len16: u16 = @intCast(tar_len);
    writeLe16(gz[pos .. pos + 2], len16);
    pos += 2;
    writeLe16(gz[pos .. pos + 2], ~len16);
    pos += 2;

    @memcpy(gz[pos .. pos + tar_len], tar);
    pos += tar_len;

    var crc = std.hash.Crc32.init();
    crc.update(tar);
    writeLe32(gz[pos .. pos + 4], crc.final());
    pos += 4;
    writeLe32(gz[pos .. pos + 4], @intCast(tar_len));
    pos += 4;

    std.debug.assert(pos == gz_len);
    return gz;
}

fn writeOctal(dst: []u8, value: usize) void {
    if (dst.len == 0) return;
    @memset(dst, '0');
    dst[dst.len - 1] = 0;

    var v = value;
    var i = dst.len - 2;
    while (true) {
        dst[i] = @as(u8, '0') + @as(u8, @intCast(v & 0x7));
        v >>= 3;
        if (v == 0 or i == 0) break;
        i -= 1;
    }
}

fn writeChecksum(dst: []u8, value: u32) void {
    @memset(dst, '0');
    var v = value;
    var i: usize = 5;
    while (true) {
        dst[i] = @as(u8, '0') + @as(u8, @intCast(v & 0x7));
        v >>= 3;
        if (v == 0 or i == 0) break;
        i -= 1;
    }
    dst[6] = 0;
    dst[7] = ' ';
}

fn writeLe16(dst: []u8, value: u16) void {
    dst[0] = @intCast(value & 0xff);
    dst[1] = @intCast((value >> 8) & 0xff);
}

fn writeLe32(dst: []u8, value: u32) void {
    dst[0] = @intCast(value & 0xff);
    dst[1] = @intCast((value >> 8) & 0xff);
    dst[2] = @intCast((value >> 16) & 0xff);
    dst[3] = @intCast((value >> 24) & 0xff);
}

test "findAssetUrl returns exact match" {
    const assets = [_]ReleaseAsset{
        .{ .name = "a.tar.gz", .browser_download_url = "https://example/a" },
        .{ .name = "b.tar.gz", .browser_download_url = "https://example/b" },
    };
    const got = findAssetUrl(&assets, "b.tar.gz") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("https://example/b", got);
}

test "findAssetUrl returns null for missing assets" {
    const assets = [_]ReleaseAsset{
        .{ .name = "a.tar.gz", .browser_download_url = "https://example/a" },
    };
    try std.testing.expect(findAssetUrl(&assets, "missing.tar.gz") == null);
}

test "targetAssetName maps supported targets only" {
    const got = targetAssetName();
    const os = builtin.target.os.tag;
    const arch = builtin.target.cpu.arch;
    const supported = (os == .linux and (arch == .x86_64 or arch == .aarch64)) or
        (os == .macos and arch == .aarch64);
    if (supported) {
        try std.testing.expect(got != null);
    } else {
        try std.testing.expect(got == null);
    }
}

test "extractPzBinary reads pz from archive root" {
    const data = "bin\n";
    const gz = try makeTarGzAlloc(std.testing.allocator, "pz", data);
    defer std.testing.allocator.free(gz);

    const got = try extractPzBinary(std.testing.allocator, gz);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(data, got);
}

test "extractPzBinary reads nested pz path" {
    const data = "nested\n";
    const gz = try makeTarGzAlloc(std.testing.allocator, "bin/pz", data);
    defer std.testing.allocator.free(gz);

    const got = try extractPzBinary(std.testing.allocator, gz);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(data, got);
}

test "extractPzBinary errors when archive has no pz binary" {
    const gz = try makeTarGzAlloc(std.testing.allocator, "bin/other", "x");
    defer std.testing.allocator.free(gz);

    try std.testing.expectError(error.ArchiveMissingBinary, extractPzBinary(std.testing.allocator, gz));
}

test "installBinary atomically replaces executable bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "pz",
        .data = "old",
    });
    const exe_path = try tmp.dir.realpathAlloc(std.testing.allocator, "pz");
    defer std.testing.allocator.free(exe_path);

    try installBinary(std.testing.allocator, exe_path, "new-binary");

    const f = try std.fs.openFileAbsolute(exe_path, .{});
    defer f.close();
    const got = try f.readToEndAlloc(std.testing.allocator, 1024);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("new-binary", got);
}

test "installBinary rejects non-path executable" {
    try std.testing.expectError(error.InvalidExecutablePath, installBinary(std.testing.allocator, "pz", "x"));
}

test "sanitizeSnippetAlloc normalizes binary text and truncates" {
    const raw = "ok\x00\x01\nline";
    const snip = try sanitizeSnippetAlloc(std.testing.allocator, raw);
    defer std.testing.allocator.free(snip);
    try std.testing.expect(std.mem.indexOf(u8, snip, "ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, snip, "..") != null);
}

test "formatHttpFailure includes actionable fields" {
    const msg = try formatHttpFailure(
        std.testing.allocator,
        "fetch latest release metadata",
        release_latest_url,
        403,
        "{\"message\":\"API rate limit exceeded\"}",
    );
    defer std.testing.allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "http status: 403") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "rate-limited") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "response: ") != null);
}

test "formatHttpFailure extracts concise html error text" {
    const html =
        \\<!DOCTYPE HTML>
        \\<html><head><title>Bad Request</title></head>
        \\<body><h2>Bad Request - Invalid Header</h2>
        \\<p>HTTP Error 400. The request has an invalid header name.</p></body></html>
    ;
    const msg = try formatHttpFailure(
        std.testing.allocator,
        "download release archive",
        "https://example.invalid/archive",
        400,
        html,
    );
    defer std.testing.allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "http status: 400") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "proxy/header rewriting") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "Bad Request - Invalid Header") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "invalid header name") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "<html>") == null);
}

test "isBadHeaderBody detects common bad-header responses" {
    try std.testing.expect(isBadHeaderBody("HTTP Error 400. The request has an invalid header name."));
    try std.testing.expect(isBadHeaderBody("bad header name in request"));
    try std.testing.expect(!isBadHeaderBody("rate limit exceeded"));
}

test "shouldRetryForBadHeaderResponse only retries matching 400 responses" {
    const bad = HttpResult{
        .status = .{
            .code = 400,
            .body = try std.testing.allocator.dupe(u8, "<p>invalid header name</p>"),
        },
    };
    defer bad.deinit(std.testing.allocator);
    try std.testing.expect(shouldRetryForBadHeaderResponse(bad));

    const non_400 = HttpResult{
        .status = .{
            .code = 403,
            .body = try std.testing.allocator.dupe(u8, "<p>invalid header name</p>"),
        },
    };
    defer non_400.deinit(std.testing.allocator);
    try std.testing.expect(!shouldRetryForBadHeaderResponse(non_400));

    const non_match = HttpResult{
        .status = .{
            .code = 400,
            .body = try std.testing.allocator.dupe(u8, "{\"message\":\"rate limited\"}"),
        },
    };
    defer non_match.deinit(std.testing.allocator);
    try std.testing.expect(!shouldRetryForBadHeaderResponse(non_match));
}
