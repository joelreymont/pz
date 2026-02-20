const app_cli = @import("app/cli.zig");
const app_runtime = @import("app/runtime.zig");
const core_loop = @import("core/loop.zig");
const sess = @import("core/session/mod.zig");
const tools = @import("core/tools/mod.zig");
const prov = @import("core/providers/first_provider.zig");
const mode_contract = @import("modes/contract.zig");
const print_run = @import("modes/print/run.zig");
const tui_harness = @import("modes/tui/harness.zig");
const perf_baseline = @import("perf/baseline.zig");

test "all module tests" {
    _ = app_cli;
    _ = app_runtime;
    _ = core_loop;
    _ = sess;
    _ = tools;
    _ = prov;
    _ = mode_contract;
    _ = print_run;
    _ = tui_harness;
    _ = perf_baseline;
}
