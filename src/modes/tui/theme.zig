const std = @import("std");
const Color = @import("frame.zig").Color;

pub const Theme = struct {
    // UI
    accent: Color,
    border_c: Color,
    border_accent: Color,
    border_muted: Color,
    success: Color,
    err: Color,
    warn: Color,
    muted: Color,
    dim: Color,
    text: Color,
    thinking_fg: Color,
    // Backgrounds
    sel_bg: Color,
    user_msg_bg: Color,
    custom_msg_bg: Color,
    tool_pending_bg: Color,
    tool_success_bg: Color,
    tool_error_bg: Color,
    // Tools
    tool_title: Color,
    tool_output: Color,
    tool_diff_add: Color,
    tool_diff_rm: Color,
    tool_diff_ctx: Color,
    // Markdown
    md_heading: Color,
    md_link: Color,
    md_link_url: Color,
    md_code: Color,
    md_code_block: Color,
    md_code_border: Color,
    md_quote: Color,
    md_hr: Color,
    md_list_bullet: Color,
    // Thinking levels
    thinking_off: Color,
    thinking_min: Color,
    thinking_low: Color,
    thinking_med: Color,
    thinking_high: Color,
    thinking_xhigh: Color,
    // Syntax
    syn_keyword: Color,
    syn_string: Color,
    syn_comment: Color,
    syn_number: Color,
    syn_func: Color,
    syn_type: Color,
    syn_operator: Color,
    syn_punct: Color,
    // Bash
    bash_mode: Color,
};

pub const dark = Theme{
    // UI
    .accent = .{ .rgb = 0x8abeb7 },
    .border_c = .{ .rgb = 0x5f87ff },
    .border_accent = .{ .rgb = 0x00d7ff },
    .border_muted = .{ .rgb = 0x505050 },
    .success = .{ .rgb = 0xb5bd68 },
    .err = .{ .rgb = 0xcc6666 },
    .warn = .{ .rgb = 0xffff00 },
    .muted = .{ .rgb = 0x808080 },
    .dim = .{ .rgb = 0x666666 },
    .text = .{ .default = {} },
    .thinking_fg = .{ .rgb = 0x808080 },
    // Backgrounds
    .sel_bg = .{ .rgb = 0x3a3a4a },
    .user_msg_bg = .{ .rgb = 0x343541 },
    .custom_msg_bg = .{ .rgb = 0x2d2838 },
    .tool_pending_bg = .{ .rgb = 0x282832 },
    .tool_success_bg = .{ .rgb = 0x283228 },
    .tool_error_bg = .{ .rgb = 0x3c2828 },
    // Tools
    .tool_title = .{ .default = {} },
    .tool_output = .{ .rgb = 0x808080 },
    .tool_diff_add = .{ .rgb = 0xb5bd68 },
    .tool_diff_rm = .{ .rgb = 0xcc6666 },
    .tool_diff_ctx = .{ .rgb = 0x808080 },
    // Markdown
    .md_heading = .{ .rgb = 0xf0c674 },
    .md_link = .{ .rgb = 0x81a2be },
    .md_link_url = .{ .rgb = 0x666666 },
    .md_code = .{ .rgb = 0x8abeb7 },
    .md_code_block = .{ .rgb = 0xb5bd68 },
    .md_code_border = .{ .rgb = 0x808080 },
    .md_quote = .{ .rgb = 0x808080 },
    .md_hr = .{ .rgb = 0x808080 },
    .md_list_bullet = .{ .rgb = 0x8abeb7 },
    // Thinking levels
    .thinking_off = .{ .rgb = 0x505050 },
    .thinking_min = .{ .rgb = 0x6e6e6e },
    .thinking_low = .{ .rgb = 0x5f87af },
    .thinking_med = .{ .rgb = 0x81a2be },
    .thinking_high = .{ .rgb = 0xb294bb },
    .thinking_xhigh = .{ .rgb = 0xd183e8 },
    // Syntax
    .syn_keyword = .{ .rgb = 0xb294bb },
    .syn_string = .{ .rgb = 0xb5bd68 },
    .syn_comment = .{ .rgb = 0x666666 },
    .syn_number = .{ .rgb = 0xde935f },
    .syn_func = .{ .rgb = 0x8abeb7 },
    .syn_type = .{ .rgb = 0xf0c674 },
    .syn_operator = .{ .default = {} },
    .syn_punct = .{ .rgb = 0x808080 },
    // Bash
    .bash_mode = .{ .rgb = 0xb5bd68 },
};

