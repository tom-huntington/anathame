const std = @import("std");
const Value = @import("runtime.zig").Value;

pub fn printResult(a: std.mem.Allocator, result: Value) !void {
    try printArguments(a, result, null, false, "result:\n");
}

pub fn printArguments(a: std.mem.Allocator, x: Value, y: ?Value, strings: bool, prefix: ?[]const u8) !void {
    var text: std.Io.Writer.Allocating = .init(a);
    defer text.deinit();
    if (prefix) |label| try text.writer.writeAll(label);
    if (y != null) try text.writer.writeAll("left arg:\n");
    if (strings) try @import("display.zig").writeString(a, &text.writer, x) else try @import("runtime.zig").writeValueAlloc(a, &text.writer, x);
    if (y) |right| {
        try text.writer.writeAll("\nright arg:\n");
        try @import("runtime.zig").writeValueAlloc(a, &text.writer, right);
    }
    try text.writer.writeAll("\n");
    @import("console.zig").init();
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.Writer.init(.stdout(), std.Io.Threaded.global_single_threaded.io(), &buffer);
    try @import("console.zig").write(&output.interface, text.written());
    try output.interface.flush();
}
