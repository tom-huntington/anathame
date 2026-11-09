const std = @import("std");
const Value = @import("runtime.zig").Value;

pub fn printResult(a: std.mem.Allocator, result: Value) !void {
    try printArguments(a, result, null, false, "result:\n");
}

pub fn printArguments(a: std.mem.Allocator, x: Value, y: ?Value, strings: bool, prefix: ?[]const u8) !void {
    // Grid formatting allocates per-cell strings and layout buffers. None of
    // these may outlive logging, even when formatting exhausts the reservation.
    const memory = @import("reserved_bump_allocator.zig").ReservedBumpAllocator.fromAllocator(a);
    const checkpoint = if (memory) |m| m.checkpoint() else 0;
    defer if (memory) |m| m.restore(checkpoint);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var text: std.Io.Writer.Allocating = .init(arena.allocator());
    defer text.deinit();
    formatArguments(arena.allocator(), &text.writer, x, y, strings, prefix) catch |err| switch (err) {
        // The only writer here is Allocating: WriteFailed means buffer OOM.
        error.OutOfMemory, error.WriteFailed => {
            try writeText("Value was not displayed due to not enough memory.\n");
            return;
        },
        else => return err,
    };
    try writeText(text.written());
}

fn formatArguments(a: std.mem.Allocator, writer: *std.Io.Writer, x: Value, y: ?Value, strings: bool, prefix: ?[]const u8) !void {
    if (prefix) |label| try writer.writeAll(label);
    if (y != null) try writer.writeAll("left arg:\n");
    if (strings) try @import("display.zig").writeString(a, writer, x) else try @import("runtime.zig").writeValueAlloc(a, writer, x);
    if (y) |right| {
        try writer.writeAll("\nright arg:\n");
        try @import("runtime.zig").writeValueAlloc(a, writer, right);
    }
    try writer.writeAll("\n");
}

fn writeText(text: []const u8) !void {
    @import("console.zig").init();
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.Writer.init(.stdout(), std.Io.Threaded.global_single_threaded.io(), &buffer);
    try @import("console.zig").write(&output.interface, text);
    try output.interface.flush();
}

/// Report completed iterations without converting the counter to a float.
pub fn printIteration(iteration: usize) !void {
    var buffer: [64]u8 = undefined;
    var output = std.Io.File.Writer.init(.stdout(), std.Io.Threaded.global_single_threaded.io(), &buffer);
    try output.interface.print("{d}\n", .{iteration});
    try output.interface.flush();
}
