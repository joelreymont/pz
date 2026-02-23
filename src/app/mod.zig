const std = @import("std");

pub const args = @import("args.zig");
pub const cli = @import("cli.zig");
pub const config = @import("config.zig");
pub const runtime = @import("runtime.zig");
pub const update = @import("update.zig");

pub fn run() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const alloc = arena.allocator();
    const argv = try std.process.argsAlloc(alloc);
    var env = try config.Env.fromProcess(alloc);
    defer env.deinit(alloc);

    var cmd = try cli.parse(alloc, std.fs.cwd(), argv[1..], env);
    defer cmd.deinit(alloc);

    var out = std.fs.File.stdout().deprecatedWriter();
    switch (cmd) {
        .help => |txt| try out.writeAll(txt),
        .version => |txt| try out.writeAll(txt),
        .changelog => |txt| try out.writeAll(txt),
        .upgrade => {
            const msg = try update.run(alloc);
            defer alloc.free(msg);
            try out.writeAll(msg);
        },
        .run => |run_cmd| {
            const sid = try runtime.exec(alloc, run_cmd);
            alloc.free(sid);
        },
    }
}
