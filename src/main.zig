const std = @import("std");
const runtime = @import("anathame").runtime;
pub fn main(init: std.process.Init) !void {
    @import("console.zig").init();

    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    const is_test = args.len >= 2 and std.mem.eql(u8, args[1], "test");
    const is_eval = args.len >= 2 and std.mem.eql(u8, args[1], "eval");
    if ((!is_eval and !is_test) or args.len < (if (is_test) @as(usize, 4) else 3)) {
        std.debug.print("Usage: anathame eval <code> [first-value] [second-value]\n       anathame test <code> [first-value] [second-value] <expected>\n", .{});
        return error.InvalidArguments;
    }
    const input_end = if (is_test) args.len - 1 else args.len;
    const input = if (input_end == 3) null else try std.mem.join(a, "; ", args[3..input_end]);
    var memory = try @import("anathame").ReservedBumpAllocator.init(64 * 1024 * 1024);
    defer memory.deinit();
    const values = runtime.evaluate(&memory, args[2], input) catch |err| {
        std.debug.print("{s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    if (is_test) {
        runtime.expectOutput(a, values, args[args.len - 1]) catch |err| {
            std.debug.print("{s}\n", .{@errorName(err)});
            if (err == error.OutputMismatch) {
                try writeOutput(init.io, values, "Actual output:\n");
            }
            std.process.exit(1);
        };
        return;
    }
    try writeOutput(init.io, values, "");
}

fn writeOutput(io: std.Io, values: []const runtime.Value, prefix: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.Writer.init(.stdout(), io, &buffer);
    try output.interface.writeAll(prefix);
    for (values, 0..) |v, i| {
        if (i > 0) try output.interface.writeAll("\n");
        try runtime.writeValue(&output.interface, v);
    }
    try output.interface.writeAll("\n");
    try output.interface.flush();
}
