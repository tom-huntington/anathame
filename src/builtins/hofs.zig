//! Higher-order builtin implementations. Evaluation dispatch remains in runtime.zig.

const std = @import("std");
const Value = @import("../runtime.zig").Value;

const runtime = @import("../runtime.zig");
const ReservedBumpAllocator = @import("../reserved_bump_allocator.zig").ReservedBumpAllocator;
const evaluateScope = runtime.evaluateScope;
const functionArity = runtime.functionArity;
const shapeMismatch = runtime.shapeMismatch;
const firstResult = runtime.firstResult;

/// Each branch receives the same inputs; choice axes precede the result axes.
pub fn product(memory: *ReservedBumpAllocator, p: @FieldType(@import("../parser.zig").Instruction, "product"), x: Value, y: Value) anyerror!Value {
    const a = memory.allocator();
    var data: std.ArrayList(f64) = .empty;
    var result_shape: ?[]const usize = null;
    for (p.branches) |branch| {
        const result = try evaluateScope(memory, branch, x, y);
        if (result.tuple != null) return error.ExpectedArray;
        if (result_shape) |shape| {
            if (!std.mem.eql(usize, shape, result.shape)) return shapeMismatch(@src().fn_name, &.{ firstResult(data.items, shape), result });
        } else result_shape = result.shape;
        try data.appendSlice(a, result.data);
    }
    const shape = try std.mem.concat(a, usize, &.{ p.shape, result_shape.? });
    return .{ .data = try data.toOwnedSlice(a), .shape = shape };
}

