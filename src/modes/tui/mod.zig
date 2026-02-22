const contract = @import("../contract.zig");

pub const frame = @import("frame.zig");
pub const render = @import("render.zig");
pub const editor = @import("editor.zig");
pub const input = @import("input.zig");
pub const transcript = @import("transcript.zig");
pub const panels = @import("panels.zig");
pub const harness = @import("harness.zig");
pub const markdown = @import("markdown.zig");
pub const syntax = @import("syntax.zig");
pub const theme = @import("theme.zig");
pub const wcwidth = @import("wcwidth.zig");
pub const mouse = @import("mouse.zig");
pub const overlay = @import("overlay.zig");
pub const cmdprev = @import("cmdprev.zig");
pub const fuzzy = @import("fuzzy.zig");
pub const pathcomp = @import("pathcomp.zig");
pub const imgproto = @import("imgproto.zig");
pub const termcap = @import("termcap.zig");
pub const term = @import("term.zig");
pub const vscreen = @import("vscreen.zig");
pub const fixture = @import("fixture.zig");

pub const Mode = struct {
    pub fn asMode(self: *Mode) contract.Mode {
        return contract.Mode.from(Mode, self, run);
    }

    fn run(_: *Mode, _: contract.RunCtx) !void {}
};
