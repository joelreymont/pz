const std = @import("std");

pub const Size = struct {
    w: usize,
    h: usize,
};

/// Query terminal dimensions via ioctl(TIOCGWINSZ).
pub fn size(fd: std.posix.fd_t) ?Size {
    var ws: std.posix.winsize = undefined;
    const rc = std.posix.system.ioctl(fd, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
    if (rc != 0) return null;
    if (ws.col == 0 or ws.row == 0) return null;
    return .{ .w = ws.col, .h = ws.row };
}

/// Volatile flag set by SIGWINCH handler.
var resized: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Install SIGWINCH handler. Returns false if installation fails.
pub fn installSigwinch() bool {
    const act = std.posix.Sigaction{
        .handler = .{ .handler = onWinch },
        .mask = std.mem.zeroes(std.posix.sigset_t),
        .flags = std.posix.SA.RESTART,
    };
    std.posix.sigaction(std.posix.SIG.WINCH, &act, null);
    return true;
}

/// Check and clear the resize flag.
pub fn pollResize() bool {
    return resized.swap(false, .acquire);
}

fn onWinch(_: c_int) callconv(.c) void {
    resized.store(true, .release);
}

// -- Raw terminal mode --

/// Only accessed from main thread (enableRaw/restore). Not thread-safe by design.
var saved_termios: ?std.posix.termios = null;

/// Put stdin into raw mode (disable canonical mode, echo, signal chars).
/// Returns true on success. Call `restore()` to undo.
pub fn enableRaw(fd: std.posix.fd_t) bool {
    const orig = std.posix.tcgetattr(fd) catch return false;
    saved_termios = orig;
    var raw = orig;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    raw.iflag.ICRNL = false;
    raw.iflag.IXON = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.INLCR = false;
    raw.iflag.IGNCR = false;
    raw.oflag.OPOST = false;
    // Read returns after 0 bytes available, with 100ms timeout
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 1;
    std.posix.tcsetattr(fd, .FLUSH, raw) catch return false;
    return true;
}

/// Restore original terminal attributes.
pub fn restore(fd: std.posix.fd_t) void {
    if (saved_termios) |orig| {
        std.posix.tcsetattr(fd, .FLUSH, orig) catch |err| {
            std.debug.print("warning: terminal restore failed: {s}\n", .{@errorName(err)});
        };
        saved_termios = null;
    }
}

test "size returns valid dimensions or null" {
    const s = size(std.posix.STDOUT_FILENO);
    if (s) |sz| {
        try std.testing.expect(sz.w > 0);
        try std.testing.expect(sz.h > 0);
    }
}

test "installSigwinch succeeds" {
    try std.testing.expect(installSigwinch());
}

test "pollResize returns false when no signal" {
    try std.testing.expect(!pollResize());
}
