const std = @import("std");
pub const Value = struct { data: []const f64, shape: []const usize };
/// Adjacent functions form a left-associated N train: (f g)(x,y) = g(f(x,y),x).
pub fn evaluate(a: std.mem.Allocator, code: []const u8, input: []const u8) ![]const Value {
    const instructions = try @import("parser.zig").parse(a, code);
    var arguments = std.mem.splitScalar(u8, input, ';');
    const left = arguments.next().?;
    const right = arguments.next() orelse return error.StackUnderflow;
    if (arguments.next() != null) return error.InvalidInput;
    const xv = try scalarArgument(left);
    const yv = try scalarArgument(right);
    if (instructions.len == 0) return error.EmptyProgram;
    var memory = try @import("reserved_bump_allocator.zig").ReservedBumpAllocator.init(64 * 1024 * 1024);
    defer memory.deinit();
    const checkpoint = memory.checkpoint();
    const x: Value = .{ .data = &.{xv}, .shape = &.{} };
    var result: Value = .{ .data = &.{yv}, .shape = &.{} };
    for (instructions, 0..) |instruction, i| {
        const name = switch (instruction) {
            .primitive => |name| name,
            else => return error.ExpectedFunction,
        };
        const function = @import("primitives.zig").lookup(name) orelse return error.UnimplementedPrimitive;
        const temporary = if (i == 0) try function(memory.allocator(), x, result) else try function(memory.allocator(), result, x);
        result = try @import("memory.zig").ReturnImpl(&memory, checkpoint, temporary);
    }
    return a.dupe(Value, &.{.{ .data = try a.dupe(f64, result.data), .shape = try a.dupe(usize, result.shape) }});
}
pub fn writeValue(w: *std.Io.Writer, value: Value) std.Io.Writer.Error!void {
    if (value.shape.len == 0) return w.print("{d}", .{value.data[0]});
    try w.writeAll("[");
    const stride = if (value.shape[0] == 0) 0 else value.data.len / value.shape[0];
    for (0..value.shape[0]) |i| {
        if (i > 0) try w.writeAll(" ");
        try writeValue(w, .{ .data = value.data[i * stride ..][0..stride], .shape = value.shape[1..] });
    }
    try w.writeAll("]");
}

fn scalarArgument(source: []const u8) !f64 {
    const text = std.mem.trim(u8, source, " \t\r\n");
    if (std.mem.indexOfAny(u8, text, "[]") != null) return error.ArrayArgumentsNotSupported;
    const value = std.fmt.parseFloat(f64, text) catch return error.InvalidInput;
    if (!std.math.isFinite(value)) return error.InvalidInput;
    return value;
}
