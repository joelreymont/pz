const contract = @import("../contract.zig");

pub const frame = @import("frame.zig");
pub const render = @import("render.zig");
pub const editor = @import("editor.zig");
pub const input = editor;
pub const transcript = @import("transcript.zig");
pub const panels = @import("panels.zig");
pub const harness = @import("harness.zig");

pub const Mode = struct {
    pub fn asMode(self: *Mode) contract.Mode {
        return contract.Mode.from(Mode, self, run);
    }

    fn run(_: *Mode, _: contract.RunCtx) !void {}
};
