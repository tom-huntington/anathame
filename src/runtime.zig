const std = @import("std");
const ReservedBumpAllocator = @import("reserved_bump_allocator.zig").ReservedBumpAllocator;
pub const Value = struct { data: []const f64 = &.{}, shape: []const usize = &.{}, tuple: ?[]const Value = null };
pub fn expect_output(a: std.mem.Allocator, code: []const u8, input: anytype, expected: anytype) !void {
    var memory = try ReservedBumpAllocator.init(64 * 1024 * 1024);
    defer memory.deinit();
    var arguments: [input.len][]const u8 = undefined;
    inline for (input, 0..) |argument, i| arguments[i] = argument;
    const source: ?[]const u8 = if (arguments.len == 0) null else try std.mem.join(a, "\n; ", &arguments);
    defer if (source) |text| a.free(text);
    const actual = try evaluate(&memory, code, source);
    try expectOutput(a, actual, expected);
}

pub fn expectOutput(a: std.mem.Allocator, actual: []const Value, expected: anytype) !void {
    const source = if (comptime @typeInfo(@TypeOf(expected)) == .@"struct") blk: {
        var parts: [expected.len][]const u8 = undefined;
        inline for (expected, 0..) |part, i| parts[i] = part;
        break :blk try std.mem.join(a, "\n; ", &parts);
    } else @as([]const u8, expected);
    const instructions = try @import("parser.zig").parse(a, source);
    if (instructions.len != actual.len) return error.OutputMismatch;
    for (instructions, actual) |instruction, value| {
        const want = switch (instruction) {
            .literal => |literal| literal,
            else => return error.ExpectedLiteral,
        };
        if (want.tuple != null or value.tuple != null) return error.ExpectedArray;
        if (!std.mem.eql(usize, want.shape, value.shape) or !std.mem.eql(f64, want.data, value.data))
            return error.OutputMismatch;
    }
}

/// Composition defaults to B; explicit N and S retain the scope's x.
/// Parsing allocations and returned values live until memory is reset or deinitialized.
pub fn evaluate(memory: *ReservedBumpAllocator, code: []const u8, input: ?[]const u8) ![]const Value {
    const a = memory.allocator();
    const program = try @import("parser.zig").parseProgram(a, code);
    const arity = program.scope.arity;
    const arguments = if (input) |source| blk: {
        const parsed = try @import("parser.zig").parse(a, source);
        const values = try a.alloc(Value, parsed.len);
        for (parsed, values) |instruction, *value| value.* = switch (instruction) {
            .literal => |literal| literal,
            else => return error.InvalidInput,
        };
        break :blk values;
    } else program.scope.default_arguments orelse return error.WrongNumberOfArguments;
    if (arguments.len != arity) return error.WrongNumberOfArguments;
    const x = arguments[0];
    const y = if (arity == 1) x else arguments[1];
    const result = try evaluateScope(memory, program.scope.instructions, x, y);
    return if (result.tuple) |tuple| tuple else a.dupe(Value, &.{result});
}

fn evaluateScope(memory: *ReservedBumpAllocator, instructions: []const @import("parser.zig").Instruction, x: Value, y: Value) anyerror!Value {
    var result = y;
    const checkpoint = memory.checkpoint();
    var retain_x = false;
    var first_function = true;
    for (instructions) |instruction| {
        if (instruction == .combinator) {
            retain_x = instruction.combinator != .b;
            continue;
        }
        const first_argument = if (first_function) x else result;
        const second_argument = if (first_function) y else if (retain_x) x else result;
        if (instruction == .scope) {
            const defaults = instruction.scope.default_arguments;
            const first = if (defaults) |args| args[0] else first_argument;
            const second = if (instruction.scope.arity == 1) first else if (defaults) |args| args[1] else second_argument;
            const temporary = try evaluateScope(memory, instruction.scope.instructions, first, second);
            result = try @import("memory.zig").ReturnImpl(memory, checkpoint, temporary);
            first_function = false;
            retain_x = false;
            continue;
        }
        const name = switch (instruction) {
            .primitive => |name| name,
            .partial => |partial| partial.name,
            else => return error.ExpectedFunction,
        };
        const function = @import("primitives.zig").lookup(name) orelse return error.UnimplementedPrimitive;
        const temporary = if (instruction == .partial)
            try function(memory.allocator(), result, instruction.partial.argument)
        else
            try function(memory.allocator(), first_argument, second_argument);
        result = try @import("memory.zig").ReturnImpl(memory, checkpoint, temporary);
        first_function = false;
        retain_x = false;
    }
    return result;
}
pub fn writeValue(w: *std.Io.Writer, value: Value) std.Io.Writer.Error!void {
    if (value.tuple) |tuple| {
        try w.writeAll("( ");
        for (tuple, 0..) |item, i| {
            if (i > 0) try w.writeAll(", ");
            try writeValue(w, item);
        }
        return w.writeAll(" )");
    }
    if (value.shape.len == 0) return w.print("{d}", .{value.data[0]});
    try w.writeAll("[");
    const stride = if (value.shape[0] == 0) 0 else value.data.len / value.shape[0];
    for (0..value.shape[0]) |i| {
        if (i > 0) try w.writeAll(" ");
        try writeValue(w, .{ .data = value.data[i * stride ..][0..stride], .shape = value.shape[1..] });
    }
    try w.writeAll("]");
}
