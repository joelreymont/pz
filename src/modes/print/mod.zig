const contract = @import("../contract.zig");
const run_impl = @import("run.zig");
pub const errors = @import("errors.zig");

pub const Mode = struct {
    pub fn asMode(self: *Mode) contract.Mode {
        return contract.Mode.from(Mode, self, run);
    }

    fn run(_: *Mode, run_ctx: contract.RunCtx) !void {
        return run_impl.exec(run_ctx);
    }
};
