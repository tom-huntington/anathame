const std = @import("std");
const runtime = @import("anathame").runtime;
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len < 2) {
        std.debug.print("Usage: anathame <code> <first-scalar> [second-scalar]\n", .{});
        return error.InvalidArguments;
    }
    const values = runtime.evaluate(a, args[1], try std.mem.join(a, "; ", args[2..])) catch |err| {
        std.debug.print("{s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.Writer.init(.stdout(), init.io, &buffer);
    for (values, 0..) |v, i| {
        if (i > 0) try output.interface.writeAll("\n");
        try runtime.writeValue(&output.interface, v);
    }
    try output.interface.writeAll("\n");
    try output.interface.flush();
}