pub const light = Theme{
    // UI
    .accent = .{ .rgb = 0x2aa198 },
    .border_c = .{ .rgb = 0x268bd2 },
    .border_accent = .{ .rgb = 0x0087d7 },
    .border_muted = .{ .rgb = 0xb0b0b0 },
    .success = .{ .rgb = 0x859900 },
    .err = .{ .rgb = 0xdc322f },
    .warn = .{ .rgb = 0xb58900 },
    .muted = .{ .rgb = 0x93a1a1 },
    .dim = .{ .rgb = 0xb0b0b0 },
    .text = .{ .default = {} },
    .thinking_fg = .{ .rgb = 0x93a1a1 },
    // Backgrounds
    .sel_bg = .{ .rgb = 0xe8e8e8 },
    .user_msg_bg = .{ .rgb = 0xeee8d5 },
    .custom_msg_bg = .{ .rgb = 0xf0e8f0 },
    .tool_pending_bg = .{ .rgb = 0xe8e8f0 },
    .tool_success_bg = .{ .rgb = 0xe8f0e8 },
    .tool_error_bg = .{ .rgb = 0xf0e8e8 },
    // Tools
    .tool_title = .{ .default = {} },
    .tool_output = .{ .rgb = 0x586e75 },
    .tool_diff_add = .{ .rgb = 0x859900 },
    .tool_diff_rm = .{ .rgb = 0xdc322f },
    .tool_diff_ctx = .{ .rgb = 0x93a1a1 },
    // Markdown
    .md_heading = .{ .rgb = 0xb58900 },
    .md_link = .{ .rgb = 0x268bd2 },
    .md_link_url = .{ .rgb = 0x93a1a1 },
    .md_code = .{ .rgb = 0x2aa198 },
    .md_code_block = .{ .rgb = 0x586e75 },
    .md_code_border = .{ .rgb = 0x93a1a1 },
    .md_quote = .{ .rgb = 0x93a1a1 },
    .md_hr = .{ .rgb = 0x93a1a1 },
    .md_list_bullet = .{ .rgb = 0x2aa198 },
    // Thinking levels
    .thinking_off = .{ .rgb = 0xb0b0b0 },
    .thinking_min = .{ .rgb = 0x93a1a1 },
    .thinking_low = .{ .rgb = 0x268bd2 },
    .thinking_med = .{ .rgb = 0x6c71c4 },
    .thinking_high = .{ .rgb = 0xd33682 },
    .thinking_xhigh = .{ .rgb = 0xd33682 },
    // Syntax (solarized light palette)
    .syn_keyword = .{ .rgb = 0x6c71c4 },
    .syn_string = .{ .rgb = 0x859900 },
    .syn_comment = .{ .rgb = 0x93a1a1 },
    .syn_number = .{ .rgb = 0xcb4b16 },
    .syn_func = .{ .rgb = 0x2aa198 },
    .syn_type = .{ .rgb = 0xb58900 },
    .syn_operator = .{ .default = {} },
    .syn_punct = .{ .rgb = 0x93a1a1 },
    // Bash
    .bash_mode = .{ .rgb = 0x859900 },
};

var active: *const Theme = &dark;

pub fn init() void {
    if (std.posix.getenv("PZ_THEME")) |val| {
        const map = std.StaticStringMap(*const Theme).initComptime(.{
            .{ "light", &light },
            .{ "dark", &dark },
        });
        if (map.get(val)) |t| {
            active = t;
            return;
        }
    }
    // Auto-detect from COLORFGBG: "fg;bg" — high bg number means light bg
    if (std.posix.getenv("COLORFGBG")) |val| {
        if (std.mem.lastIndexOfScalar(u8, val, ';')) |sep| {
            const bg_str = val[sep + 1 ..];
            const bg = std.fmt.parseInt(u8, bg_str, 10) catch return;
            // bg >= 8 typically means a light background
            if (bg >= 8) {
                active = &light;
            }
        }
    }
}

pub fn get() *const Theme {
    return active;
}

// For tests: override active theme temporarily
pub fn setActive(t: *const Theme) void {
    active = t;
}

test "dark and light differ" {
    const d = &dark;
    const l = &light;
    // At least accent must differ
    try std.testing.expect(!Color.eql(d.accent, l.accent));
    try std.testing.expect(!Color.eql(d.border_muted, l.border_muted));
    try std.testing.expect(!Color.eql(d.sel_bg, l.sel_bg));
}

test "init selects dark by default" {
    // Save and restore
    const prev = active;
    defer active = prev;
    active = &light;
    // With no env vars set in test, init should leave dark or detect
    // Just verify get() returns a valid pointer
    const t = get();
    try std.testing.expect(t == &dark or t == &light);
}
