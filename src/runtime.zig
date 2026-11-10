const hofs = @import("builtins/hofs.zig");
const std = @import("std");
const ReservedBumpAllocator = @import("reserved_bump_allocator.zig").ReservedBumpAllocator;
pub const Value = struct { data: []const f64 = &.{}, shape: []const usize = &.{}, tuple: ?[]const Value = null };
/// Report the values at the point a shape constraint fails.
pub fn shapeMismatch(context: []const u8, values: []const Value) error{ShapeMismatch} {
    return shapeMismatchIndexed(context, values, null);
}

/// Report original value indices when comparing selected rows or results.
pub fn shapeMismatchIndexed(context: []const u8, values: []const Value, indices: ?[]const usize) error{ShapeMismatch} {
    std.debug.print("ShapeMismatch in {s}\n", .{context});
    for (values, 0..) |value, i| {
        std.debug.print("  value {d}: ", .{if (indices) |items| items[i] else i});
        printDiagnosticValue(value);
        std.debug.print("\n", .{});
    }
    return error.ShapeMismatch;
}

/// Report missing function operands separately from value argument arity.
pub fn combinatorFunctionArguments(name: []const u8, expected: usize, actual: usize) error{ExpectedFunction} {
    std.debug.print("ExpectedFunction: combinator |{s} expected {d} function arguments, got {d}.\n", .{ name, expected, actual });
    return error.ExpectedFunction;
}

fn printDiagnosticValue(value: Value) void {
    if (value.tuple) |items| {
        std.debug.print("tuple (", .{});
        for (items, 0..) |item, i| {
            if (i != 0) std.debug.print(", ", .{});
            printDiagnosticValue(item);
        }
        std.debug.print(")", .{});
    } else {
        std.debug.print("shape {any}, data {any}", .{ value.shape, value.data });
    }
}

/// The first assembled result is the reference for subsequent result shapes.
pub fn firstResult(data: []const f64, shape: []const usize) Value {
    var width: usize = 1;
    for (shape) |dimension| width *= dimension;
    return .{ .data = data[0..@min(width, data.len)], .shape = shape };
}

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
            writeValueAlloc(a, &output.writer, value) catch break;
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
    defer {
        memory.bindings.deinit(memory.allocator());
        memory.bindings = .empty;
    }
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
    const result = try callScope(memory, program.scope, x, y);
    return if (result.tuple) |tuple| tuple else a.dupe(Value, &.{result});
}

