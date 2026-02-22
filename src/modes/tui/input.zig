const std = @import("std");
const editor = @import("editor.zig");
const mouse = @import("mouse.zig");

pub const Ev = union(enum) {
    key: editor.Key,
    mouse: mouse.Ev,
    resize: void, // SIGWINCH detected
    none: void, // timeout / no data
};

pub const Reader = struct {
    fd: std.posix.fd_t,
    buf: [256]u8 = undefined,
    len: usize = 0,
    pos: usize = 0,

    pub fn init(fd: std.posix.fd_t) Reader {
        return .{ .fd = fd };
    }

    /// Read next input event. May block up to VTIME (100ms).
    pub fn next(self: *Reader) Ev {
        // Try to parse from existing buffer first
        if (self.pos < self.len) {
            if (self.parseOne()) |ev| return ev;
        }

        // Read more data
        self.compact();
        const n = std.posix.read(self.fd, self.buf[self.len..]) catch |err| switch (err) {
            error.WouldBlock => return .none,
            else => return .none,
        };
        if (n == 0) {
            // Lone ESC with no follow-up data → standalone ESC key
            if (self.pos < self.len and self.buf[self.pos] == 0x1b and self.len - self.pos == 1) {
                self.pos += 1;
                return .{ .key = .esc };
            }
            return .none;
        }
        self.len += n;

        return self.parseOne() orelse .none;
    }

    fn compact(self: *Reader) void {
        if (self.pos == 0) return;
        const rem = self.len - self.pos;
        if (rem > 0) {
            std.mem.copyForwards(u8, self.buf[0..rem], self.buf[self.pos..self.len]);
        }
        self.len = rem;
        self.pos = 0;
    }

    fn parseOne(self: *Reader) ?Ev {
        const data = self.buf[self.pos..self.len];
        if (data.len == 0) return null;

        // ESC sequences
        if (data[0] == 0x1b) {
            if (data.len < 2) {
                // Lone ESC — might be incomplete, wait for more
                return null;
            }
            if (data[1] == '[') return self.parseCsi(data);
            if (data[1] == 'O') return self.parseSS3(data);
            // ESC + other: treat ESC as standalone (alt-key, ignore for now)
            self.pos += 1;
            return .none;
        }

        // Ctrl-C
        if (data[0] == 0x03) {
            self.pos += 1;
            return .{ .key = .ctrl_c };
        }

        // Ctrl-D
        if (data[0] == 0x04) {
            self.pos += 1;
            return .{ .key = .ctrl_d };
        }

        // Ctrl-O
        if (data[0] == 0x0f) {
            self.pos += 1;
            return .{ .key = .ctrl_o };
        }

        // Ctrl-P
        if (data[0] == 0x10) {
            self.pos += 1;
            return .{ .key = .ctrl_p };
        }

        // Ctrl-T
        if (data[0] == 0x14) {
            self.pos += 1;
            return .{ .key = .ctrl_t };
        }

        // Enter (CR or LF)
        if (data[0] == '\r' or data[0] == '\n') {
            self.pos += 1;
            // Skip CR+LF pair
            if (data[0] == '\r' and data.len > 1 and data[1] == '\n')
                self.pos += 1;
            return .{ .key = .enter };
        }

        // Backspace (DEL or BS)
        if (data[0] == 0x7f or data[0] == 0x08) {
            self.pos += 1;
            return .{ .key = .backspace };
        }

        // Tab and other control chars — ignore
        if (data[0] < 0x20) {
            self.pos += 1;
            return .none;
        }

        // UTF-8 character
        const seq_len = std.unicode.utf8ByteSequenceLength(data[0]) catch {
            self.pos += 1;
            return .none;
        };
        if (data.len < seq_len) return null; // incomplete
        const cp = std.unicode.utf8Decode(data[0..seq_len]) catch {
            self.pos += 1;
            return .none;
        };
        self.pos += seq_len;
        return .{ .key = .{ .char = cp } };
    }

    fn parseCsi(self: *Reader, data: []const u8) ?Ev {
        if (data.len < 3) return null; // need at least ESC [ X

        // SGR mouse: ESC [ < ...
        if (data[2] == '<') {
            if (mouse.parse(data)) |r| {
                self.pos += r.len;
                return .{ .mouse = r.ev };
            }
            // Incomplete mouse sequence — need more bytes
            if (data.len < 9) return null;
            // Malformed — skip ESC [
            self.pos += 2;
            return .none;
        }

        // Simple CSI sequences: ESC [ letter
        switch (data[2]) {
            'A' => {
                self.pos += 3;
                return .none;
            }, // up
            'B' => {
                self.pos += 3;
                return .none;
            }, // down
            'Z' => {
                self.pos += 3;
                return .{ .key = .shift_tab };
            },
            'C' => {
                self.pos += 3;
                return .{ .key = .right };
            },
            'D' => {
                self.pos += 3;
                return .{ .key = .left };
            },
            'H' => {
                self.pos += 3;
                return .{ .key = .home };
            },
            'F' => {
                self.pos += 3;
                return .{ .key = .end };
            },
            else => {},
        }

        // CSI with numeric params: ESC [ N ~
        // Scan for final byte (0x40-0x7e)
        var i: usize = 2;
        while (i < data.len) : (i += 1) {
            if (data[i] >= 0x40 and data[i] <= 0x7e) {
                i += 1; // include final byte
                const seq = data[2..i];
                const ev = mapCsiParam(seq);
                self.pos += i;
                return ev;
            }
        }
        // Incomplete CSI
        return null;
    }

    fn parseSS3(self: *Reader, data: []const u8) ?Ev {
        if (data.len < 3) return null;
        const ev: Ev = switch (data[2]) {
            'C' => .{ .key = .right },
            'D' => .{ .key = .left },
            'H' => .{ .key = .home },
            'F' => .{ .key = .end },
            else => .none,
        };
        self.pos += 3;
        return ev;
    }
};

