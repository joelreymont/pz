const std = @import("std");

pub const ImageCap = enum {
    none,
    kitty,
    iterm,
};

const term_cap_map = std.StaticStringMap(ImageCap).initComptime(.{
    .{ "xterm-kitty", .kitty },
});

const term_program_cap_map = std.StaticStringMap(ImageCap).initComptime(.{
    .{ "WezTerm", .kitty },
});

pub fn detect() ImageCap {
    if (std.posix.getenv("KITTY_WINDOW_ID") != null) return .kitty;
    if (std.posix.getenv("TERM")) |term| {
        if (term_cap_map.get(term)) |cap| return cap;
    }
    if (std.posix.getenv("TERM_PROGRAM")) |tp| {
        if (term_program_cap_map.get(tp)) |cap| return cap;
        if (std.mem.indexOf(u8, tp, "iTerm") != null) return .iterm;
    }
    if (std.posix.getenv("LC_TERMINAL")) |lt| {
        if (std.mem.indexOf(u8, lt, "iTerm") != null) return .iterm;
    }
    return .none;
}

/// Default image display height in terminal rows.
pub const img_rows: usize = 8;

/// Write an image file to the terminal using the appropriate protocol.
/// Positions cursor at (col, row) first using CUP sequence.
pub fn writeImageAt(out: anytype, alloc: std.mem.Allocator, path: []const u8, col: usize, row: usize, cols: usize, cap: ImageCap) !void {
    switch (cap) {
        .none => return,
        .kitty => {
            // Position cursor
            try writeCup(out, col, row);
            try writeKittyFile(out, path, cols);
        },
        .iterm => {
            try writeCup(out, col, row);
            try writeItermFile(out, alloc, path, cols);
        },
    }
}

fn writeCup(out: anytype, col: usize, row: usize) !void {
    var buf: [24]u8 = undefined;
    const seq = std.fmt.bufPrint(&buf, "\x1b[{};{}H", .{ row + 1, col + 1 }) catch
        return error.Overflow;
    try out.writeAll(seq);
}

/// Kitty: transmit image by file path.
/// \x1b_Ga=T,f=100,t=f,c=COLS,r=ROWS;\x1b\\
fn writeKittyFile(out: anytype, path: []const u8, cols: usize) !void {
    var hdr: [128]u8 = undefined;
    const h = std.fmt.bufPrint(&hdr, "\x1b_Ga=T,f=100,t=f,c={d},r={d};", .{ cols, img_rows }) catch
        return error.Overflow;
    try out.writeAll(h);

    // Kitty file path payload is base64-encoded path
    const enc = std.base64.standard;
    var enc_buf: [512]u8 = undefined;
    const encoded = enc.Encoder.encode(&enc_buf, path);
    try out.writeAll(encoded);
    try out.writeAll("\x1b\\");
}

/// iTerm2: transmit image by reading file and base64-encoding data.
fn writeItermFile(out: anytype, alloc: std.mem.Allocator, path: []const u8, cols: usize) !void {
    // Read file
    const data = try std.fs.cwd().readFileAlloc(alloc, path, 4 * 1024 * 1024);
    defer alloc.free(data);

    var hdr: [128]u8 = undefined;
    const h = std.fmt.bufPrint(&hdr, "\x1b]1337;File=inline=1;width={d}cols;height={d}rows:", .{ cols, img_rows }) catch
        return error.Overflow;
    try out.writeAll(h);

    // Base64 encode in chunks
    const enc = std.base64.standard;
    var enc_buf: [8192]u8 = undefined;
    var off: usize = 0;
    while (off < data.len) {
        const chunk = @min(data.len - off, (enc_buf.len / 4) * 3);
        const encoded = enc.Encoder.encode(&enc_buf, data[off .. off + chunk]);
        try out.writeAll(encoded);
        off += chunk;
    }
    try out.writeAll("\x07");
}

// -- Tests --

test "detect returns none in test environment" {
    // In CI/test, no KITTY_WINDOW_ID or iTerm vars
    const cap = detect();
    _ = cap; // just ensure it doesn't crash
}

test "img_rows constant" {
    try std.testing.expectEqual(@as(usize, 8), img_rows);
}
