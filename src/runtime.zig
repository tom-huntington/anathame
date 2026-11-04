const std = @import("std");
pub const Value = struct { data: []const f64, shape: []const usize };
pub fn run_test(a: std.mem.Allocator, code: []const u8, input: []const u8, expected: []const u8) !void {
    const actual = try evaluate(a, code, input);
    try expectOutput(a, actual, expected);
}

pub fn expectOutput(a: std.mem.Allocator, actual: []const Value, expected: []const u8) !void {
    const normalized = try std.mem.replaceOwned(u8, a, expected, ",", " ");
    const instructions = try @import("parser.zig").parse(a, normalized);
    if (instructions.len != actual.len) return error.OutputMismatch;
    for (instructions, actual) |instruction, value| {
        const want = switch (instruction) {
            .literal => |literal| literal,
            else => return error.ExpectedLiteral,
        };
        if (!std.mem.eql(usize, want.shape, value.shape) or !std.mem.eql(f64, want.data, value.data))
            return error.OutputMismatch;
    }
}

/// Trains retain x: (f g)(x,y) = g(f(x,y),x), or (f g)(x) = g(f(x),x).
pub fn evaluate(a: std.mem.Allocator, code: []const u8, input: []const u8) ![]const Value {
    const instructions = try @import("parser.zig").parse(a, code);
    if (instructions.len == 0) return error.EmptyProgram;
    const first_name = switch (instructions[0]) {
        .primitive => |name| name,
        .partial => |partial| partial.name,
        else => return error.ExpectedFunction,
    };
    const arity = if (instructions[0] == .partial) 1 else @import("primitives.zig").arity(first_name);
    const arguments = try @import("parser.zig").parse(a, input);
    if (arguments.len != arity) return error.WrongNumberOfArguments;
    const x = switch (arguments[0]) {
        .literal => |value| value,
        else => return error.InvalidInput,
    };
    var result = if (arity == 1) x else switch (arguments[1]) {
        .literal => |value| value,
        else => return error.InvalidInput,
    };
    var memory = try @import("reserved_bump_allocator.zig").ReservedBumpAllocator.init(64 * 1024 * 1024);
    defer memory.deinit();
    const checkpoint = memory.checkpoint();
    for (instructions, 0..) |instruction, i| {
        const name = switch (instruction) {
            .primitive => |name| name,
            .partial => |partial| partial.name,
            else => return error.ExpectedFunction,
        };
        const function = @import("primitives.zig").lookup(name) orelse return error.UnimplementedPrimitive;
        const temporary = if (instruction == .partial)
            try function(memory.allocator(), result, instruction.partial.argument)
        else if (i == 0) try function(memory.allocator(), x, result) else try function(memory.allocator(), result, x);
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