/// Stack positive marker runs; unequal runs return (rows, cumulative row offsets).
pub fn partition(memory: *ReservedBumpAllocator, x: Value, markers: Value, function: *const @import("../parser.zig").Instruction) anyerror!Value {
    const a = memory.allocator();
    if (x.tuple != null or markers.tuple != null) return error.InvalidInput;
    if (markers.shape.len != 1) return error.InvalidInput;
    if (x.shape.len == 0 or x.shape[0] != markers.data.len) return shapeMismatch(@src().fn_name, &.{ x, markers });
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
            if (scalar_output != (mapped.shape.len == 0)) return shapeMismatch(@src().fn_name, &.{ firstResult(data.items, if (scalar_output) &.{} else previous), mapped });
            if (!std.mem.eql(usize, previous[1..], mapped_shape[1..])) return shapeMismatch(@src().fn_name, &.{ firstResult(data.items, previous), mapped });
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

/// Map each row with the current accumulator. Without a separate update
/// function, the mapper returns a tuple of the next accumulator and output.
pub fn mapAccum(memory: *ReservedBumpAllocator, x: Value, initial: Value, functions: @FieldType(@import("../parser.zig").Instruction, "map_accum")) anyerror!Value {
    if (x.tuple != null) return error.ExpectedArray;
    const a = memory.allocator();
    const count = if (x.shape.len == 0) 1 else x.shape[0];
    var accumulator = initial;
    var data: std.ArrayList(f64) = .empty;
    var output_shape: ?[]const usize = null;
    for (0..@max(count, 1)) |i| {
        const row = try rowArgument(a, x, i);
        const result = try evaluateScope(memory, &.{functions.map.*}, accumulator, row);
        const mapped = if (functions.update == null) blk: {
            const pair = result.tuple orelse return error.ExpectedTuple;
            if (pair.len != 2) return error.WrongNumberOfArguments;
            accumulator = pair[0];
            break :blk pair[1];
        } else result;
        if (mapped.tuple != null) return error.ExpectedArray;
        if (output_shape) |shape| {
            if (!std.mem.eql(usize, shape, mapped.shape)) return shapeMismatch(@src().fn_name, &.{ firstResult(data.items, shape), mapped });
        } else output_shape = try a.dupe(usize, mapped.shape);
        if (count != 0) try data.appendSlice(a, mapped.data);
        if (i + 1 < count) {
            if (functions.update) |update| accumulator = try evaluateScope(memory, &.{update.*}, accumulator, row);
        }
    }
    const axes: []const usize = if (x.shape.len == 0) &.{} else &.{count};
    return .{ .data = try data.toOwnedSlice(a), .shape = try std.mem.concat(a, usize, &.{ axes, output_shape.? }) };
}

/// Map a function over leading-axis rows, repeating single-row arguments.
/// A scalar condition selects a whole branch; arrays select corresponding cells or rows.
pub fn switchValue(memory: *ReservedBumpAllocator, x: Value, condition: Value, branches: @FieldType(@import("../parser.zig").Instruction, "switch_fn")) anyerror!Value {
    if (condition.tuple != null) return error.ExpectedArray;
    if (condition.shape.len == 0) {
        const flag = condition.data[0];
        if (flag != 0 and flag != 1) return error.InvalidCondition;
        const function = if (flag == 1) branches.yes else branches.no;
        return evaluateScope(memory, &.{function.*}, x, x);
    }
    if (x.tuple != null) return error.ExpectedArray;
    if (x.shape.len != 0 and x.shape[0] != condition.shape[0]) return shapeMismatch(@src().fn_name, &.{ x, condition });
    const a = memory.allocator();
    const count = condition.shape[0];
    var data: std.ArrayList(f64) = .empty;
    var output_shape: ?[]const usize = null;
    for (0..@max(count, 1)) |i| {
        const result = try switchValue(memory, try rowArgument(a, x, i), try rowArgument(a, condition, i), branches);
        if (result.tuple != null) return error.ExpectedArray;
        if (output_shape) |shape| {
            if (!std.mem.eql(usize, shape, result.shape)) return shapeMismatch(@src().fn_name, &.{ firstResult(data.items, shape), result });
        } else output_shape = try a.dupe(usize, result.shape);
        if (count != 0) try data.appendSlice(a, result.data);
    }
    return .{ .data = try data.toOwnedSlice(a), .shape = try std.mem.concat(a, usize, &.{ &.{count}, output_shape.? }) };
}

/// Map tuple elements or trailing array components and stack the results.
pub fn each(memory: *ReservedBumpAllocator, x: Value, function: *const @import("../parser.zig").Instruction, fill: ?Value, dimensions: usize) anyerror!Value {
    if (functionArity(function.*) != 1) return error.WrongNumberOfArguments;
    if (x.tuple != null) return eachItems(memory, x, function, fill);

    const a = memory.allocator();
    const split = x.shape.len - dimensions;
    const frame = x.shape[0..split];
    var count: usize = 1;
    for (frame) |dimension| count = try std.math.mul(usize, count, dimension);

    // Flatten the frame so each component is a contiguous row.
    const shape = try std.mem.concat(a, usize, &.{ &.{count}, x.shape[split..] });
    const stacked = try eachItems(memory, .{ .data = x.data, .shape = shape }, function, fill);
    return .{ .data = stacked.data, .shape = try std.mem.concat(a, usize, &.{ frame, stacked.shape[1..] }) };
}

fn eachItems(memory: *ReservedBumpAllocator, items: Value, function: *const @import("../parser.zig").Instruction, fill: ?Value) anyerror!Value {
    const a = memory.allocator();
    const count = if (items.tuple) |tuple| tuple.len else items.shape[0];
    // Probe an empty array frame with one zero-filled component to learn the result shape.
    const probes = if (items.tuple != null) count else @max(count, 1);
    if (fill) |value| {
        if (value.tuple != null or value.shape.len != 0 or value.data.len != 1) return error.InvalidInput;
        const results = try a.alloc(Value, probes);
        var shape: []usize = &.{};
        for (results, 0..) |*result, i| {
            const item = if (items.tuple) |tuple| tuple[i] else try rowArgument(a, items, i);
            result.* = try evaluateScope(memory, &.{function.*}, item, item);
            if (result.tuple != null) return error.ExpectedArray;
            // Align trailing axes, promoting lower-rank results with leading ones.
            if (result.shape.len > shape.len) {
                const expanded = try a.alloc(usize, result.shape.len);
                @memset(expanded, 1);
                @memcpy(expanded[expanded.len - shape.len ..], shape);
                if (i == 0) @memcpy(expanded, result.shape);
                shape = expanded;
            }
            const offset = shape.len - result.shape.len;
            for (result.shape, 0..) |dimension, axis| shape[offset + axis] = @max(shape[offset + axis], dimension);
        }
        var cell_len: usize = 1;
        for (shape) |dimension| cell_len = try std.math.mul(usize, cell_len, dimension);
        const data = try a.alloc(f64, try std.math.mul(usize, count, cell_len));
        @memset(data, value.data[0]);
        for (results[0..count], 0..) |result, row| {
            for (result.data, 0..) |element, index| {
                var remaining = index;
                var destination: usize = 0;
                var stride: usize = 1;
                var axis = result.shape.len;
                while (axis > 0) {
                    axis -= 1;
                    destination += (remaining % result.shape[axis]) * stride;
                    remaining /= result.shape[axis];
                    stride *= shape[shape.len - result.shape.len + axis];
                }
                data[row * cell_len + destination] = element;
            }
        }
        return .{ .data = data, .shape = try std.mem.concat(a, usize, &.{ &.{count}, shape }) };
    }
    var data: std.ArrayList(f64) = .empty;
    var output_shape: ?[]const usize = null;
    for (0..probes) |i| {
        const item = if (items.tuple) |tuple| tuple[i] else try rowArgument(a, items, i);
        const result = try evaluateScope(memory, &.{function.*}, item, item);
        if (result.tuple != null) return error.ExpectedArray;
        if (output_shape) |shape| {
            if (!std.mem.eql(usize, shape, result.shape)) return shapeMismatch("each", &.{ firstResult(data.items, shape), result });
        } else output_shape = try a.dupe(usize, result.shape);
        if (i < count) try data.appendSlice(a, result.data);
    }
    return .{ .data = try data.toOwnedSlice(a), .shape = try std.mem.concat(a, usize, &.{ &.{count}, output_shape orelse &.{} }) };
}

pub fn rows(memory: *ReservedBumpAllocator, x: Value, y: Value, function: *const @import("../parser.zig").Instruction) anyerror!Value {
    const arity = functionArity(function.*) orelse return error.WrongNumberOfArguments;
    if (arity != 1 and arity != 2) return error.WrongNumberOfArguments;
    if (x.tuple != null or (arity == 2 and y.tuple != null)) return error.ExpectedArray;
    const right = if (arity == 1) x else y;
    if (x.shape.len == 0 and right.shape.len == 0)
        return evaluateScope(memory, &.{function.*}, x, right);
    const nx = if (x.shape.len == 0) 1 else x.shape[0];
    const ny = if (right.shape.len == 0) 1 else right.shape[0];
    if (nx != ny and nx != 1 and ny != 1) return shapeMismatch(@src().fn_name, &.{ x, right });
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
            if (!std.mem.eql(usize, shape, result.shape)) return shapeMismatch(@src().fn_name, &.{ firstResult(data.items, shape), result });
        } else output_shape = try a.dupe(usize, result.shape);
        if (count != 0) try data.appendSlice(a, result.data);
    }
    return .{ .data = try data.toOwnedSlice(a), .shape = try std.mem.concat(a, usize, &.{ &.{count}, output_shape.? }) };
}

