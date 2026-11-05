const std = @import("std");
const ReservedBumpAllocator = @import("reserved_bump_allocator.zig").ReservedBumpAllocator;
pub const Value = struct { data: []const f64 = &.{}, shape: []const usize = &.{}, tuple: ?[]const Value = null };
pub fn expect_output(a: std.mem.Allocator, code: []const u8, input: anytype, expected: anytype) !void {
    var memory = try ReservedBumpAllocator.init(64 * 1024 * 1024);
    defer memory.deinit();
    const source: ?[]const u8 = if (comptime @typeInfo(@TypeOf(input)) == .@"struct") blk: {
        var arguments: [input.len][]const u8 = undefined;
        inline for (input, 0..) |argument, i| arguments[i] = argument;
        break :blk if (arguments.len == 0) null else try std.mem.join(a, "\n; ", &arguments);
    } else try a.dupe(u8, @as([]const u8, input));
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
    var mismatch = false;
    errdefer if (mismatch) {
        var output = std.Io.Writer.Allocating.init(a);
        defer output.deinit();
        for (actual, 0..) |value, i| {
            if (i > 0) output.writer.writeAll("\n; ") catch break;
            writeValue(&output.writer, value) catch break;
        }
        std.debug.print("expected:\n{s}\nactual:\n{s}\n", .{ source, output.written() });
    };
    const instructions = try @import("parser.zig").parse(a, source);
    if (instructions.len != actual.len) {
        mismatch = true;
        return error.OutputMismatch;
    }
    for (instructions, actual) |instruction, value| {
        const want = switch (instruction) {
            .literal => |literal| literal,
            else => return error.ExpectedLiteral,
        };
        if (want.tuple != null or value.tuple != null) return error.ExpectedArray;
        if (!std.mem.eql(usize, want.shape, value.shape) or !std.mem.eql(f64, want.data, value.data)) {
            mismatch = true;
            return error.OutputMismatch;
        }
    }
}

