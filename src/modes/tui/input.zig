const std = @import("std");
const editor = @import("editor.zig");
const mouse = @import("mouse.zig");

pub const Ev = union(enum) {
    key: editor.Key,
    mouse: mouse.Ev,
    paste: []const u8, // bracketed paste content
    resize: void, // SIGWINCH detected
    notify: void, // external wake-up (background jobs, etc.)
    none: void, // timeout / no data
    err: void, // fatal read error (EBADF, etc.)
};

pub const Reader = struct {
    fd: std.posix.fd_t,
    buf: [256]u8 = undefined,
    len: usize = 0,
    pos: usize = 0,
    paste_buf: [65536]u8 = undefined,
    paste_len: usize = 0,
    in_paste: bool = false,
    notify_fd: ?std.posix.fd_t = null,

    pub fn init(fd: std.posix.fd_t) Reader {
        return .{ .fd = fd };
    }

    pub fn initWithNotify(fd: std.posix.fd_t, notify_fd: std.posix.fd_t) Reader {
        return .{
            .fd = fd,
            .notify_fd = notify_fd,
        };
    }

    /// Inject bytes into the read buffer (e.g. from InputWatcher stash).
    pub fn inject(self: *Reader, data: []const u8) void {
        self.compact();
        const avail = self.buf.len - self.len;
        const n = @min(data.len, avail);
        @memcpy(self.buf[self.len..][0..n], data[0..n]);
        self.len += n;
    }

    /// Read next input event. May block up to VTIME (100ms).
    pub fn next(self: *Reader) Ev {
        // Bracketed paste accumulation mode
        if (self.in_paste) return self.accumulatePaste();

        // Try to parse from existing buffer first
        if (self.pos < self.len) {
            if (self.parseOne()) |ev| return ev;
        }

        // Read more data
        self.compact();
        const n = self.readReady() catch |err| switch (err) {
            error.WouldBlock => return .none,
            else => return .err,
        };
        if (n == 0) {
            // Lone ESC with no follow-up data → standalone ESC key
            if (self.pos < self.len and self.buf[self.pos] == 0x1b and self.len - self.pos == 1) {
                self.pos += 1;
                return .{ .key = .esc };
            }
            return .none;
        }
        if (n == read_notify) return .notify;
        self.len += n;

        return self.parseOne() orelse .none;
    }

    const read_notify = std.math.maxInt(usize);

    fn readReady(self: *Reader) !usize {
        if (self.notify_fd == null) {
            return std.posix.read(self.fd, self.buf[self.len..]);
        }

        var fds = [2]std.posix.pollfd{
            .{
                .fd = self.fd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            },
            .{
                .fd = self.notify_fd.?,
                .events = std.posix.POLL.IN,
                .revents = 0,
            },
        };
        const ready = try std.posix.poll(&fds, 100);
        if (ready == 0) return error.WouldBlock;

        if ((fds[1].revents & std.posix.POLL.IN) != 0) {
            self.drainNotify();
            return read_notify;
        }
        return std.posix.read(self.fd, self.buf[self.len..]);
    }

    fn drainNotify(self: *Reader) void {
        const fd = self.notify_fd orelse return;
        var scratch: [64]u8 = undefined;
        while (true) {
            const n = std.posix.read(fd, &scratch) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return,
            };
            if (n == 0) return;
            if (n < scratch.len) return;
        }
    }

    fn accumulatePaste(self: *Reader) Ev {
        // Accumulate paste content until \x1b[201~ (paste end)
        while (true) {
            // Process remaining buffer bytes
            while (self.pos < self.len) {
                const b = self.buf[self.pos];
                // Check for paste end sequence: \x1b[201~
                if (b == 0x1b) {
                    const rem = self.len - self.pos;
                    if (rem >= 6) {
                        if (std.mem.eql(u8, self.buf[self.pos .. self.pos + 6], "\x1b[201~")) {
                            self.pos += 6;
                            self.in_paste = false;
                            return .{ .paste = self.paste_buf[0..self.paste_len] };
                        }
                        // Not end marker — consume ESC as paste content
                    } else {
                        // ESC near buffer end — need more data to check marker
                        break;
                    }
                }
                if (self.paste_len < self.paste_buf.len) {
                    self.paste_buf[self.paste_len] = b;
                    self.paste_len += 1;
                }
                self.pos += 1;
            }

            // Need more data
            self.compact();
            const n = std.posix.read(self.fd, self.buf[self.len..]) catch return .err;
            if (n == 0) {
                // EOF during paste — return what we have
                self.in_paste = false;
                if (self.paste_len > 0) return .{ .paste = self.paste_buf[0..self.paste_len] };
                return .none;
            }
            self.len += n;
        }
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
            // Alt+Enter: ESC CR or ESC LF
            if (data[1] == '\r' or data[1] == '\n') {
                self.pos += 2;
                return .{ .key = .alt_enter };
            }
            // Alt+b / Alt+f: word movement
            if (data[1] == 'b') {
                self.pos += 2;
                return .{ .key = .alt_b };
            }
            if (data[1] == 'f') {
                self.pos += 2;
                return .{ .key = .alt_f };
            }
            if (data[1] == 'd') {
                self.pos += 2;
                return .{ .key = .alt_d };
            }
            if (data[1] == 'y') {
                self.pos += 2;
                return .{ .key = .alt_y };
            }
            // ESC + unrecognized: emit standalone ESC
            self.pos += 1;
            return .{ .key = .esc };
        }

        // Ctrl-A
        if (data[0] == 0x01) {
            self.pos += 1;
            return .{ .key = .ctrl_a };
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

        // Ctrl-E
        if (data[0] == 0x05) {
            self.pos += 1;
            return .{ .key = .ctrl_e };
        }

        // Ctrl-G
        if (data[0] == 0x07) {
            self.pos += 1;
            return .{ .key = .ctrl_g };
        }

        // Ctrl-K
        if (data[0] == 0x0b) {
            self.pos += 1;
            return .{ .key = .ctrl_k };
        }

        // Ctrl-L
        if (data[0] == 0x0c) {
            self.pos += 1;
            return .{ .key = .ctrl_l };
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

        // Ctrl-U
        if (data[0] == 0x15) {
            self.pos += 1;
            return .{ .key = .ctrl_u };
        }

        // Ctrl-V (paste image)
        if (data[0] == 0x16) {
            self.pos += 1;
            return .{ .key = .ctrl_v };
        }

        // Ctrl-W
        if (data[0] == 0x17) {
            self.pos += 1;
            return .{ .key = .ctrl_w };
        }

        // Ctrl-] (jump-to-char)
        if (data[0] == 0x1d) {
            self.pos += 1;
            return .{ .key = .ctrl_close_bracket };
        }
        // Ctrl-Y
        if (data[0] == 0x19) {
            self.pos += 1;
            return .{ .key = .ctrl_y };
        }
        // Ctrl-Z
        if (data[0] == 0x1a) {
            self.pos += 1;
            return .{ .key = .ctrl_z };
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

        // Tab
        if (data[0] == 0x09) {
            self.pos += 1;
            return .{ .key = .tab };
        }

        // Other control chars — ignore
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

        // Bracketed paste start: ESC [ 200 ~
        if (data.len >= 6 and std.mem.eql(u8, data[2..6], "200~")) {
            self.pos += 6;
            self.in_paste = true;
            self.paste_len = 0;
            return self.accumulatePaste();
        }

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
                return .{ .key = .up };
            }, // up
            'B' => {
                self.pos += 3;
                return .{ .key = .down };
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
    // "3~" = delete, "1~"/"7~" = home, "4~"/"8~" = end, "5~"/"6~" = page up/down
    if (seq.len == 2 and seq[1] == '~') {
        return switch (seq[0]) {
            '3' => .{ .key = .delete },
            '1', '7' => .{ .key = .home },
            '4', '8' => .{ .key = .end },
            '5' => .{ .key = .page_up },
            '6' => .{ .key = .page_down },
            else => .none,
        };
    }
    // "1;3A" = Alt+Up
    if (seq.len == 4 and std.mem.eql(u8, seq, "1;3A")) {
        return .{ .key = .alt_up };
    }
    // "1;5D" = Ctrl+Left, "1;5C" = Ctrl+Right
    if (seq.len == 4 and std.mem.eql(u8, seq[0..3], "1;5")) {
        return switch (seq[3]) {
            'D' => .{ .key = .ctrl_left },
            'C' => .{ .key = .ctrl_right },
            else => .none,
        };
    }
    // Kitty keyboard protocol: "N;Mu" where N=codepoint, M=modifiers
    if (seq.len >= 3 and seq[seq.len - 1] == 'u') {
        if (parseKittyKey(seq[0 .. seq.len - 1])) |k| return .{ .key = k };
    }
    return .none;
}

fn parseKittyKey(params: []const u8) ?editor.Key {
    // Format: "codepoint;modifiers" — modifiers use mod-1 encoding:
    // 2=shift, 3=alt, 5=ctrl, 6=shift+ctrl, 7=alt+ctrl
    const sep = std.mem.indexOfScalar(u8, params, ';') orelse return null;
    const cp = std.fmt.parseInt(u21, params[0..sep], 10) catch return null;
    const mods = std.fmt.parseInt(u8, params[sep + 1 ..], 10) catch return null;
    const actual = mods -| 1;
    const shift = actual & 1 != 0;
    const alt = actual & 2 != 0;
    const ctrl = actual & 4 != 0;

    // Shift+Ctrl combos
    if (shift and ctrl and !alt) {
        return switch (cp) {
            'p', 'P' => .shift_ctrl_p,
            'z', 'Z' => .ctrl_shift_z,
            else => null,
        };
    }

    // Ctrl combos
    if (ctrl and !shift and !alt) {
        return switch (cp) {
            'a', 'A' => .ctrl_a,
            'c', 'C' => .ctrl_c,
            'd', 'D' => .ctrl_d,
            'e', 'E' => .ctrl_e,
            'g', 'G' => .ctrl_g,
            'k', 'K' => .ctrl_k,
            'l', 'L' => .ctrl_l,
            'o', 'O' => .ctrl_o,
            'p', 'P' => .ctrl_p,
            't', 'T' => .ctrl_t,
            'u', 'U' => .ctrl_u,
            'v', 'V' => .ctrl_v,
            'w', 'W' => .ctrl_w,
            'y', 'Y' => .ctrl_y,
            'z', 'Z' => .ctrl_z,
            ']' => .ctrl_close_bracket,
            else => null,
        };
    }

    // Alt combos
    if (alt and !shift and !ctrl) {
        return switch (cp) {
            'b', 'B' => .alt_b,
            'd', 'D' => .alt_d,
            'f', 'F' => .alt_f,
            'y', 'Y' => .alt_y,
            '\r', '\n' => .alt_enter,
            else => null,
        };
    }

    // Unmodified special keys via Kitty
    if (actual == 0) {
        return switch (cp) {
            13 => .enter,
            9 => .tab,
            27 => .esc,
            127 => .backspace,
            else => null,
        };
    }

    return null;
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

test "parse ctrl-g" {
    var r = Reader.init(-1);
    r.buf[0] = 0x07;
    r.len = 1;
    try expectKey(r.parseOne().?, .ctrl_g);
}

test "parse ctrl-k" {
    var r = Reader.init(-1);
    r.buf[0] = 0x0b;
    r.len = 1;
    try expectKey(r.parseOne().?, .ctrl_k);
}

test "parse ctrl-l" {
    var r = Reader.init(-1);
    r.buf[0] = 0x0c;
    r.len = 1;
    try expectKey(r.parseOne().?, .ctrl_l);
}

test "parse ctrl-v" {
    var r = Reader.init(-1);
    r.buf[0] = 0x16;
    r.len = 1;
    try expectKey(r.parseOne().?, .ctrl_v);
}

test "parse ctrl-z" {
    var r = Reader.init(-1);
    r.buf[0] = 0x1a;
    r.len = 1;
    try expectKey(r.parseOne().?, .ctrl_z);
}

test "parse alt-enter" {
    var r = Reader.init(-1);
    r.buf[0] = 0x1b;
    r.buf[1] = '\r';
    r.len = 2;
    try expectKey(r.parseOne().?, .alt_enter);
}

test "parse alt-up" {
    var r = Reader.init(-1);
    const seq = "\x1b[1;3A";
    @memcpy(r.buf[0..seq.len], seq);
    r.len = seq.len;
    try expectKey(r.parseOne().?, .alt_up);
}

test "parse shift-ctrl-p kitty protocol" {
    var r = Reader.init(-1);
    // Kitty: ESC[112;6u (p=112, modifier 6=shift+ctrl)
    const seq = "\x1b[112;6u";
    @memcpy(r.buf[0..seq.len], seq);
    r.len = seq.len;
    try expectKey(r.parseOne().?, .shift_ctrl_p);
}

test "parse shift-ctrl-p kitty uppercase" {
    var r = Reader.init(-1);
    // Kitty: ESC[80;6u (P=80, modifier 6=shift+ctrl)
    const seq = "\x1b[80;6u";
    @memcpy(r.buf[0..seq.len], seq);
    r.len = seq.len;
    try expectKey(r.parseOne().?, .shift_ctrl_p);
}

test "parse bracketed paste" {
    var r = Reader.init(-1);
    // Full paste sequence in one buffer: ESC[200~ hello ESC[201~
    const seq = "\x1b[200~hello\x1b[201~";
    @memcpy(r.buf[0..seq.len], seq);
    r.len = seq.len;
    const ev = r.parseOne() orelse return error.TestUnexpectedResult;
    switch (ev) {
        .paste => |text| try std.testing.expectEqualStrings("hello", text),
        else => return error.TestUnexpectedResult,
    }
}

test "parse bracketed paste multi-line" {
    var r = Reader.init(-1);
    const seq = "\x1b[200~line1\nline2\nline3\x1b[201~";
    @memcpy(r.buf[0..seq.len], seq);
    r.len = seq.len;
    const ev = r.parseOne() orelse return error.TestUnexpectedResult;
    switch (ev) {
        .paste => |text| try std.testing.expectEqualStrings("line1\nline2\nline3", text),
        else => return error.TestUnexpectedResult,
    }
}

test "parse ctrl-a ctrl-e ctrl-u ctrl-w" {
    var r = Reader.init(-1);
    r.buf[0] = 0x01;
    r.len = 1;
    try expectKey(r.parseOne().?, .ctrl_a);

    r.pos = 0;
    r.buf[0] = 0x05;
    r.len = 1;
    try expectKey(r.parseOne().?, .ctrl_e);

    r.pos = 0;
    r.buf[0] = 0x15;
    r.len = 1;
    try expectKey(r.parseOne().?, .ctrl_u);

    r.pos = 0;
    r.buf[0] = 0x17;
    r.len = 1;
    try expectKey(r.parseOne().?, .ctrl_w);
}

test "parse alt-b alt-f" {
    var r = Reader.init(-1);
    r.buf[0] = 0x1b;
    r.buf[1] = 'b';
    r.len = 2;
    try expectKey(r.parseOne().?, .alt_b);

    r.pos = 0;
    r.buf[0] = 0x1b;
    r.buf[1] = 'f';
    r.len = 2;
    try expectKey(r.parseOne().?, .alt_f);
}

test "parse ctrl-left ctrl-right" {
    var r = Reader.init(-1);
    const left = "\x1b[1;5D";
    @memcpy(r.buf[0..left.len], left);
    r.len = left.len;
    try expectKey(r.parseOne().?, .ctrl_left);

    r.pos = 0;
    const right = "\x1b[1;5C";
    @memcpy(r.buf[0..right.len], right);
    r.len = right.len;
    try expectKey(r.parseOne().?, .ctrl_right);
}

test "parse alt-d" {
    var r = Reader.init(-1);
    r.buf[0] = 0x1b;
    r.buf[1] = 'd';
    r.len = 2;
    try expectKey(r.parseOne().?, .alt_d);
}

test "parse alt-y" {
    var r = Reader.init(-1);
    r.buf[0] = 0x1b;
    r.buf[1] = 'y';
    r.len = 2;
    try expectKey(r.parseOne().?, .alt_y);
}

test "parse ctrl-y" {
    var r = Reader.init(-1);
    r.buf[0] = 0x19;
    r.len = 1;
    try expectKey(r.parseOne().?, .ctrl_y);
}

test "parse ctrl-shift-z kitty protocol" {
    var r = Reader.init(-1);
    const seq = "\x1b[122;6u";
    @memcpy(r.buf[0..seq.len], seq);
    r.len = seq.len;
    try expectKey(r.parseOne().?, .ctrl_shift_z);
}

test "parse ctrl-close-bracket" {
    var r = Reader.init(-1);
    r.buf[0] = 0x1d;
    r.len = 1;
    try expectKey(r.parseOne().?, .ctrl_close_bracket);
}

test "reader emits notify event from notify fd" {
    const in_pipe = try std.posix.pipe2(.{
        .NONBLOCK = true,
        .CLOEXEC = true,
    });
    defer std.posix.close(in_pipe[0]);
    defer std.posix.close(in_pipe[1]);

    const notify_pipe = try std.posix.pipe2(.{
        .NONBLOCK = true,
        .CLOEXEC = true,
    });
    defer std.posix.close(notify_pipe[0]);
    defer std.posix.close(notify_pipe[1]);

    var r = Reader.initWithNotify(in_pipe[0], notify_pipe[0]);
    const b = [_]u8{1};
    _ = try std.posix.write(notify_pipe[1], &b);

    const ev = r.next();
    switch (ev) {
        .notify => {},
        else => return error.TestUnexpectedResult,
    }
}

test "reader notify does not drop stdin bytes" {
    const in_pipe = try std.posix.pipe2(.{
        .NONBLOCK = true,
        .CLOEXEC = true,
    });
    defer std.posix.close(in_pipe[0]);
    defer std.posix.close(in_pipe[1]);

    const notify_pipe = try std.posix.pipe2(.{
        .NONBLOCK = true,
        .CLOEXEC = true,
    });
    defer std.posix.close(notify_pipe[0]);
    defer std.posix.close(notify_pipe[1]);

    var r = Reader.initWithNotify(in_pipe[0], notify_pipe[0]);

    const n = [_]u8{1};
    _ = try std.posix.write(notify_pipe[1], &n);
    _ = try std.posix.write(in_pipe[1], "x");

    const ev1 = r.next();
    switch (ev1) {
        .notify => {},
        else => return error.TestUnexpectedResult,
    }
    try expectKey(r.next(), .{ .char = 'x' });
}