pub fn evaluateScope(memory: *ReservedBumpAllocator, instructions: []const @import("parser.zig").Instruction, x: Value, y: Value) anyerror!Value {
    var result = y;
    const checkpoint = memory.checkpoint();
    var retain_x = false;
    var reverse_arguments = false;
    var retain_y = false;
    var first_function = true;
    var skip: usize = 0;
    // D transforms only the right input, so do not evaluate its prefix on x.
    var start: usize = 0;
    for (instructions, 0..) |instruction, index| {
        if (instruction == .combinator and instruction.combinator == .d) start = index;
    }
    if (start > 0) {
        result = try evaluateScope(memory, instructions[0..start], y, y);
        first_function = false;
    }
    for (instructions[start..], start..) |instruction, index| {
        if (skip > 0) {
            skip -= 1;
            continue;
        }
        if (instruction == .combinator and (instruction.combinator == .d2 or instruction.combinator == .phi1)) {
            if (index == 0 or index + 2 >= instructions.len) return combinatorFunctionArguments(@tagName(instruction.combinator), 3, @as(usize, @intFromBool(index > 0)) + @min(2, instructions.len - index - 1));
            const branch = instructions[index + 1];
            const combine = instructions[index + 2];
            const branch_arity: usize = if (instruction.combinator == .d2) 1 else 2;
            if (functionArity(branch) != branch_arity or functionArity(combine) != 2) return error.WrongNumberOfArguments;
            const right = try evaluateScope(memory, &.{branch}, if (branch_arity == 1) y else x, y);
            const temporary = try evaluateScope(memory, &.{combine}, result, right);
            result = try @import("memory.zig").ReturnImpl(memory, checkpoint, temporary);
            skip = 2;
            first_function = false;
            retain_x = false;
            retain_y = false;
            reverse_arguments = false;
            continue;
        }
        if (instruction == .combinator and instruction.combinator == .psi) {
            if (index == 0 or index + 1 == instructions.len) return combinatorFunctionArguments("psi", 2, @as(usize, @intFromBool(index > 0)) + @min(1, instructions.len - index - 1));
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
                if (remaining.len < 1) return combinatorFunctionArguments("phi", 2, 1);
                if (functionArity(remaining[0]) == 1) {
                    if (remaining.len < 3) return combinatorFunctionArguments("phi", 4, 1 + remaining.len);
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
                if (remaining.len < 2) return combinatorFunctionArguments("phi", 3, 1 + remaining.len);
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
            reverse_arguments = instruction.combinator == .sig or instruction.combinator == .n or instruction.combinator == .d;
            retain_y = instruction.combinator == .nu or instruction.combinator == .delta;
            continue;
        }
        const first_argument = if (first_function or reverse_arguments) x else result;
        const second_argument = if (first_function or retain_y) y else if (reverse_arguments) result else if (retain_x) x else result;
        reverse_arguments = false;
        retain_y = false;
        if (instruction == .aggregate or instruction == .literal or instruction == .variable or instruction == .expression or instruction == .dynamic_applied) {
            const temporary = switch (instruction) {
                .aggregate => |aggregate| blk: {
                    const a = memory.allocator();
                    const values = try a.alloc(Value, aggregate.items.len);
                    for (aggregate.items, values) |item, *value| value.* = try evaluateScope(memory, &.{item}, first_argument, second_argument);
                    if (aggregate.tuple) break :blk Value{ .tuple = values };
                    var data: std.ArrayList(f64) = .empty;
                    const child_shape: []const usize = if (values.len == 0) &.{} else values[0].shape;
                    for (values) |value| {
                        if (value.tuple != null) return error.ExpectedArray;
                        if (!std.mem.eql(usize, child_shape, value.shape)) return error.RaggedArray;
                        try data.appendSlice(a, value.data);
                    }
                    const shape = try a.alloc(usize, child_shape.len + 1);
                    shape[0] = values.len;
                    @memcpy(shape[1..], child_shape);
                    break :blk Value{ .data = try data.toOwnedSlice(a), .shape = shape };
                },
                .literal => |value| value,
                .variable => |name| memory.bindings.get(name) orelse return error.UnboundVariable,
                .expression => |expression| blk: {
                    var args: [2]Value = undefined;
                    for (expression.arguments, 0..) |arg, i| args[i] = try evaluateScope(memory, &.{arg}, first_argument, second_argument);
                    break :blk try evaluateScope(memory, expression.body, args[0], args[expression.arguments.len - 1]);
                },
                .dynamic_applied => |application| blk: {
                    const arg = try evaluateScope(memory, &.{application.argument.*}, first_argument, second_argument);
                    break :blk try evaluateScope(memory, &.{application.function.*}, first_argument, arg);
                },
                else => unreachable,
            };
            result = try @import("memory.zig").ReturnImpl(memory, checkpoint, temporary);
            first_function = false;
            retain_x = false;
            continue;
        }
        if (instruction == .component) {
            const temporary = try componentOperation(memory, instruction.component, first_argument, second_argument);
            result = try @import("memory.zig").ReturnImpl(memory, checkpoint, temporary);
            first_function = false;
            retain_x = false;
            continue;
        }
        if (instruction == .product) {
            const temporary = try hofs.product(memory, instruction.product, first_argument, second_argument);
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
            const temporary = try uncOperation(memory, instruction.unc, first_argument, 0);
            result = try @import("memory.zig").ReturnImpl(memory, checkpoint, temporary);
            first_function = false;
            retain_x = false;
            continue;
        }
        if (instruction == .log or instruction == .logshape) {
            const shapes = instruction == .logshape;
            const function = if (shapes) instruction.logshape.* else instruction.log.*;
            if (shapes) {
                try @import("logging.zig").printShapes(first_argument, if (functionArity(function) == 2) second_argument else null, null);
            } else {
                _ = if (functionArity(function) == 2)
                    try @import("builtins/axis_agnostic.zig").logl(memory.allocator(), first_argument, second_argument)
                else
                    try @import("builtins/axis_agnostic.zig").log(memory.allocator(), first_argument, second_argument);
            }
            const temporary = try evaluateScope(memory, &.{function}, first_argument, second_argument);
            if (shapes) try @import("logging.zig").printShapes(temporary, null, "result:\n") else try @import("logging.zig").printResult(memory.allocator(), temporary);
            result = try @import("memory.zig").ReturnImpl(memory, checkpoint, temporary);
            first_function = false;
            retain_x = false;
            continue;
        }
        if (instruction == .join) {
            const temporary = try evaluateScope(memory, &.{instruction.join.*}, first_argument, first_argument);
            result = try @import("memory.zig").ReturnImpl(memory, checkpoint, temporary);
            first_function = false;
            retain_x = false;
            continue;
        }
        if (instruction == .flip) {
            const temporary = try evaluateScope(memory, &.{instruction.flip.*}, second_argument, first_argument);
            result = try @import("memory.zig").ReturnImpl(memory, checkpoint, temporary);
            first_function = false;
            retain_x = false;
            continue;
        }
        if (instruction == .switch_fn) {
            const temporary = try hofs.switchValue(memory, first_argument, second_argument, instruction.switch_fn);
            result = try @import("memory.zig").ReturnImpl(memory, checkpoint, temporary);
            first_function = false;
            retain_x = false;
            continue;
        }
        if (instruction == .map_accum) {
            const temporary = try hofs.mapAccum(memory, first_argument, second_argument, instruction.map_accum);
            result = try @import("memory.zig").ReturnImpl(memory, checkpoint, temporary);
            first_function = false;
            retain_x = false;
            continue;
        }
        if (instruction == .repeat) {
            const temporary = try hofs.repeat(memory, first_argument, second_argument, instruction.repeat);
            result = try @import("memory.zig").ReturnImpl(memory, checkpoint, temporary);
            first_function = false;
            retain_x = false;
            continue;
        }
        if (instruction == .under) {
            const under = instruction.under;
            const transformed_x = try evaluateScope(memory, &.{under.transform.*}, first_argument, .{});
            const transformed_y = if (functionArity(under.function.*) == 2)
                try evaluateScope(memory, &.{under.transform.*}, second_argument, .{})
            else
                Value{};
            const modified = try evaluateScope(memory, &.{under.function.*}, transformed_x, transformed_y);
            const temporary = try evaluateScope(memory, &.{.{ .primitive = under.inverse }}, modified, .{});
            result = try @import("memory.zig").ReturnImpl(memory, checkpoint, temporary);
            first_function = false;
            retain_x = false;
            continue;
        }
        if (instruction == .sort_with) {
            const temporary = try hofs.sortWith(memory, first_argument, instruction.sort_with);
            result = try @import("memory.zig").ReturnImpl(memory, checkpoint, temporary);
            first_function = false;
            retain_x = false;
            continue;
        }
        if (instruction == .map_scan or instruction == .map_fold) {
            const temporary = try hofs.mapScan(memory, first_argument, instruction, 0);
            result = try @import("memory.zig").ReturnImpl(memory, checkpoint, temporary);
            first_function = false;
            retain_x = false;
            continue;
        }
        if (instruction == .partition) {
            const temporary = try hofs.partition(memory, first_argument, second_argument, instruction.partition);
            result = try @import("memory.zig").ReturnImpl(memory, checkpoint, temporary);
            first_function = false;
            retain_x = false;
            continue;
        }
        if (instruction == .reduce or instruction == .fold or instruction == .stencil) {
            const temporary = if (instruction == .reduce)
                try hofs.reduce(memory, first_argument, null, instruction.reduce)
            else if (instruction == .fold)
                try hofs.reduce(memory, first_argument, second_argument, instruction.fold)
            else
                try hofs.stencil(memory, first_argument, second_argument, instruction.stencil);
            result = try @import("memory.zig").ReturnImpl(memory, checkpoint, temporary);
            first_function = false;
            retain_x = false;
            continue;
        }
        if (instruction == .scan or instruction == .partials or instruction == .rows or instruction == .table or instruction == .each or instruction == .each_fill) {
            const temporary = if (instruction == .each)
                try hofs.each(memory, first_argument, instruction.each, null)
            else if (instruction == .each_fill)
                try hofs.each(memory, first_argument, instruction.each_fill, second_argument)
            else if (instruction == .rows)
                try hofs.rows(memory, first_argument, second_argument, instruction.rows)
            else if (instruction == .table)
                try hofs.tableRows(memory, first_argument, second_argument, instruction.table)
            else if (instruction == .partials)
                try hofs.scan(memory, first_argument, null, instruction.partials, false)
            else
                try hofs.scan(memory, first_argument, second_argument, instruction.scan.function, instruction.scan.exclusive);
            result = try @import("memory.zig").ReturnImpl(memory, checkpoint, temporary);
            first_function = false;
            retain_x = false;
            continue;
        }
        if (instruction == .pad) {
            const fill = try evaluateScope(memory, &.{instruction.pad.*}, first_argument, second_argument);
            const temporary = try @import("builtins/pad.zig").pad(memory.allocator(), first_argument, second_argument, fill);
            result = try @import("memory.zig").ReturnImpl(memory, checkpoint, temporary);
            first_function = false;
            retain_x = false;
            continue;
        }
        if (instruction == .applied or instruction == .tuples) {
            const temporary = if (instruction == .applied)
                try evaluateScope(memory, &.{instruction.applied.function.*}, first_argument, instruction.applied.argument)
            else
                try hofs.tuples(memory, first_argument, second_argument, instruction.tuples, 0);
            result = try @import("memory.zig").ReturnImpl(memory, checkpoint, temporary);
            first_function = false;
            retain_x = false;
            continue;
        }
        if (instruction == .scope) {
            const defaults = instruction.scope.default_arguments;
            const first = if (defaults) |args| args[0] else first_argument;
            const second = if (instruction.scope.arity == 1) first else if (defaults) |args| args[1] else second_argument;
            const temporary = try callScope(memory, instruction.scope, first, second);
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
        const function = @import("primitives.zig").lookup(name) orelse {
            std.debug.print("Unimplemented primitive: {s}\n", .{name});
            return error.UnimplementedPrimitive;
        };
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

pub fn evaluateConstant(a: std.mem.Allocator, instruction: @import("parser.zig").Instruction) !Value {
    if (instruction != .scope or instruction.scope.default_arguments == null) return error.ExpectedLiteral;
    const argument = instruction.scope.default_arguments.?[0];
    if (ReservedBumpAllocator.fromAllocator(a)) |memory| {
        return evaluateScope(memory, &.{instruction}, argument, argument);
    }
    var memory = try ReservedBumpAllocator.init(64 * 1024 * 1024);
    defer memory.deinit();
    defer memory.bindings.deinit(memory.allocator());
    return cloneValue(a, try evaluateScope(&memory, &.{instruction}, argument, argument));
}

fn cloneValue(a: std.mem.Allocator, value: Value) anyerror!Value {
    if (value.tuple) |tuple| {
        const items = try a.alloc(Value, tuple.len);
        for (items, tuple) |*item, original| item.* = try cloneValue(a, original);
        return .{ .tuple = items };
    }
    return .{ .data = try a.dupe(f64, value.data), .shape = try a.dupe(usize, value.shape) };
}

pub fn functionArity(instruction: @import("parser.zig").Instruction) ?usize {
    return switch (instruction) {
        .component => |c| functionArity(c.function.*),
        .primitive => |name| @import("primitives.zig").arity(name),
        .pad, .each_fill => 2,
        .partial, .applied, .dynamic_applied, .cases => 1,
        .log, .logshape => |f| functionArity(f.*),
        .under => |u| functionArity(u.function.*),
        .tuples => 2,
        .scope => |scope| scope.arity,
        .repeat => |r| if (r.second != null or (!r.fixed and r.count == null)) 2 else 1,
        .partition, .table, .flip, .map_accum, .switch_fn, .scan, .fold => 2,
        .map_fold, .map_scan, .partials, .reduce, .unc, .join, .sort_with, .each => 1,
        .rows => |function| functionArity(function.*),
        .stencil => 2,
        .product => |p| if (p.branches[0].len == 1) functionArity(p.branches[0][0]) else null,
        else => null,
    };
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

pub fn writeValue(w: *std.Io.Writer, value: Value) (std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    var memory = ReservedBumpAllocator.init(64 * 1024 * 1024) catch return error.OutOfMemory;
    defer memory.deinit();
    return writeValueAlloc(memory.allocator(), w, value);
}

pub fn writeValueAlloc(a: std.mem.Allocator, w: *std.Io.Writer, value: Value) (std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    return @import("display.zig").write(a, w, value);
}

// Scope bindings and pattern views precede the body's checkpoint. Nested calls
// use their own table so resizing cannot leave a parent pointing into a dead frame.
fn callScope(memory: *ReservedBumpAllocator, scope: @FieldType(@import("parser.zig").Instruction, "scope"), x: Value, y: Value) anyerror!Value {
    if (scope.parameters.len == 0) return evaluateScope(memory, scope.instructions, x, y);
    const checkpoint = memory.checkpoint();
    const previous = memory.bindings;
    memory.bindings = .empty;
    defer memory.bindings = previous;
    errdefer memory.restore(checkpoint);
    const a = memory.allocator();
    var entries = previous.iterator();
    while (entries.next()) |entry| try memory.bindings.put(a, entry.key_ptr.*, entry.value_ptr.*);
    for (scope.parameters, 0..) |parameter, i| try bindPattern(memory, a, parameter, if (i == 0) x else y);
    const result = try evaluateScope(memory, scope.instructions, if (scope.parameters.len < scope.arity) y else x, y);
    return @import("memory.zig").ReturnImpl(memory, checkpoint, result);
}

fn printPattern(pattern: @import("parser.zig").Pattern) void {
    switch (pattern) {
        .extractor => |extractor| {
            std.debug.print("<extractor>`", .{});
            printPattern(extractor.pattern.*);
        },
        .name => |name| std.debug.print("{s}", .{name}),
        .rest => |name| std.debug.print("*{s}", .{name}),
        .items => |items| {
            std.debug.print("[", .{});
            for (items, 0..) |item, i| {
                if (i > 0) std.debug.print(" ", .{});
                printPattern(item);
            }
            std.debug.print("]", .{});
        },
    }
}

fn bindPattern(memory: *ReservedBumpAllocator, a: std.mem.Allocator, pattern: @import("parser.zig").Pattern, value: Value) anyerror!void {
    switch (pattern) {
        .extractor => |extractor| {
            const transformed = try evaluateScope(memory, &.{extractor.function}, value, .{});
            try bindPattern(memory, a, extractor.pattern.*, transformed);
        },
        .name, .rest => |name| {
            if (memory.bindings.contains(name)) {
                std.debug.print("shadowed names not allowed\n", .{});
                return error.ShadowedNamesNotAllowed;
            }
            try memory.bindings.put(a, name, value);
        },
        .items => |items| {
            const count = if (value.tuple) |tuple| tuple.len else if (value.shape.len > 0) value.shape[0] else {
                std.debug.print("Pattern ", .{});
                printPattern(pattern);
                std.debug.print(" requires an array or tuple\n", .{});
                return shapeMismatch("array or tuple required for pattern", &.{value});
            };
            var rest_index: ?usize = null;
            for (items, 0..) |item, i| {
                if (item == .rest) {
                    if (rest_index != null) return error.InvalidSyntax;
                    rest_index = i;
                }
            }
            const required = items.len - @intFromBool(rest_index != null);
            if (if (rest_index != null) count < required else count != required) {
                std.debug.print("Pattern ", .{});
                printPattern(pattern);
                std.debug.print(" expects {d} items, received {d}\n", .{ items.len, count });
                return shapeMismatch(@src().fn_name, &.{value});
            }
            for (items, 0..) |item, i| {
                const index = if (rest_index != null and i > rest_index.?) count - (items.len - i) else i;
                const bound = if (item == .rest) blk: {
                    const end = count - (items.len - i - 1);
                    if (value.tuple) |tuple| break :blk Value{ .tuple = tuple[index..end] };
                    const shape = try a.dupe(usize, value.shape);
                    shape[0] = end - index;
                    var width: usize = 1;
                    for (value.shape[1..]) |dimension| width *= dimension;
                    break :blk Value{ .shape = shape, .data = value.data[index * width .. end * width] };
                } else if (value.tuple) |tuple| tuple[index] else try hofs.rowArgument(a, value, index);
                try bindPattern(memory, a, item, bound);
            }
        },
    }
}

/// Split the selected axis into two arguments, grouping items after the first.
fn uncOperation(memory: *ReservedBumpAllocator, function: *const @import("parser.zig").Instruction, x: Value, dimensions: ?usize) anyerror!Value {
    if (functionArity(function.*) != 2) return error.WrongNumberOfArguments;
    const pair = if (x.tuple) |tuple| blk: {
        if (dimensions != null and dimensions.? != 0) return error.InvalidAxis;
        if (tuple.len < 2) return error.WrongNumberOfArguments;
        break :blk [2]Value{ tuple[0], if (tuple.len == 2) tuple[1] else .{ .tuple = tuple[1..] } };
    } else blk: {
        if (x.shape.len == 0) return error.WrongNumberOfArguments;
        const rank = dimensions orelse x.shape.len - 1;
        if (rank >= x.shape.len) return error.InvalidAxis;
        const count = x.shape[x.shape.len - rank - 1];
        if (count < 2) return error.WrongNumberOfArguments;
        const axial = @import("builtins/axial.zig");
        if (count > 2) {
            const parts = try axial.unconsComponents(memory.allocator(), x, rank);
            break :blk [2]Value{ parts.tuple.?[0], parts.tuple.?[1] };
        }
        break :blk [2]Value{
            try axial.selectComponents(memory.allocator(), x, .{ .data = &.{0} }, rank),
            try axial.selectComponents(memory.allocator(), x, .{ .data = &.{1} }, rank),
        };
    };
    return evaluateScope(memory, &.{function.*}, pair[0], pair[1]);
}

/// Component dimensions are trailing storage dimensions, after the operated axis.
fn componentOperation(memory: *ReservedBumpAllocator, c: @FieldType(@import("parser.zig").Instruction, "component"), x: Value, y: Value) anyerror!Value {
    // Relative components leave a vector of blocks or a matrix of cells.
    // Keep block's null rank for leading-axis tuple/scalar selection.
    const selected_dimensions: ?usize = if (c.dimensions) |rank| rank else if (c.leading_axes == 1) null else blk: {
        if (x.tuple != null or x.shape.len < c.leading_axes + c.type_shape.len) return error.InvalidAxis;
        break :blk x.shape.len - c.leading_axes;
    };
    const selection = c.function.* == .primitive and std.mem.eql(u8, c.function.primitive, "select");
    const bound_selection = c.function.* == .partial and std.mem.eql(u8, c.function.partial.name, "select");
    if (selection or bound_selection) {
        if (x.tuple == null and (x.shape.len < c.type_shape.len or
            !std.mem.eql(usize, x.shape[x.shape.len - c.type_shape.len ..], c.type_shape))) return error.ShapeMismatch;
        if (x.tuple != null and c.type_shape.len != 0) return error.ExpectedArray;
        return @import("builtins/axial.zig").selectComponents(memory.allocator(), x, if (bound_selection) c.function.partial.argument else y, selected_dimensions);
    }
    if (c.function.* == .unc) {
        if (x.tuple != null and c.type_shape.len != 0) return error.ExpectedArray;
        if (x.tuple == null and (x.shape.len < c.type_shape.len or
            !std.mem.eql(usize, x.shape[x.shape.len - c.type_shape.len ..], c.type_shape))) return error.ShapeMismatch;
        return uncOperation(memory, c.function.unc, x, selected_dimensions);
    }
    if (x.tuple != null) return error.ExpectedArray;
    if (x.shape.len < c.type_shape.len or
        !std.mem.eql(usize, x.shape[x.shape.len - c.type_shape.len ..], c.type_shape)) return error.ShapeMismatch;
    if (x.shape.len <= c.type_shape.len) return error.InvalidAxis;
    const dimensions = selected_dimensions orelse if (x.shape.len > 0) x.shape.len - 1 else 0;
    if ((c.function.* == .primitive and std.mem.eql(u8, c.function.primitive, "indexin")) or
        (c.function.* == .partial and std.mem.eql(u8, c.function.partial.name, "indexin")))
        return @import("builtins/axial.zig").indexinComponents(memory.allocator(), x, if (c.function.* == .partial) c.function.partial.argument else y, selected_dimensions orelse x.shape.len);
    if (dimensions >= x.shape.len) return error.InvalidAxis;
    if (c.function.* == .primitive and std.mem.eql(u8, c.function.primitive, "sort"))
        return @import("builtins/axial.zig").sortComponents(memory.allocator(), x, dimensions);
    if (c.function.* == .primitive and std.mem.eql(u8, c.function.primitive, "deduplicate"))
        return @import("builtins/axial.zig").deduplicateComponents(memory.allocator(), x, dimensions);
    if (c.function.* == .tuples) return hofs.tuples(memory, x, y, c.function.tuples, dimensions);
    if (c.function.* == .map_scan or c.function.* == .map_fold) return hofs.mapScan(memory, x, c.function.*, dimensions);
    const a = memory.allocator();
    const axis = x.shape.len - dimensions - 1;
    const width = x.shape[axis];
    const cell_shape = x.shape[axis + 1 ..];
    var cell_size: usize = 1;
    for (cell_shape) |dim| cell_size *= dim;
    var count: usize = 1;
    for (x.shape[0..axis]) |dim| count *= dim;
    const is_reduce = c.function.* == .reduce;
    const is_fold = c.function.* == .fold;
    const is_scan = c.function.* == .scan;
    const seeded = is_fold or is_scan;
    const final_only = is_reduce or is_fold;
    const is_partials = c.function.* == .partials;
    if (is_reduce or is_fold or is_scan or is_partials) {
        const function = if (is_reduce) c.function.reduce else if (is_fold) c.function.fold else if (is_scan) c.function.scan.function else c.function.partials;
        if (functionArity(function.*) != 2) return error.WrongNumberOfArguments;
        if (!seeded and width == 0) return error.EmptyArray;
        if (seeded) return hofs.seededFold(memory, x, y, function, axis, final_only, is_scan and c.function.scan.exclusive, true);
        if (hofs.booleanOp(function)) |is_or| return hofs.booleanFold(a, x, if (seeded) y else null, axis, final_only, is_scan and c.function.scan.exclusive, seeded, is_or);
        if (final_only and count > 0) {
            var data: std.ArrayList(f64) = .empty;
            var result_shape: ?[]const usize = null;
            for (0..count) |i| {
                const start = i * width * cell_size;
                const checkpoint = memory.checkpoint();
                var accumulator: Value = if (seeded) y else .{ .data = x.data[start..][0..cell_size], .shape = cell_shape };
                for (if (seeded) @as(usize, 0) else 1..width) |j| {
                    if (hofs.booleanAbsorbed(hofs.booleanD(function), accumulator)) break;
                    const next: Value = .{ .data = x.data[start + j * cell_size ..][0..cell_size], .shape = cell_shape };
                    const result = try evaluateScope(memory, &.{function.*}, accumulator, next);
                    accumulator = try @import("memory.zig").ReturnImpl(memory, checkpoint, result);
                }
                if (accumulator.tuple != null) return error.ShapeMismatch;
                if (result_shape) |expected| {
                    if (!std.mem.eql(usize, expected, accumulator.shape)) return error.ShapeMismatch;
                } else {
                    result_shape = try a.dupe(usize, accumulator.shape);
                }
                try data.appendSlice(a, accumulator.data);
            }
            return .{
                .data = try data.toOwnedSlice(a),
                .shape = try std.mem.concat(a, usize, &.{ x.shape[0..axis], result_shape.? }),
            };
        }
        const exclusive = is_scan and c.function.scan.exclusive;
        const output_width = if (final_only) 1 else width + @as(usize, if (seeded and !exclusive) 1 else 0);
        const shape = try a.alloc(usize, x.shape.len - @as(usize, if (final_only) 1 else 0));
        @memcpy(shape[0..axis], x.shape[0..axis]);
        if (final_only) {
            @memcpy(shape[axis..], cell_shape);
        } else {
            shape[axis] = output_width;
            @memcpy(shape[axis + 1 ..], cell_shape);
        }
        const data = try a.alloc(f64, count * output_width * cell_size);
        // Keep one cell accumulator and reclaim each operand's temporaries.
        const accumulator = try a.alloc(f64, cell_size);
        for (0..count) |i| {
            const start = i * width * cell_size;
            @memcpy(accumulator, if (seeded) y.data else x.data[start..][0..cell_size]);
            const output_start = i * output_width * cell_size;
            if (!final_only and output_width > 0) @memcpy(data[output_start..][0..cell_size], accumulator);
            for (if (seeded) @as(usize, 0) else 1..width - @as(usize, if (exclusive and width > 0) 1 else 0)) |j| {
                if (hofs.booleanAbsorbed(hofs.booleanD(function), .{ .data = accumulator, .shape = cell_shape })) {
                    if (!final_only) {
                        for (j..width - @as(usize, if (exclusive and width > 0) 1 else 0)) |remaining| {
                            const offset = output_start + (remaining + @as(usize, if (seeded) 1 else 0)) * cell_size;
                            @memcpy(data[offset..][0..cell_size], accumulator);
                        }
                    }
                    break;
                }
                const checkpoint = memory.checkpoint();
                const acc: Value = .{ .data = accumulator, .shape = cell_shape };
                const next: Value = .{ .data = x.data[start + j * cell_size ..][0..cell_size], .shape = cell_shape };
                const result = try evaluateScope(memory, &.{function.*}, acc, next);
                if (result.tuple != null or !std.mem.eql(usize, result.shape, cell_shape) or result.data.len != cell_size) return error.ShapeMismatch;
                @memcpy(accumulator, result.data);
                memory.restore(checkpoint);
                if (!final_only) {
                    const offset = output_start + (j + @as(usize, if (seeded) 1 else 0)) * cell_size;
                    @memcpy(data[offset..][0..cell_size], accumulator);
                }
            }
            if (final_only) @memcpy(data[output_start..][0..cell_size], accumulator);
        }
        return .{ .data = data, .shape = shape };
    }
    return @import("builtins/axial.zig").unconsComponents(a, x, dimensions);
}