/// Composition defaults to B; explicit N, s, and sig retain the scope's x.
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
    var reverse_arguments = false;
    var first_function = true;
    var skip: usize = 0;
    for (instructions, 0..) |instruction, index| {
        if (skip > 0) {
            skip -= 1;
            continue;
        }
        if (instruction == .combinator and instruction.combinator == .psi) {
            if (index == 0 or index + 1 == instructions.len) return error.ExpectedFunction;
            const function = instructions[index + 1];
            if (functionArity(function) != 2) return error.WrongNumberOfArguments;
            const right = try evaluateScope(memory, instructions[0..index], y, y);
            const temporary = try evaluateScope(memory, &.{function}, result, right);
            result = try @import("memory.zig").ReturnImpl(memory, checkpoint, temporary);
            skip = 1;
            first_function = false;
            retain_x = false;
            reverse_arguments = false;
            continue;
        }
        if (instruction == .combinator and instruction.combinator == .phi) {
            const remaining = instructions[index + 1 ..];
            const temporary = if (result.tuple) |tuple| blk: {
                if (tuple.len != 2) return error.WrongNumberOfArguments;
                if (remaining.len < 1) return error.ExpectedFunction;
                if (functionArity(remaining[0]) == 1) {
                    if (remaining.len < 3) return error.ExpectedFunction;
                    if (functionArity(remaining[1]) != 1 or functionArity(remaining[2]) != 2) return error.WrongNumberOfArguments;
                    const left = try evaluateScope(memory, remaining[0..1], tuple[0], tuple[0]);
                    const right = try evaluateScope(memory, remaining[1..2], tuple[1], tuple[1]);
                    skip = 3;
                    break :blk try evaluateScope(memory, remaining[2..3], left, right);
                }
                if (functionArity(remaining[0]) != 2) return error.WrongNumberOfArguments;
                skip = 1;
                break :blk try evaluateScope(memory, remaining[0..1], tuple[0], tuple[1]);
            } else blk: {
                if (remaining.len < 2) return error.ExpectedFunction;
                if (functionArity(remaining[0]) != 1 or functionArity(remaining[1]) != 2) return error.WrongNumberOfArguments;
                const branch = try evaluateScope(memory, remaining[0..1], x, x);
                skip = 2;
                break :blk try evaluateScope(memory, remaining[1..2], result, branch);
            };
            result = try @import("memory.zig").ReturnImpl(memory, checkpoint, temporary);
            first_function = false;
            retain_x = false;
            reverse_arguments = false;
            continue;
        }
        if (instruction == .combinator) {
            retain_x = instruction.combinator != .b;
            reverse_arguments = instruction.combinator == .sig;
            continue;
        }
        const first_argument = if (first_function or reverse_arguments) x else result;
        const second_argument = if (first_function) y else if (reverse_arguments) result else if (retain_x) x else result;
        reverse_arguments = false;
        if (instruction == .product) {
            const temporary = try product(memory, instruction.product, first_argument, second_argument);
            result = try @import("memory.zig").ReturnImpl(memory, checkpoint, temporary);
            first_function = false;
            retain_x = false;
            continue;
        }
        if (instruction == .cases) {
            const temporary = try cases(memory.allocator(), first_argument, instruction.cases);
            result = try @import("memory.zig").ReturnImpl(memory, checkpoint, temporary);
            first_function = false;
            retain_x = false;
            continue;
        }
        if (instruction == .unc) {
            if (functionArity(instruction.unc.*) != 2) return error.WrongNumberOfArguments;
            const pair = if (first_argument.tuple) |tuple| blk: {
                if (tuple.len != 2) return error.WrongNumberOfArguments;
                break :blk [2]Value{ tuple[0], tuple[1] };
            } else blk: {
                if (first_argument.shape.len == 0 or first_argument.shape[0] != 2) return error.WrongNumberOfArguments;
                break :blk [2]Value{
                    try rowArgument(memory.allocator(), first_argument, 0),
                    try rowArgument(memory.allocator(), first_argument, 1),
                };
            };
            const temporary = try evaluateScope(memory, &.{instruction.unc.*}, pair[0], pair[1]);
            result = try @import("memory.zig").ReturnImpl(memory, checkpoint, temporary);
            first_function = false;
            retain_x = false;
            continue;
        }
        if (instruction == .partition) {
            const temporary = try partition(memory, first_argument, second_argument, instruction.partition);
            result = try @import("memory.zig").ReturnImpl(memory, checkpoint, temporary);
            first_function = false;
            retain_x = false;
            continue;
        }
        if (instruction == .reduce or instruction == .stencil) {
            const temporary = if (instruction == .reduce)
                try reduce(memory, first_argument, instruction.reduce)
            else
                try stencil(memory, first_argument, second_argument, instruction.stencil);
            result = try @import("memory.zig").ReturnImpl(memory, checkpoint, temporary);
            first_function = false;
            retain_x = false;
            continue;
        }
        if (instruction == .scan or instruction == .rows or instruction == .filter) {
            const temporary = if (instruction == .rows)
                try rows(memory, first_argument, second_argument, instruction.rows)
            else if (instruction == .filter)
                try filter(memory, first_argument, instruction.filter)
            else
                try scan(memory, first_argument, instruction.scan);
            result = try @import("memory.zig").ReturnImpl(memory, checkpoint, temporary);
            first_function = false;
            retain_x = false;
            continue;
        }
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
            try function(memory.allocator(), first_argument, instruction.partial.argument)
        else
            try function(memory.allocator(), first_argument, second_argument);
        result = try @import("memory.zig").ReturnImpl(memory, checkpoint, temporary);
        first_function = false;
        retain_x = false;
    }
    return result;
}

fn functionArity(instruction: @import("parser.zig").Instruction) ?usize {
    return switch (instruction) {
        .primitive => |name| @import("primitives.zig").arity(name),
        .partial, .cases => 1,
        .scope => |scope| scope.arity,
        .partition => 2,
        .scan, .reduce, .unc, .filter => 1,
        .rows => |function| functionArity(function.*),
        .stencil => |st| if (st.size != null or functionArity(st.function.*) == 2) 1 else 2,
        .product => |p| if (p.branches[0].len == 1) functionArity(p.branches[0][0]) else null,
        else => null,
    };
}

/// Each branch receives the same inputs; choice axes precede the result axes.
fn product(memory: *ReservedBumpAllocator, p: @FieldType(@import("parser.zig").Instruction, "product"), x: Value, y: Value) anyerror!Value {
    const a = memory.allocator();
    var data: std.ArrayList(f64) = .empty;
    var result_shape: ?[]const usize = null;
    for (p.branches) |branch| {
        const result = try evaluateScope(memory, branch, x, y);
        if (result.tuple != null) return error.ExpectedArray;
        if (result_shape) |shape| {
            if (!std.mem.eql(usize, shape, result.shape)) return error.ShapeMismatch;
        } else result_shape = result.shape;
        try data.appendSlice(a, result.data);
    }
    const shape = try std.mem.concat(a, usize, &.{ p.shape, result_shape.? });
    return .{ .data = try data.toOwnedSlice(a), .shape = shape };
}
fn cases(a: std.mem.Allocator, input: Value, table: Value) !Value {
    if (input.tuple != null) return error.ExpectedArray;
    const data = try a.alloc(f64, input.data.len);
    for (input.data, data) |key, *output| {
        for (0..table.shape[0]) |row| {
            if (table.data[row * 2] == key) {
                output.* = table.data[row * 2 + 1];
                break;
            }
        } else {
            std.debug.print("TableMiss: no match for {d}\n", .{key});
            return error.TableMiss;
        }
    }
    return .{ .data = data, .shape = try a.dupe(usize, input.shape) };
}

