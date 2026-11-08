const std = @import("std");
const runtime = @import("anathame").runtime;
pub fn main(init: std.process.Init) !void {
    @import("anathame").console.init();

    var memory = try @import("anathame").ReservedBumpAllocator.init(64 * 1024 * 1024);
    defer memory.deinit();
    const a = memory.allocator();
    const raw_args = try init.minimal.args.toSlice(a);
    var positional: std.ArrayList([]const u8) = .empty;
    try positional.append(a, raw_args[0]);
    var index: usize = 1;
    var options = true;
    while (index < raw_args.len) : (index += 1) {
        const argument = raw_args[index];
        if (options and std.mem.eql(u8, argument, "--")) {
            options = false;
        } else if (options and std.mem.eql(u8, argument, "--env")) {
            index += 1;
            if (index == raw_args.len) return error.ExpectedEnvironmentAssignment;
            const assignment = raw_args[index];
            const equals = std.mem.indexOfScalar(u8, assignment, '=') orelse return error.ExpectedEnvironmentAssignment;
            try @import("anathame").environment.set(a, assignment[0..equals], assignment[equals + 1 ..]);
        } else {
            try positional.append(a, argument);
        }
    }
    const args = positional.items;
    const is_test = args.len >= 2 and std.mem.eql(u8, args[1], "test");
    const is_eval = args.len >= 2 and std.mem.eql(u8, args[1], "eval");
    if ((!is_eval and !is_test) or args.len < (if (is_test) @as(usize, 4) else 3)) {
        std.debug.print("Usage: anathame [--env NAME=value] eval <code> [first-value] [second-value]\n       anathame [--env NAME=value] test <code> [first-value] [second-value] <expected>\n", .{});
        return error.InvalidArguments;
    }
    const input_end = if (is_test) args.len - 1 else args.len;
    const input = if (input_end == 3) null else try std.mem.join(a, "; ", args[3..input_end]);
    const values = runtime.evaluate(&memory, args[2], input) catch |err| {
        std.debug.print("{s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    if (is_test) {
        runtime.expectOutput(a, values, args[args.len - 1]) catch |err| {
            std.debug.print("{s}\n", .{@errorName(err)});
            if (err == error.OutputMismatch) {
                try writeOutput(&memory, init.io, values, "Actual output:\n");
            }
            std.process.exit(1);
        };
        return;
    }
    try writeOutput(&memory, init.io, values, "");
}

fn writeOutput(memory: *@import("anathame").ReservedBumpAllocator, io: std.Io, values: []const runtime.Value, prefix: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.Writer.init(.stdout(), io, &buffer);
    try output.interface.writeAll(prefix);
    for (values, 0..) |v, i| {
        if (i > 0) try output.interface.writeAll("\n");
        const checkpoint = memory.checkpoint();
        defer memory.restore(checkpoint);
        var text: std.Io.Writer.Allocating = .init(memory.allocator());
        defer text.deinit();
        try runtime.writeValueAlloc(memory.allocator(), &text.writer, v);
        try @import("anathame").console.write(&output.interface, text.written());
    }
    try output.interface.writeAll("\n");
    try output.interface.flush();
}
