const std = @import("std");
const stream_parse = @import("../core/providers/stream_parse.zig");
const providers = @import("../core/providers/contract.zig");

const parse_gate_ns: i128 = 10 * std.time.ns_per_s;

test "performance baseline parser hot path stays under gate" {
    const chunks = [_][]const u8{
        "text:alpha\nthinking:beta\nusage:3,5,8\nstop:done\n",
    };

    const iters: usize = 2000;
    var total_evs: usize = 0;

    const started = std.time.nanoTimestamp();
    var i: usize = 0;
    while (i < iters) : (i += 1) {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const ar = arena.allocator();

        var parser = stream_parse.Parser{};
        defer parser.deinit(ar);

        var evs: std.ArrayListUnmanaged(providers.Ev) = .{};
        defer evs.deinit(ar);

        for (chunks) |chunk| {
            try parser.feed(ar, &evs, chunk);
        }
        try parser.finish(ar, &evs);
        total_evs += evs.items.len;
    }
    const elapsed = std.time.nanoTimestamp() - started;

    try std.testing.expectEqual(iters * 4, total_evs);
    try std.testing.expect(elapsed < parse_gate_ns);
}