pub fn writeValue(w: *std.Io.Writer, value: Value) std.Io.Writer.Error!void {
    if (value.tuple) |tuple| {
        try w.writeAll("tup( ");
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

/// Stack positive marker runs; unequal runs return (rows, cumulative row offsets).
fn partition(memory: *ReservedBumpAllocator, x: Value, markers: Value, function: *const @import("parser.zig").Instruction) anyerror!Value {
    const a = memory.allocator();
    if (x.tuple != null or markers.tuple != null) return error.InvalidInput;
    if (markers.shape.len != 1) return error.InvalidInput;
    if (x.shape.len == 0 or x.shape[0] != markers.data.len) return error.ShapeMismatch;
    for (markers.data) |marker| {
        if (!std.math.isFinite(marker) or @trunc(marker) != marker or marker < -9223372036854775808.0 or marker >= 9223372036854775808.0) return error.InvalidInput;
    }
    var data: std.ArrayList(f64) = .empty;
    var offsets: std.ArrayList(f64) = .empty;
    try offsets.append(a, 0);
    var jagged = false;
    var groups: usize = 0;
    var group_len: usize = 0;
    const row_len = if (x.shape[0] == 0) 0 else x.data.len / x.shape[0];
    var output_shape: ?[]const usize = null;
    var scalar_output = false;
    var i: usize = 0;
    while (i < markers.data.len) {
        const start = i;
        const marker = markers.data[i];
        i += 1;
        while (i < markers.data.len and markers.data[i] == marker) : (i += 1) {}
        if (marker <= 0) continue;
        const run_shape = try a.dupe(usize, x.shape);
        run_shape[0] = i - start;
        const run: Value = .{ .data = x.data[start * row_len .. i * row_len], .shape = run_shape };
        const mapped = try evaluateScope(memory, &.{function.*}, run, run);
        if (mapped.tuple != null) return error.ExpectedArray;
        const mapped_shape: []const usize = if (mapped.shape.len == 0) &.{1} else mapped.shape;
        if (output_shape) |previous| {
            if (scalar_output != (mapped.shape.len == 0)) return error.ShapeMismatch;
            if (!std.mem.eql(usize, previous[1..], mapped_shape[1..])) return error.ShapeMismatch;
            if (group_len != mapped_shape[0]) jagged = true;
        } else {
            output_shape = mapped_shape;
            scalar_output = mapped.shape.len == 0;
            group_len = mapped_shape[0];
        }
        groups += 1;
        try data.appendSlice(a, mapped.data);
        try offsets.append(a, offsets.items[offsets.items.len - 1] + @as(f64, @floatFromInt(mapped_shape[0])));
    }
    // Uiua returns an empty list when there are no positive groups.
    if (groups == 0) return .{ .data = &.{}, .shape = try a.dupe(usize, &.{0}) };
    if (jagged) {
        const shape = try a.dupe(usize, output_shape.?);
        shape[0] = @intFromFloat(offsets.items[offsets.items.len - 1]);
        const items = try a.alloc(Value, 2);
        items[0] = .{ .data = try data.toOwnedSlice(a), .shape = shape };
        items[1] = .{ .data = try offsets.toOwnedSlice(a), .shape = try a.dupe(usize, &.{groups + 1}) };
        return .{ .tuple = items };
    }
    if (scalar_output) return .{ .data = try data.toOwnedSlice(a), .shape = try a.dupe(usize, &.{groups}) };
    const shape = try a.alloc(usize, output_shape.?.len + 1);
    shape[0] = groups;
    shape[1] = group_len;
    @memcpy(shape[2..], output_shape.?[1..]);
    return .{ .data = try data.toOwnedSlice(a), .shape = shape };
}

/// Map a function over leading-axis rows, repeating single-row arguments.
fn rows(memory: *ReservedBumpAllocator, x: Value, y: Value, function: *const @import("parser.zig").Instruction) anyerror!Value {
    const arity = functionArity(function.*) orelse return error.WrongNumberOfArguments;
    if (arity != 1 and arity != 2) return error.WrongNumberOfArguments;
    if (x.tuple != null or (arity == 2 and y.tuple != null)) return error.ExpectedArray;
    const right = if (arity == 1) x else y;
    if (x.shape.len == 0 and right.shape.len == 0)
        return evaluateScope(memory, &.{function.*}, x, right);
    const nx = if (x.shape.len == 0) 1 else x.shape[0];
    const ny = if (right.shape.len == 0) 1 else right.shape[0];
    if (nx != ny and nx != 1 and ny != 1) return error.ShapeMismatch;
    const count = if (nx == 1) ny else nx;
    const a = memory.allocator();
    var data: std.ArrayList(f64) = .empty;
    var output_shape: ?[]const usize = null;
    for (0..@max(count, 1)) |i| {
        const first = try rowArgument(a, x, i);
        const second = if (arity == 1) first else try rowArgument(a, right, i);
        const result = try evaluateScope(memory, &.{function.*}, first, second);
        if (result.tuple != null) return error.ExpectedArray;
        if (output_shape) |shape| {
            if (!std.mem.eql(usize, shape, result.shape)) return error.ShapeMismatch;
        } else output_shape = try a.dupe(usize, result.shape);
        if (count != 0) try data.appendSlice(a, result.data);
    }
    return .{ .data = try data.toOwnedSlice(a), .shape = try std.mem.concat(a, usize, &.{ &.{count}, output_shape.? }) };
}

/// Keep leading-axis rows whose predicate returns a nonzero scalar.
fn filter(memory: *ReservedBumpAllocator, x: Value, function: *const @import("parser.zig").Instruction) anyerror!Value {
    if (functionArity(function.*) != 1) return error.WrongNumberOfArguments;
    if (x.tuple != null) return error.ExpectedArray;
    const a = memory.allocator();
    const count = if (x.shape.len == 0) 1 else x.shape[0];
    const shape = if (x.shape.len == 0) try a.dupe(usize, &.{1}) else try a.dupe(usize, x.shape);
    const data = try a.alloc(f64, x.data.len);
    var kept: usize = 0;
    var used: usize = 0;
    for (0..count) |i| {
        const checkpoint = memory.checkpoint();
        const row = try rowArgument(a, x, i);
        const predicate = try evaluateScope(memory, &.{function.*}, row, row);
        if (predicate.tuple != null or predicate.shape.len != 0 or predicate.data.len != 1) return error.ShapeMismatch;
        if (predicate.data[0] != 0) {
            @memcpy(data[used..][0..row.data.len], row.data);
            used += row.data.len;
            kept += 1;
        }
        memory.restore(checkpoint);
    }
    shape[0] = kept;
    return .{ .data = data[0..used], .shape = shape };
}

fn rowArgument(a: std.mem.Allocator, value: Value, index: usize) !Value {
    if (value.shape.len == 0) return value;
    const shape = value.shape[1..];
    var width: usize = 1;
    for (shape) |dimension| width = try std.math.mul(usize, width, dimension);
    if (value.shape[0] == 0) {
        const data = try a.alloc(f64, width);
        @memset(data, 0);
        return .{ .data = data, .shape = shape };
    }
    const start = (if (value.shape[0] == 1) 0 else index) * width;
    return .{ .data = value.data[start..][0..width], .shape = shape };
}

/// Inclusive left scan, independently along each innermost vector.
fn scan(memory: *ReservedBumpAllocator, x: Value, function: *const @import("parser.zig").Instruction) anyerror!Value {
    if (functionArity(function.*) != 2) return error.WrongNumberOfArguments;
    if (x.tuple != null) return error.ExpectedArray;
    const a = memory.allocator();
    const data = try a.dupe(f64, x.data);
    const shape = try a.dupe(usize, x.shape);
    const width = if (shape.len == 0) 1 else shape[shape.len - 1];
    if (width == 0) return .{ .data = data, .shape = shape };
    for (0..data.len / width) |row| {
        const start = row * width;
        for (1..width) |column| {
            const checkpoint = memory.checkpoint();
            const acc: Value = .{ .data = data[start + column - 1 ..][0..1] };
            const next: Value = .{ .data = x.data[start + column ..][0..1] };
            const result = try evaluateScope(memory, &.{function.*}, acc, next);
            if (result.tuple != null or result.shape.len != 0 or result.data.len != 1) return error.ShapeMismatch;
            data[start + column] = result.data[0];
            memory.restore(checkpoint);
        }
    }
    return .{ .data = data, .shape = shape };
}

/// Left fold over leading-axis rows, as in Uiua's reduce.
fn reduce(memory: *ReservedBumpAllocator, x: Value, function: *const @import("parser.zig").Instruction) anyerror!Value {
    if (functionArity(function.*) != 2) return error.WrongNumberOfArguments;
    if (x.tuple != null) return error.ExpectedArray;
    if (x.shape.len == 0) return x;
    const a = memory.allocator();
    const shape = x.shape[1..];
    var width: usize = 1;
    for (shape) |dimension| width = try std.math.mul(usize, width, dimension);
    if (x.shape[0] == 0) {
        const identity: f64 = if (function.* == .primitive) blk: {
            const name = function.primitive;
            if (std.mem.eql(u8, name, "add") or std.mem.eql(u8, name, "sub")) break :blk 0;
            if (std.mem.eql(u8, name, "mul") or std.mem.eql(u8, name, "div")) break :blk 1;
            if (std.mem.eql(u8, name, "min")) break :blk std.math.inf(f64);
            if (std.mem.eql(u8, name, "max")) break :blk -std.math.inf(f64);
            return error.NoReductionIdentity;
        } else return error.NoReductionIdentity;
        const data = try a.alloc(f64, width);
        @memset(data, identity);
        return .{ .data = data, .shape = shape };
    }
    var acc: Value = .{ .data = x.data[0..width], .shape = shape };
    const checkpoint = memory.checkpoint();
    for (1..x.shape[0]) |i| {
        const row: Value = .{ .data = x.data[i * width ..][0..width], .shape = shape };
        const result = try evaluateScope(memory, &.{function.*}, acc, row);
        acc = try @import("memory.zig").ReturnImpl(memory, checkpoint, result);
    }
    return acc;
}

/// Scalar window sizes traverse the leading axis. Dyadic operands receive adjacent rows.
fn stencil(memory: *ReservedBumpAllocator, x: Value, y: Value, st: @FieldType(@import("parser.zig").Instruction, "stencil")) anyerror!Value {
    if (x.tuple != null or x.shape.len == 0) return error.ExpectedArray;
    const arity = functionArity(st.function.*) orelse return error.WrongNumberOfArguments;
    if (arity != 1 and arity != 2) return error.WrongNumberOfArguments;
    const size = st.size orelse if (arity == 2) Value{ .data = &.{2} } else y;
    if (size.tuple != null or size.shape.len != 0 or size.data.len != 1) return error.InvalidWindowSize;
    const n = size.data[0];
    if (!std.math.isFinite(n) or n < 1 or @trunc(n) != n or n >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return error.InvalidWindowSize;
    const width: usize = @intFromFloat(n);
    if (arity == 2 and width != 2) return error.WrongNumberOfArguments;
    const a = memory.allocator();
    const count = if (width > x.shape[0]) 0 else x.shape[0] - width + 1;
    var row_len: usize = 1;
    for (x.shape[1..]) |dimension| row_len = try std.math.mul(usize, row_len, dimension);
    const window_len = try std.math.mul(usize, width, row_len);
    const window_shape = try a.dupe(usize, x.shape);
    window_shape[0] = width;
    var data: std.ArrayList(f64) = .empty;
    var output_shape: ?[]const usize = null;
    for (0..count) |i| {
        const first: Value = if (arity == 2)
            .{ .data = x.data[i * row_len ..][0..row_len], .shape = x.shape[1..] }
        else
            .{ .data = x.data[i * row_len ..][0..window_len], .shape = window_shape };
        const second: Value = if (arity == 2)
            .{ .data = x.data[(i + 1) * row_len ..][0..row_len], .shape = x.shape[1..] }
        else
            first;
        const result = try evaluateScope(memory, &.{st.function.*}, first, second);
        if (result.tuple != null) return error.ExpectedArray;
        if (output_shape) |shape| {
            if (!std.mem.eql(usize, shape, result.shape)) return error.ShapeMismatch;
        }
        if (output_shape == null) output_shape = try a.dupe(usize, result.shape);
        try data.appendSlice(a, result.data);
    }
    // Infer the result shape on a prototype window for empty output.
    if (output_shape == null) {
        const prototype_data = try a.alloc(f64, window_len);
        @memset(prototype_data, 0);
        const first: Value = .{ .data = if (arity == 2) prototype_data[0..row_len] else prototype_data, .shape = if (arity == 2) x.shape[1..] else window_shape };
        const result = try evaluateScope(memory, &.{st.function.*}, first, first);
        if (result.tuple != null) return error.ExpectedArray;
        output_shape = result.shape;
    }
    return .{ .data = try data.toOwnedSlice(a), .shape = try std.mem.concat(a, usize, &.{ &.{count}, output_shape.? }) };
}