fn mapCsiParam(seq: []const u8) Ev {
    // "3~" = delete, "1~"/"7~" = home, "4~"/"8~" = end
    if (seq.len == 2 and seq[1] == '~') {
        return switch (seq[0]) {
            '3' => .{ .key = .delete },
            '1', '7' => .{ .key = .home },
            '4', '8' => .{ .key = .end },
            else => .none,
        };
    }
    return .none;
}

// ============================================================
// Tests
// ============================================================

test "parse plain ASCII char" {
    var r = Reader.init(-1);
    r.buf[0] = 'a';
    r.len = 1;
    const ev = r.parseOne() orelse return error.TestUnexpectedResult;
    switch (ev) {
        .key => |k| switch (k) {
            .char => |cp| try std.testing.expectEqual(@as(u21, 'a'), cp),
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

fn expectKey(ev: Ev, expected: editor.Key) !void {
    switch (ev) {
        .key => |k| try std.testing.expectEqual(expected, k),
        else => return error.TestUnexpectedResult,
    }
}

test "parse enter" {
    var r = Reader.init(-1);
    r.buf[0] = '\r';
    r.len = 1;
    try expectKey(r.parseOne().?, .enter);
}

test "parse ctrl-c" {
    var r = Reader.init(-1);
    r.buf[0] = 0x03;
    r.len = 1;
    try expectKey(r.parseOne().?, .ctrl_c);
}

test "parse backspace" {
    var r = Reader.init(-1);
    r.buf[0] = 0x7f;
    r.len = 1;
    try expectKey(r.parseOne().?, .backspace);
}

test "parse arrow right" {
    var r = Reader.init(-1);
    @memcpy(r.buf[0..3], "\x1b[C");
    r.len = 3;
    try expectKey(r.parseOne().?, .right);
}

test "parse arrow left" {
    var r = Reader.init(-1);
    @memcpy(r.buf[0..3], "\x1b[D");
    r.len = 3;
    try expectKey(r.parseOne().?, .left);
}

test "parse delete key" {
    var r = Reader.init(-1);
    @memcpy(r.buf[0..4], "\x1b[3~");
    r.len = 4;
    try expectKey(r.parseOne().?, .delete);
}

test "parse home key" {
    var r = Reader.init(-1);
    @memcpy(r.buf[0..3], "\x1b[H");
    r.len = 3;
    try expectKey(r.parseOne().?, .home);
}

test "parse mouse scroll" {
    var r = Reader.init(-1);
    const seq = "\x1b[<64;10;5M";
    @memcpy(r.buf[0..seq.len], seq);
    r.len = seq.len;
    const ev = r.parseOne().?;
    switch (ev) {
        .mouse => {},
        else => return error.TestUnexpectedResult,
    }
}

test "parse UTF-8 char" {
    var r = Reader.init(-1);
    // é = 0xC3 0xA9
    r.buf[0] = 0xC3;
    r.buf[1] = 0xA9;
    r.len = 2;
    const ev = r.parseOne().?;
    switch (ev) {
        .key => |k| switch (k) {
            .char => |cp| try std.testing.expectEqual(@as(u21, 0xe9), cp),
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

test "incomplete ESC returns null" {
    var r = Reader.init(-1);
    r.buf[0] = 0x1b;
    r.len = 1;
    try std.testing.expect(r.parseOne() == null);
}

test "incomplete UTF-8 returns null" {
    var r = Reader.init(-1);
    // First byte of 3-byte sequence, missing rest
    r.buf[0] = 0xE4;
    r.len = 1;
    try std.testing.expect(r.parseOne() == null);
}

test "parse ctrl-d" {
    var r = Reader.init(-1);
    r.buf[0] = 0x04;
    r.len = 1;
    try expectKey(r.parseOne().?, .ctrl_d);
}

test "parse shift-tab" {
    var r = Reader.init(-1);
    @memcpy(r.buf[0..3], "\x1b[Z");
    r.len = 3;
    try expectKey(r.parseOne().?, .shift_tab);
}
