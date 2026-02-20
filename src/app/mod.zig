const std = @import("std");

pub const args = @import("args.zig");
pub const cli = @import("cli.zig");
pub const config = @import("config.zig");
pub const runtime = @import("runtime.zig");

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
        .run => |run_cmd| {
            const sid = try runtime.exec(alloc, run_cmd);
            alloc.free(sid);
        },
    }
}