/// Apply a dyadic function to every pair of leading-axis rows, as in Uiua.
pub fn tableRows(memory: *ReservedBumpAllocator, x: Value, y: Value, function: *const @import("../parser.zig").Instruction) anyerror!Value {
    if (functionArity(function.*) != 2) return error.WrongNumberOfArguments;
    if (x.tuple != null or y.tuple != null) return error.ExpectedArray;
    const nx = if (x.shape.len == 0) 1 else x.shape[0];
    const ny = if (y.shape.len == 0) 1 else y.shape[0];
    const count = try std.math.mul(usize, nx, ny);
    const a = memory.allocator();
    var data: std.ArrayList(f64) = .empty;
    var output_shape: ?[]const usize = null;
    for (0..@max(count, 1)) |i| {
        const first = try rowArgument(a, x, if (count == 0) 0 else i / ny);
        const second = try rowArgument(a, y, if (count == 0) 0 else i % ny);
        const result = try evaluateScope(memory, &.{function.*}, first, second);
        if (result.tuple != null) return error.ExpectedArray;
        if (output_shape) |shape| {
            if (!std.mem.eql(usize, shape, result.shape)) return shapeMismatch(@src().fn_name, &.{ firstResult(data.items, shape), result });
        } else {
            output_shape = try a.dupe(usize, result.shape);
        }
        if (count != 0) try data.appendSlice(a, result.data);
    }
    var axes: [2]usize = undefined;
    var rank: usize = 0;
    if (x.shape.len != 0) {
        axes[rank] = nx;
        rank += 1;
    }
    if (y.shape.len != 0) {
        axes[rank] = ny;
        rank += 1;
    }
    return .{ .data = try data.toOwnedSlice(a), .shape = try std.mem.concat(a, usize, &.{ axes[0..rank], output_shape.? }) };
}

