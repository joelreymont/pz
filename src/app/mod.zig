const std = @import("std");

pub const args = @import("args.zig");
pub const cli = @import("cli.zig");
pub const config = @import("config.zig");
pub const report = @import("report.zig");
pub const runtime = @import("runtime.zig");
pub const update = @import("update.zig");

pub fn run() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const alloc = arena.allocator();
    const argv = try std.process.argsAlloc(alloc);
    var env = try config.Env.fromProcess(alloc);
    defer env.deinit(alloc);
    var out = std.fs.File.stdout().deprecatedWriter();

    var cmd = cli.parse(alloc, std.fs.cwd(), argv[1..], env) catch |err| {
        if (err == error.OutOfMemory) return err;
        const msg = try report.cli(alloc, "parse arguments", err);
        defer alloc.free(msg);
        try out.writeAll(msg);
        return;
    };
    defer cmd.deinit(alloc);

    switch (cmd) {
        .help => |txt| try out.writeAll(txt),
        .version => |txt| try out.writeAll(txt),
        .changelog => |txt| try out.writeAll(txt),
        .upgrade => {
            const outcome = try update.runOutcome(alloc);
            defer outcome.deinit(alloc);
            try out.writeAll(outcome.msg);
        },
        .run => |run_cmd| {
            const sid = runtime.exec(alloc, run_cmd) catch |err| {
                if (err == error.OutOfMemory) return err;
                const msg = try report.cli(alloc, "run command", err);
                defer alloc.free(msg);
                try out.writeAll(msg);
                return;
            };
            alloc.free(sid);
        },
    }
}
