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

/// Map each row with the current accumulator, then update it for the next row.
pub fn mapAccum(memory: *ReservedBumpAllocator, x: Value, initial: Value, functions: @FieldType(@import("../parser.zig").Instruction, "map_accum")) anyerror!Value {
    if (x.tuple != null) return error.ExpectedArray;
    const a = memory.allocator();
    const count = if (x.shape.len == 0) 1 else x.shape[0];
    var accumulator = initial;
    var data: std.ArrayList(f64) = .empty;
    var output_shape: ?[]const usize = null;
    for (0..@max(count, 1)) |i| {
        const row = try rowArgument(a, x, i);
        const mapped = try evaluateScope(memory, &.{functions.map.*}, row, accumulator);
        if (mapped.tuple != null) return error.ExpectedArray;
        if (output_shape) |shape| {
            if (!std.mem.eql(usize, shape, mapped.shape)) return shapeMismatch(@src().fn_name, &.{ firstResult(data.items, shape), mapped });
        } else output_shape = try a.dupe(usize, mapped.shape);
        if (count != 0) try data.appendSlice(a, mapped.data);
        if (i + 1 < count) accumulator = try evaluateScope(memory, &.{functions.update.*}, row, accumulator);
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

/// Left prefixes along each innermost vector, optionally starting from a seed.
pub fn scan(memory: *ReservedBumpAllocator, x: Value, seed: ?Value, function: *const @import("../parser.zig").Instruction, exclusive: bool) anyerror!Value {
    if (functionArity(function.*) != 2) return error.WrongNumberOfArguments;
    if (x.tuple != null) return error.ExpectedArray;
    if (seed) |initial| {
        if (initial.tuple != null or initial.shape.len != 0 or initial.data.len != 1) return error.ExpectedScalar;
    } else if (x.data.len == 0) return error.EmptyArray;
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
        if (initial.tuple != null or initial.shape.len != 0 or initial.data.len != 1) return error.ExpectedScalar;
    } else if (x.data.len == 0) return error.EmptyArray;
    if (x.shape.len == 0) {
        if (seed) |initial| {
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
        const next_left = try evaluateScope(memory, &.{r.first.*}, left, if (r.second != null) right else left);
        const next_right = if (r.second) |f| try evaluateScope(memory, &.{f.*}, left, right) else next_left;
        const done = r.fixed and sameValue(left, next_left) and (r.second == null or sameValue(right, next_right));
        // Preserve both outputs together before reclaiming the previous iteration.
        const pair = try @import("../memory.zig").ReturnImpl(memory, checkpoint, .{ .tuple = &.{ next_left, next_right } });
        left = pair.tuple.?[0];
        right = pair.tuple.?[1];
        if (done) break;
    }
    if (r.second != null) return @import("../primitives.zig").lookup("couple").?(memory.allocator(), left, right);
    return left;
}