pub fn rowArgument(a: std.mem.Allocator, value: Value, index: usize) !Value {
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

/// A closed set of scalar monoids with known identities.
pub fn monoidIdentity(function: *const @import("../parser.zig").Instruction) ?f64 {
    if (function.* != .primitive) return null;
    const name = function.primitive;
    if (std.mem.eql(u8, name, "add") or std.mem.eql(u8, name, "or")) return 0;
    if (std.mem.eql(u8, name, "mul") or std.mem.eql(u8, name, "multiply") or std.mem.eql(u8, name, "and")) return 1;
    if (std.mem.eql(u8, name, "min")) return std.math.inf(f64);
    if (std.mem.eql(u8, name, "max") or std.mem.eql(u8, name, "maximum")) return -std.math.inf(f64);
    return null;
}

/// Empty reductions preserve the cell shape and yield one identity per cell.
pub fn emptyMonoidFold(memory: *ReservedBumpAllocator, x: Value, function: *const @import("../parser.zig").Instruction, axis: usize, final_only: bool) anyerror!Value {
    const identity = monoidIdentity(function) orelse return error.EmptyArray;
    const a = memory.allocator();
    const cell_shape = x.shape[axis + 1 ..];
    var cell_size: usize = 1;
    for (cell_shape) |dimension| cell_size = try std.math.mul(usize, cell_size, dimension);
    const data = try a.alloc(f64, cell_size);
    @memset(data, identity);
    return seededFold(memory, x, .{ .data = data, .shape = cell_shape }, function, axis, final_only, false, true);
}

pub fn mapScan(memory: *ReservedBumpAllocator, x: Value, operation: @import("../parser.zig").Instruction, dimensions: usize) anyerror!Value {
    if (x.tuple != null) return error.ExpectedArray;
    const input = if (x.shape.len == 0) Value{ .data = x.data, .shape = &.{1} } else x;
    if (dimensions >= input.shape.len) return error.InvalidComponent;
    const axis = input.shape.len - dimensions - 1;
    const final_only = operation == .map_fold;
    const identity: Value = .{ .data = &.{if (final_only) operation.map_fold.identity else operation.map_scan.identity} };
    const function = if (final_only) operation.map_fold.function else operation.map_scan.function;
    var result = try seededFoldImpl(memory, input, identity, function, axis, final_only, false, false, true);
    if (x.shape.len == 0 and !final_only) result.shape = result.shape[1..];
    return result;
}

/// Only bare boolean primitives can bypass operand evaluation.
pub fn booleanOp(function: *const @import("../parser.zig").Instruction) ?bool {
    if (function.* != .primitive) return null;
    if (std.mem.eql(u8, function.primitive, "or")) return true;
    if (std.mem.eql(u8, function.primitive, "and")) return false;
    return null;
}

/// Recognize a d combinator whose unchanged left argument is the accumulator.
pub fn booleanD(function: *const @import("../parser.zig").Instruction) ?bool {
    if (function.* != .scope) return null;
    const scope = function.scope;
    if (scope.parameters.len != 0 or scope.default_arguments != null) return null;
    const body = scope.instructions;
    if (body.len == 1) return booleanD(&body[0]);
    if (body.len < 3 or body[body.len - 2] != .combinator or body[body.len - 2].combinator.kind != .d) return null;
    for (body) |instruction| {
        if (instruction == .combinator and instruction.combinator.yeild) return null;
    }
    return booleanOp(&body[body.len - 1]);
}

pub fn booleanAbsorbed(is_or: ?bool, accumulator: Value) bool {
    const op = is_or orelse return false;
    if (accumulator.tuple != null) return false;
    for (accumulator.data) |value| if (value != @as(f64, if (op) 1 else 0)) return false;
    return true;
}

/// Fold each scalar lane independently, stopping input reads at its absorbing value.
pub fn booleanFold(a: std.mem.Allocator, x: Value, seed: ?Value, axis: usize, final_only: bool, exclusive: bool, include_seed: bool, is_or: bool) !Value {
    const width = x.shape[axis];
    var lanes: usize = 1;
    for (x.shape[axis + 1 ..]) |dim| lanes *= dim;
    var count: usize = 1;
    for (x.shape[0..axis]) |dim| count *= dim;
    const output_width = if (final_only) 1 else width + @as(usize, @intFromBool(include_seed and !exclusive));
    const shape = try a.alloc(usize, x.shape.len - @as(usize, @intFromBool(final_only)));
    @memcpy(shape[0..axis], x.shape[0..axis]);
    if (final_only) {
        @memcpy(shape[axis..], x.shape[axis + 1 ..]);
    } else {
        shape[axis] = output_width;
        @memcpy(shape[axis + 1 ..], x.shape[axis + 1 ..]);
    }
    const data = try a.alloc(f64, count * output_width * lanes);
    const absorbing: f64 = if (is_or) 1 else 0;
    for (0..count) |row| {
        for (0..lanes) |lane| {
            var acc = if (seed) |initial| initial.data[lane] else x.data[row * width * lanes + lane];
            const out = row * output_width * lanes + lane;
            if (!final_only and output_width > 0 and (seed == null or include_seed)) data[out] = acc;
            const begin: usize = if (seed != null) 0 else 1;
            const end = width - @as(usize, @intFromBool(exclusive and width > 0));
            var column = begin;
            while (column < end) : (column += 1) {
                if (acc == absorbing) break;
                const next = x.data[(row * width + column) * lanes + lane];
                acc = @floatFromInt(@intFromBool(if (is_or) acc != 0 or next != 0 else acc != 0 and next != 0));
                if (!final_only) data[out + (column + @as(usize, @intFromBool(include_seed))) * lanes] = acc;
            }
            if (final_only) {
                data[out] = acc;
            } else {
                while (column < end) : (column += 1) data[out + (column + @as(usize, @intFromBool(include_seed))) * lanes] = acc;
            }
        }
    }
    return .{ .data = data, .shape = shape };
}

/// Seeded folds keep accumulator values independent of input cell shape.
pub fn seededFold(memory: *ReservedBumpAllocator, x: Value, seed: Value, function: *const @import("../parser.zig").Instruction, axis: usize, final_only: bool, exclusive: bool, include_seed: bool) anyerror!Value {
    return seededFoldImpl(memory, x, seed, function, axis, final_only, exclusive, include_seed, false);
}

// Mapped reductions learn the accumulator shape from the first mapped cell, independently
// of the input cell shape. Ordinary seeded folds retain their explicit seed shape.
fn seededFoldImpl(memory: *ReservedBumpAllocator, x: Value, seed: Value, function: *const @import("../parser.zig").Instruction, axis: usize, final_only: bool, exclusive: bool, include_seed: bool, mapped: bool) anyerror!Value {
    if (functionArity(function.*) != 2) return error.WrongNumberOfArguments;
    if (x.tuple != null or seed.tuple != null) return error.ExpectedArray;
    const a = memory.allocator();
    const cell_shape = x.shape[axis + 1 ..];
    if (std.mem.eql(usize, seed.shape, cell_shape)) {
        if (booleanOp(function)) |is_or| return booleanFold(a, x, seed, axis, final_only, exclusive, include_seed or exclusive, is_or);
    }
    var cell_size: usize = 1;
    for (cell_shape) |dim| cell_size *= dim;
    var count: usize = 1;
    for (x.shape[0..axis]) |dim| count *= dim;
    const width = x.shape[axis];
    const output_width = if (final_only) 1 else width + @as(usize, if (include_seed and !exclusive) 1 else 0);
    var data: std.ArrayList(f64) = .empty;
    var result_shape: ?[]const usize = if (final_only or mapped) null else seed.shape;
    for (0..count) |i| {
        var accumulator = if (final_only) seed else Value{ .data = try a.dupe(f64, seed.data), .shape = seed.shape };
        const lane_checkpoint = memory.checkpoint();
        for (0..width) |j| {
            if (final_only and booleanAbsorbed(booleanD(function), accumulator)) break;
            if (!final_only and (exclusive or (include_seed and j == 0))) try data.appendSlice(a, accumulator.data);
            const checkpoint = memory.checkpoint();
            if (!booleanAbsorbed(booleanD(function), accumulator) and !(exclusive and j + 1 == width)) {
                const next: Value = .{ .data = x.data[(i * width + j) * cell_size ..][0..cell_size], .shape = cell_shape };
                const result = try evaluateScope(memory, &.{function.*}, accumulator, next);
                if (final_only) {
                    accumulator = try @import("../memory.zig").ReturnImpl(memory, lane_checkpoint, result);
                } else {
                    if (result.tuple != null) return error.ExpectedArray;
                    if (mapped and j == 0) {
                        if (result_shape) |expected| {
                            if (!std.mem.eql(usize, expected, result.shape)) return error.ShapeMismatch;
                        }
                        accumulator = try @import("../memory.zig").ReturnImpl(memory, checkpoint, result);
                        result_shape = accumulator.shape;
                    } else {
                        if (!std.mem.eql(usize, result.shape, accumulator.shape) or result.data.len != accumulator.data.len) return error.ShapeMismatch;
                        @memcpy(@constCast(accumulator.data), result.data);
                        memory.restore(checkpoint);
                    }
                }
            }
            if (accumulator.tuple != null) return error.ExpectedArray;
            if (!final_only) {
                if (!std.mem.eql(usize, accumulator.shape, result_shape orelse seed.shape)) return error.ShapeMismatch;
                if (!exclusive) try data.appendSlice(a, accumulator.data);
            }
        }
        if (final_only) {
            if (result_shape) |expected| {
                if (!std.mem.eql(usize, expected, accumulator.shape)) return error.ShapeMismatch;
            } else result_shape = accumulator.shape;
            try data.appendSlice(a, accumulator.data);
        } else if (width == 0 and include_seed and !exclusive) try data.appendSlice(a, seed.data);
    }
    const trailing_shape = result_shape orelse seed.shape;
    const shape = if (final_only)
        try std.mem.concat(a, usize, &.{ x.shape[0..axis], trailing_shape })
    else
        try std.mem.concat(a, usize, &.{ x.shape[0..axis], &.{output_width}, trailing_shape });
    return .{ .data = try data.toOwnedSlice(a), .shape = shape };
}

/// Left prefixes along each innermost vector, optionally starting from a seed.
pub fn scan(memory: *ReservedBumpAllocator, x: Value, seed: ?Value, function: *const @import("../parser.zig").Instruction, exclusive: bool) anyerror!Value {
    if (functionArity(function.*) != 2) return error.WrongNumberOfArguments;
    if (x.tuple != null) return error.ExpectedArray;
    if (seed) |initial| {
        const input = if (x.shape.len == 0) Value{ .data = x.data, .shape = &.{1} } else x;
        var result = try seededFold(memory, input, initial, function, input.shape.len - 1, false, exclusive, false);
        if (x.shape.len == 0) result.shape = result.shape[1..];
        return result;
    } else if (x.shape.len > 0 and x.shape[x.shape.len - 1] == 0) {
        return emptyMonoidFold(memory, x, function, x.shape.len - 1, false);
    }
    if (booleanOp(function)) |is_or| {
        const input = if (x.shape.len == 0) Value{ .data = x.data, .shape = &.{1} } else x;
        var result = try booleanFold(memory.allocator(), input, seed, input.shape.len - 1, false, exclusive, exclusive, is_or);
        if (x.shape.len == 0) result.shape = x.shape;
        return result;
    }
    const a = memory.allocator();
    const data = try a.dupe(f64, x.data);
    const shape = try a.dupe(usize, x.shape);
    const width = if (shape.len == 0) 1 else shape[shape.len - 1];
    if (width == 0) return .{ .data = data, .shape = shape };
    for (0..data.len / width) |row| {
        const start = row * width;
        var accumulator = if (seed) |initial| initial.data[0] else data[start];
        for (if (seed != null) @as(usize, 0) else 1..width) |column| {
            if (exclusive) data[start + column] = accumulator;
            if (exclusive and column + 1 == width) break;
            if (booleanAbsorbed(booleanD(function), .{ .data = (&accumulator)[0..1] })) {
                @memset(data[start + column .. start + width], accumulator);
                break;
            }
            const checkpoint = memory.checkpoint();
            const acc: Value = .{ .data = (&accumulator)[0..1] };
            const next: Value = .{ .data = x.data[start + column ..][0..1] };
            const result = try evaluateScope(memory, &.{function.*}, acc, next);
            if (result.tuple != null or result.shape.len != 0 or result.data.len != 1) return shapeMismatch("scalar result required in " ++ @src().fn_name, &.{ acc, result });
            accumulator = result.data[0];
            if (!exclusive) data[start + column] = accumulator;
            memory.restore(checkpoint);
        }
    }
    return .{ .data = data, .shape = shape };
}

/// Left fold independently along each trailing-axis vector.
pub fn reduce(memory: *ReservedBumpAllocator, x: Value, seed: ?Value, function: *const @import("../parser.zig").Instruction) anyerror!Value {
    if (functionArity(function.*) != 2) return error.WrongNumberOfArguments;
    if (x.tuple != null) return error.ExpectedArray;
    if (seed) |initial| {
        const input = if (x.shape.len == 0) Value{ .data = x.data, .shape = &.{1} } else x;
        return seededFold(memory, input, initial, function, input.shape.len - 1, true, false, false);
    } else if (x.shape.len > 0 and x.shape[x.shape.len - 1] == 0) {
        return emptyMonoidFold(memory, x, function, x.shape.len - 1, true);
    }
    if (booleanOp(function)) |is_or| {
        const input = if (x.shape.len == 0) Value{ .data = x.data, .shape = &.{1} } else x;
        return booleanFold(memory.allocator(), input, seed, input.shape.len - 1, true, false, false, is_or);
    }
    if (x.shape.len == 0) {
        if (seed) |initial| {
            if (booleanAbsorbed(booleanD(function), initial)) return initial;
            const result = try evaluateScope(memory, &.{function.*}, initial, x);
            if (result.tuple != null or result.shape.len != 0 or result.data.len != 1) return error.ExpectedScalar;
            return result;
        }
        return x;
    }
    const a = memory.allocator();
    const shape = x.shape[0 .. x.shape.len - 1];
    const width = x.shape[x.shape.len - 1];
    var count: usize = 1;
    for (shape) |dimension| count = try std.math.mul(usize, count, dimension);
    const data = try a.alloc(f64, count);
    for (0..count) |row| {
        const start = row * width;
        data[row] = if (seed) |initial| initial.data[0] else x.data[start];
        for (if (seed != null) @as(usize, 0) else 1..width) |column| {
            if (booleanAbsorbed(booleanD(function), .{ .data = data[row..][0..1] })) break;
            const checkpoint = memory.checkpoint();
            const acc: Value = .{ .data = data[row..][0..1] };
            const next: Value = .{ .data = x.data[start + column ..][0..1] };
            const result = try evaluateScope(memory, &.{function.*}, acc, next);
            if (result.tuple != null or result.shape.len != 0 or result.data.len != 1) return shapeMismatch("scalar result required in " ++ @src().fn_name, &.{ acc, result });
            data[row] = result.data[0];
            memory.restore(checkpoint);
        }
    }
    return .{ .data = data, .shape = shape };
}

/// Scalar window sizes traverse the leading axis. Dyadic operands receive adjacent rows.
pub fn stencil(memory: *ReservedBumpAllocator, x: Value, y: Value, st: @FieldType(@import("../parser.zig").Instruction, "stencil")) anyerror!Value {
    if (x.tuple != null or x.shape.len == 0) return error.ExpectedArray;
    const arity = functionArity(st.function.*) orelse return error.WrongNumberOfArguments;
    if (arity != 1 and arity != 2) return error.WrongNumberOfArguments;
    const size = y;
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
            if (!std.mem.eql(usize, shape, result.shape)) return shapeMismatch(@src().fn_name, &.{ firstResult(data.items, shape), result });
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

fn natural(n: f64) !usize {
    if (!std.math.isFinite(n) or n < 0 or @trunc(n) != n or n >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return error.InvalidInput;
    return @intFromFloat(n);
}

/// Select pairs by index predicate and apply a dyadic function to their elements.
/// Apply independently within rows of multidimensional arrays.
pub fn tuples(memory: *ReservedBumpAllocator, x: Value, y: Value, t: @FieldType(@import("../parser.zig").Instruction, "tuples"), dimensions: usize) anyerror!Value {
    if (x.tuple != null) return error.ExpectedArray;
    const a = memory.allocator();
    if (x.shape.len > dimensions + 1) {
        const count = x.shape[0];
        var data: std.ArrayList(f64) = .empty;
        var output_shape: ?[]const usize = null;
        for (0..@max(count, 1)) |i| {
            const row = try rowArgument(a, x, i);
            const result = try tuples(memory, row, y, t, dimensions);
            if (output_shape) |shape| {
                if (!std.mem.eql(usize, shape, result.shape)) return shapeMismatch(@src().fn_name, &.{ firstResult(data.items, shape), result });
            } else output_shape = try a.dupe(usize, result.shape);
            if (count != 0) try data.appendSlice(a, result.data);
        }
        return .{ .data = try data.toOwnedSlice(a), .shape = try std.mem.concat(a, usize, &.{ &.{count}, output_shape.? }) };
    }
    const f = t.predicate;
    if (y.tuple != null or y.shape.len != 0 or y.data.len != 1) return error.InvalidInput;
    const scalar = x.shape.len == 0;
    const n = if (scalar) try natural(x.data[0]) else x.shape[0];
    const size = y.data[0];
    const k = if (size == std.math.inf(f64)) n else if (size < 0) n -| try natural(-size) else try natural(size);
    const increasing = f.* == .primitive and (std.mem.eql(u8, f.primitive, "less") or std.mem.eql(u8, f.primitive, "less than"));
    if (increasing and scalar) {
        var combinations: f64 = if (k > n) 0 else 1;
        if (k <= n) {
            for (0..@min(k, n - k)) |i| combinations *= @as(f64, @floatFromInt(n - i)) / @as(f64, @floatFromInt(i + 1));
        }
        return .{ .data = try a.dupe(f64, &.{@round(combinations)}) };
    }
    if (!scalar and k != 2) return error.WrongNumberOfArguments;
    const indices = try a.alloc(usize, k);
    var data: std.ArrayList(f64) = .empty;
    var count: usize = 0;
    var output_shape: ?[]const usize = null;
    try tupleSelections(memory, x, t, n, indices, 0, &data, &count, &output_shape);
    if (scalar) return .{ .data = try a.dupe(f64, &.{@floatFromInt(count)}) };
    if (output_shape == null) {
        var width: usize = 1;
        for (x.shape[1..]) |dim| width = try std.math.mul(usize, width, dim);
        const zeros = try a.alloc(f64, width);
        @memset(zeros, 0);
        const row: Value = .{ .data = zeros, .shape = x.shape[1..] };
        const mapped = try evaluateScope(memory, &.{t.function.*}, row, row);
        if (mapped.tuple != null) return error.ExpectedArray;
        output_shape = mapped.shape;
    }
    return .{ .data = try data.toOwnedSlice(a), .shape = try std.mem.concat(a, usize, &.{ &.{count}, output_shape.? }) };
}

fn tupleSelections(memory: *ReservedBumpAllocator, x: Value, t: @FieldType(@import("../parser.zig").Instruction, "tuples"), n: usize, indices: []usize, depth: usize, data: *std.ArrayList(f64), count: *usize, output_shape: *?[]const usize) anyerror!void {
    const a = memory.allocator();
    if (depth == indices.len) {
        count.* = try std.math.add(usize, count.*, 1);
        if (x.shape.len != 0) {
            var width: usize = 1;
            for (x.shape[1..]) |dim| width = try std.math.mul(usize, width, dim);
            const checkpoint = memory.checkpoint();
            const first: Value = .{ .data = x.data[indices[0] * width ..][0..width], .shape = x.shape[1..] };
            const second: Value = .{ .data = x.data[indices[1] * width ..][0..width], .shape = x.shape[1..] };
            const mapped = try evaluateScope(memory, &.{t.function.*}, first, second);
            if (mapped.tuple != null) return error.ExpectedArray;
            if (output_shape.*) |shape| {
                if (!std.mem.eql(usize, shape, mapped.shape)) return shapeMismatch(@src().fn_name, &.{ firstResult(data.items, shape), mapped });
            }
            const saved = try @import("../memory.zig").ReturnImpl(memory, checkpoint, mapped);
            if (output_shape.* == null) output_shape.* = try a.dupe(usize, saved.shape);
            try data.appendSlice(a, saved.data);
        }
        return;
    }
    for (0..n) |i| {
        var reps: usize = 1;
        for (indices[0..depth]) |j| {
            const checkpoint = memory.checkpoint();
            const predicate = try evaluateScope(memory, &.{t.predicate.*}, .{ .data = &.{@floatFromInt(j)} }, .{ .data = &.{@floatFromInt(i)} });
            if (predicate.tuple != null or predicate.shape.len != 0 or predicate.data.len != 1) return error.InvalidInput;
            const times = try natural(predicate.data[0]);
            if (indices.len > 2 and times > 1) return error.InvalidInput;
            reps = times;
            memory.restore(checkpoint);
            if (reps == 0) break;
        }
        indices[depth] = i;
        for (0..reps) |_| try tupleSelections(memory, x, t, n, indices, depth + 1, data, count, output_shape);
    }
}

/// Exact structural equality, including tuple nesting and array shape.
fn sameValue(x: Value, y: Value) bool {
    if (x.tuple) |xs| {
        const ys = y.tuple orelse return false;
        if (xs.len != ys.len) return false;
        for (xs, ys) |left, right| if (!sameValue(left, right)) return false;
        return true;
    }
    return y.tuple == null and std.mem.eql(usize, x.shape, y.shape) and std.mem.eql(f64, x.data, y.data);
}

pub fn repeat(memory: *ReservedBumpAllocator, x: Value, y: Value, r: @FieldType(@import("../parser.zig").Instruction, "repeat")) anyerror!Value {
    var count: usize = 0;
    if (!r.fixed) {
        const value = r.count orelse y;
        if (value.tuple != null or value.shape.len != 0 or value.data.len != 1) return error.InvalidInput;
        const n = value.data[0];
        if (!std.math.isFinite(n) or n < 0 or @floor(n) != n or n >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return error.InvalidInput;
        count = @intFromFloat(n);
    }
    const checkpoint = memory.checkpoint();
    var left = x;
    var right = y;
    var i: usize = 0;
    while (r.fixed or i < count) : (i += 1) {
        // A single dyad keeps the original input as its right argument.
        const next_left = try evaluateScope(memory, &.{r.first.*}, left, if (r.second != null) right else x);
        const next_right = if (r.second) |f| try evaluateScope(memory, &.{f.*}, left, right) else next_left;
        const done = r.fixed and sameValue(left, next_left) and (r.second == null or sameValue(right, next_right));
        // Preserve both outputs together before reclaiming the previous iteration.
        const pair = try @import("../memory.zig").ReturnImpl(memory, checkpoint, .{ .tuple = &.{ next_left, next_right } });
        left = pair.tuple.?[0];
        right = pair.tuple.?[1];
        if (r.check) {
            const iteration = i + 1;
            if (iteration & (iteration - 1) == 0) try @import("../logging.zig").printIteration(iteration);
        }
        if (done) break;
    }
    if (r.second != null) return @import("../primitives.zig").lookup("couple").?(memory.allocator(), left, right);
    return left;
}

/// Stable leading-axis sort using a strict comes-before predicate on rows.
pub fn sortWith(memory: *ReservedBumpAllocator, x: Value, function: *const @import("../parser.zig").Instruction) anyerror!Value {
    if (x.tuple != null) return error.InvalidInput;
    if (x.shape.len == 0 or x.shape[0] < 2) return x;
    const a = memory.allocator();
    const count = x.shape[0];
    const indices = try a.alloc(usize, count);
    const scratch = try a.alloc(usize, count);
    for (indices, 0..) |*index, i| index.* = i;
    var run: usize = 1;
    while (run < count) : (run *= 2) {
        var start: usize = 0;
        while (start < count) : (start += 2 * run) {
            const middle = @min(start + run, count);
            const end = @min(start + 2 * run, count);
            var left = start;
            var right = middle;
            for (scratch[start..end]) |*target| {
                const take_right = left < middle and right < end and blk: {
                    const checkpoint = memory.checkpoint();
                    defer memory.restore(checkpoint);
                    const rhs = try rowArgument(a, x, indices[right]);
                    const lhs = try rowArgument(a, x, indices[left]);
                    const comparison = try evaluateScope(memory, &.{function.*}, rhs, lhs);
                    if (comparison.tuple != null or comparison.shape.len != 0 or comparison.data.len != 1) return error.InvalidInput;
                    if (comparison.data[0] != 0 and comparison.data[0] != 1) return error.InvalidInput;
                    break :blk comparison.data[0] == 1;
                };
                if (left == middle or take_right) {
                    target.* = indices[right];
                    right += 1;
                } else {
                    target.* = indices[left];
                    left += 1;
                }
            }
        }
        @memcpy(indices, scratch);
    }
    const width = x.data.len / count;
    const data = try a.alloc(f64, x.data.len);
    for (indices, 0..) |source, target| @memcpy(data[target * width ..][0..width], x.data[source * width ..][0..width]);
    return .{ .data = data, .shape = x.shape };
}

/// Return the first matching cell along the selected axis, without evaluating later cells.
pub fn find(memory: *ReservedBumpAllocator, x: Value, predicate: *const @import("../parser.zig").Instruction, dimensions: usize) anyerror!Value {
    if (x.tuple != null) return error.ExpectedArray;
    const input = if (x.shape.len == 0) Value{ .data = x.data, .shape = &.{1} } else x;
    if (dimensions >= input.shape.len) return error.InvalidComponent;
    const axis = input.shape.len - dimensions - 1;
    const cell_shape = input.shape[axis + 1 ..];
    var size: usize = 1;
    for (cell_shape) |dim| size *= dim;
    var count: usize = 1;
    for (input.shape[0..axis]) |dim| count *= dim;
    const a = memory.allocator();
    const shape = try a.alloc(usize, input.shape.len - 1);
    @memcpy(shape[0..axis], input.shape[0..axis]);
    @memcpy(shape[axis..], cell_shape);
    const data = try a.alloc(f64, count * size);
    for (0..count) |row| {
        for (0..input.shape[axis]) |column| {
            const cell: Value = .{ .data = input.data[(row * input.shape[axis] + column) * size ..][0..size], .shape = cell_shape };
            const checkpoint = memory.checkpoint();
            const matched = blk: {
                defer memory.restore(checkpoint);
                const result = try evaluateScope(memory, &.{predicate.*}, cell, .{});
                if (result.tuple != null or result.shape.len != 0 or result.data.len != 1) return error.ExpectedScalar;
                break :blk result.data[0] != 0;
            };
            if (matched) {
                @memcpy(data[row * size ..][0..size], cell.data);
                break;
            }
        } else return error.NoMatch;
    }
    return .{ .data = data, .shape = shape };
}

/// A dense memo table, with a separate state array to support empty components
/// and detect dependency cycles without reserving a numeric result value.
const RecurseMap = std.HashMapUnmanaged([]const usize, usize, struct {
    pub fn hash(_: @This(), key: []const usize) u64 {
        return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(key));
    }

    pub fn eql(_: @This(), lhs: []const usize, rhs: []const usize) bool {
        return std.mem.eql(usize, lhs, rhs);
    }
}, std.hash_map.default_max_load_percentage);

const Recurse = struct {
    memory: *ReservedBumpAllocator,
    functions: @FieldType(@import("../parser.zig").Instruction, "recurse"),
    bounds: []const usize,
    component: []const usize,
    width: usize,
    table: []f64,
    state: []u8,
    keys: []usize,
    map: RecurseMap,

    fn store(self: *Recurse, index: usize, value: Value) !Value {
        if (value.tuple != null) return error.ExpectedArray;
        if (!std.mem.eql(usize, self.component, value.shape) or value.data.len != self.width) return error.RecurseResultShapeMismatch;
        for (value.data) |number| if (std.math.isNan(number)) return error.RecurseSentinelResult;
        const destination = self.table[index * self.width ..][0..self.width];
        @memcpy(destination, value.data);
        self.state[index] = 2;
        return .{ .data = destination, .shape = self.component };
    }

    fn visit(self: *Recurse, node: Value, root: bool) anyerror!Value {
        if (node.tuple != null or node.shape.len > 1 or node.data.len != self.bounds.len) return error.InvalidRecurseIndex;
        const checkpoint = self.memory.checkpoint();
        const coordinates = try self.memory.allocator().alloc(usize, self.bounds.len);
        for (node.data, self.bounds, coordinates) |number, bound, *destination| {
            if (!std.math.isFinite(number) or number < 0 or @trunc(number) != number or number >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return error.InvalidRecurseIndex;
            const coordinate: usize = @intFromFloat(number);
            if (!root and coordinate >= bound) return error.InvalidRecurseIndex;
            destination.* = coordinate;
        }
        var index: usize = 0;
        if (!root) {
            if (self.map.get(coordinates)) |cached_index| {
                index = cached_index;
            } else {
                index = self.map.count();
                if (index == self.state.len) return error.RecurseCacheCapacityExceeded;
                const key = self.keys[index * self.bounds.len ..][0..self.bounds.len];
                @memcpy(key, coordinates);
                // All storage predates the recursive checkpoints. Never grow here.
                self.map.putAssumeCapacityNoClobber(key, index);
                self.state[index] = 0;
            }
            if (self.state[index] == 2) {
                self.memory.restore(checkpoint);
                return .{ .data = self.table[index * self.width ..][0..self.width], .shape = self.component };
            }
            if (self.state[index] == 1) return error.RecurseCycle;
            self.state[index] = 1;
        }
        const base = try evaluateScope(self.memory, &.{self.functions.base.*}, node, node);
        var result = base;
        if (isRecurseSentinel(base)) {
            const children = try evaluateScope(self.memory, &.{self.functions.children.*}, node, node);
            if (children.tuple != null) return error.ExpectedArray;
            const scalar = children.shape.len == 0;
            const count = if (scalar) 1 else children.shape[0];
            const a = self.memory.allocator();
            const values = try a.alloc(f64, try std.math.mul(usize, count, self.width));
            for (0..count) |i| {
                const child = if (scalar) children else try rowArgument(a, children, i);
                const value = try self.visit(child, false);
                @memcpy(values[i * self.width ..][0..self.width], value.data);
            }
            const resolved: Value = .{ .data = values, .shape = if (scalar) self.component else try std.mem.concat(a, usize, &.{ &.{count}, self.component }) };
            result = if (functionArity(self.functions.combine.*) == 2)
                try evaluateScope(self.memory, &.{self.functions.combine.*}, if (self.functions.child_indices) children else node, resolved)
            else
                try evaluateScope(self.memory, &.{self.functions.combine.*}, resolved, resolved);
        }
        if (result.tuple != null) return error.ExpectedArray;
        for (result.data) |number| if (std.math.isNan(number)) return error.RecurseSentinelResult;
        if (!std.mem.eql(usize, result.shape, self.component)) return error.RecurseResultShapeMismatch;
        if (root) return @import("../memory.zig").ReturnImpl(self.memory, checkpoint, result);
        const cached = try self.store(index, result);
        self.memory.restore(checkpoint);
        return cached;
    }
};

fn isRecurseSentinel(value: Value) bool {
    return value.tuple == null and value.shape.len == 0 and value.data.len == 1 and std.math.isNan(value.data[0]);
}

pub fn recurse(memory: *ReservedBumpAllocator, maximum: Value, functions: @FieldType(@import("../parser.zig").Instruction, "recurse")) anyerror!Value {
    if (maximum.tuple != null or maximum.shape.len > 1) return error.InvalidRecurseIndex;
    const checkpoint = memory.checkpoint();
    errdefer memory.restore(checkpoint);
    const a = memory.allocator();
    const bounds = try a.alloc(usize, maximum.data.len);
    var count: usize = 1;
    for (maximum.data, bounds) |number, *bound| {
        if (!std.math.isFinite(number) or number < 0 or @trunc(number) != number or number >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return error.InvalidRecurseIndex;
        bound.* = @intFromFloat(number);
        count *|= bound.*;
    }
    const zeros = try a.alloc(f64, maximum.data.len);
    @memset(zeros, 0);
    const origin: Value = .{ .data = zeros, .shape = maximum.shape };
    const base = try evaluateScope(memory, &.{functions.base.*}, origin, origin);
    if (base.tuple != null) return error.ExpectedArray;
    for (base.data) |number| if (std.math.isNan(number)) return error.RecurseOriginNotBaseCase;
    // Bound the cache by 1 GiB, including owned keys/results and buckets.
    // Four buckets per entry conservatively covers load factor, power-of-two
    // rounding, metadata, and the map allocation header/alignment.
    const budget = 1024 * 1024 * 1024;
    const bytes_per_entry = try std.math.add(usize, try std.math.add(usize, try std.math.mul(usize, bounds.len, @sizeOf(usize)), try std.math.mul(usize, base.data.len, @sizeOf(f64))), 1 + 4 * (@sizeOf([]const usize) + @sizeOf(usize) + 1) + 64);
    const capacity = @min(count, budget / bytes_per_entry);
    var map: RecurseMap = .empty;
    try map.ensureTotalCapacity(a, @intCast(capacity));
    var cache: Recurse = .{
        .memory = memory,
        .functions = functions,
        .bounds = bounds,
        .component = base.shape,
        .width = base.data.len,
        .table = try a.alloc(f64, try std.math.mul(usize, capacity, base.data.len)),
        .state = try a.alloc(u8, capacity),
        .keys = try a.alloc(usize, try std.math.mul(usize, capacity, bounds.len)),
        .map = map,
    };
    @memset(cache.state, 0);
    if (count > 0) {
        if (capacity == 0) return error.RecurseCacheCapacityExceeded;
        const key = cache.keys[0..bounds.len];
        @memset(key, 0);
        cache.map.putAssumeCapacityNoClobber(key, 0);
        _ = try cache.store(0, base);
    }
    const result = try cache.visit(maximum, true);
    return @import("../memory.zig").ReturnImpl(memory, checkpoint, result);
}
