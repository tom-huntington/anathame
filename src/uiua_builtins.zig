const std = @import("std");
const Value = @import("runtime.zig").Value;

/// Uiua indexin: find each needle row in the haystack (the first argument).
/// Missing rows return the haystack's row count; duplicate rows use the first index.
pub fn indexin(a: std.mem.Allocator, haystack: Value, needle: Value) !Value {
    if (haystack.tuple != null or needle.tuple != null) return error.InvalidInput;
    const hay_rows = if (haystack.shape.len == 0) 1 else haystack.shape[0];
    const needle_rows = if (needle.shape.len == 0) 1 else needle.shape[0];
    if (needle.shape.len == haystack.shape.len or needle.shape.len + 1 == haystack.shape.len) {
        const same_rank = needle.shape.len == haystack.shape.len;
        const shape = if (same_rank) needle.shape[0..@min(1, needle.shape.len)] else &.{};
        const data = try a.alloc(f64, if (same_rank) needle_rows else 1);
        const hay_width = rowWidth(haystack);
        const needle_width = if (same_rank) rowWidth(needle) else needle.data.len;
        for (data, 0..) |*result, i| {
            result.* = @floatFromInt(hay_rows);
            if (!same_rank and !std.mem.endsWith(usize, haystack.shape, needle.shape)) continue;
            const wanted = needle.data[i * needle_width ..][0..needle_width];
            for (0..hay_rows) |j| {
                const candidate = haystack.data[j * hay_width ..][0..hay_width];
                if (candidate.len != wanted.len) continue;
                for (candidate, wanted) |x, y| {
                    if (x != y and !(std.math.isNan(x) and std.math.isNan(y))) break;
                } else {
                    result.* = @floatFromInt(j);
                    break;
                }
            }
        }
        return .{ .data = data, .shape = try a.dupe(usize, shape) };
    }
    const recurse_needle = needle.shape.len > haystack.shape.len;
    if (recurse_needle and needle_rows == 0) return .{ .data = try a.dupe(f64, needle.data), .shape = try a.dupe(usize, needle.shape) };
    if (!recurse_needle and !std.mem.endsWith(usize, haystack.shape, needle.shape)) {
        const shape = haystack.shape[0 .. haystack.shape.len - needle.shape.len - 1];
        var count: usize = 1;
        for (shape) |dim| count = try std.math.mul(usize, count, dim);
        const data = try a.alloc(f64, count);
        @memset(data, @as(f64, @floatFromInt(hay_rows)));
        return .{ .data = data, .shape = try a.dupe(usize, shape) };
    }
    const source = if (recurse_needle) needle else haystack;
    const rows = source.shape[0];
    const width = rowWidth(source);
    var data: std.ArrayList(f64) = .empty;
    errdefer data.deinit(a);
    var shape: []const usize = &.{0};
    for (0..rows) |i| {
        const row: Value = .{ .data = source.data[i * width ..][0..width], .shape = source.shape[1..] };
        const result = if (recurse_needle) try indexin(a, haystack, row) else try indexin(a, row, needle);
        defer a.free(result.data);
        defer a.free(result.shape);
        if (i == 0) {
            const dimensions = try a.alloc(usize, result.shape.len + 1);
            dimensions[0] = rows;
            @memcpy(dimensions[1..], result.shape);
            shape = dimensions;
        }
        try data.appendSlice(a, result.data);
    }
    return .{ .data = try data.toOwnedSlice(a), .shape = if (rows == 0) try a.dupe(usize, shape) else shape };
}

fn rowWidth(value: Value) usize {
    var width: usize = 1;
    for (value.shape[@min(1, value.shape.len)..]) |dim| width *= dim;
    return width;
}

/// Uiua sort: reorder leading-axis rows lexicographically, preserving their contents.
pub fn lexisort(a: std.mem.Allocator, value: Value, _: Value) !Value {
    if (value.tuple != null) return error.InvalidInput;
    if (value.shape.len == 0 or value.data.len == 0 or value.shape[0] < 2) return value;
    const width = value.data.len / value.shape[0];
    const indices = try a.alloc(usize, value.shape[0]);
    defer a.free(indices);
    for (indices, 0..) |*index, i| index.* = i;
    const Context = struct {
        data: []const f64,
        width: usize,

        fn lessThan(ctx: @This(), lhs: usize, rhs: usize) bool {
            for (ctx.data[lhs * ctx.width ..][0..ctx.width], ctx.data[rhs * ctx.width ..][0..ctx.width]) |x, y| {
                // Uiua orders NaNs after numbers and treats signed zeros as equal.
                if (x < y) return true;
                if (x > y) return false;
                if (std.math.isNan(x) != std.math.isNan(y)) return std.math.isNan(y);
            }
            return false;
        }
    };
    std.mem.sort(usize, indices, Context{ .data = value.data, .width = width }, Context.lessThan);
    const data = try a.alloc(f64, value.data.len);
    for (indices, 0..) |source, dest| {
        @memcpy(data[dest * width ..][0..width], value.data[source * width ..][0..width]);
    }
    return .{ .data = data, .shape = value.shape };
}

/// Uiua reshape without fill: scalar repetition, cyclic lists, and inferred axes.
pub fn reshape(a: std.mem.Allocator, value: Value, dimensions: Value) !Value {
    if (value.tuple != null or dimensions.tuple != null or dimensions.shape.len > 1 or dimensions.data.len >= 100) return error.InvalidInput;
    const scalar = dimensions.shape.len == 0;
    if (scalar and dimensions.data.len != 1) return error.InvalidInput;
    const shape = try a.alloc(usize, if (scalar) value.shape.len + 1 else dimensions.data.len);
    var inferred: ?usize = null;
    var count: usize = 1;
    for (dimensions.data, 0..) |n, i| {
        if (std.math.isInf(n)) {
            if (scalar) {
                if (n > 0) return value;
                return reverseReshapeRows(a, value);
            }
            if (inferred != null) return error.InvalidInput;
            inferred = i;
            shape[i] = 1;
        } else {
            if (std.math.isNan(n) or @trunc(n) != n or @abs(n) >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return error.InvalidInput;
            shape[i] = @intFromFloat(@abs(n));
            count = try std.math.mul(usize, count, shape[i]);
        }
    }
    if (scalar) {
        @memcpy(shape[1..], value.shape);
        count = try std.math.mul(usize, count, value.data.len);
    } else if (inferred) |i| {
        if (count == 0) return error.InvalidInput;
        shape[i] = value.data.len / count;
        count = try std.math.mul(usize, count, shape[i]);
    }
    if (count > 0 and value.data.len == 0) return @import("runtime.zig").shapeMismatch(@src().fn_name, &.{ value, dimensions });
    const source = if (scalar and dimensions.data[0] < 0) try reverseReshapeRows(a, value) else value;
    const data = try a.alloc(f64, count);
    for (data, 0..) |*item, i| {
        var index = i;
        if (!scalar) {
            var stride: usize = 1;
            var axis = shape.len;
            while (axis > 0) {
                axis -= 1;
                const dim = shape[axis];
                const coordinate = i / stride % dim;
                if (dimensions.data[axis] < 0) {
                    index -= coordinate * stride;
                    index += (dim - 1 - coordinate) * stride;
                }
                stride *= dim;
            }
        }
        item.* = source.data[index % source.data.len];
    }
    return .{ .data = data, .shape = shape };
}

fn reverseReshapeRows(a: std.mem.Allocator, value: Value) !Value {
    if (value.shape.len == 0 or value.data.len == 0) return value;
    const rows = value.shape[0];
    const width = value.data.len / rows;
    const data = try a.alloc(f64, value.data.len);
    for (0..rows) |i| @memcpy(data[i * width ..][0..width], value.data[(rows - 1 - i) * width ..][0..width]);
    return .{ .data = data, .shape = value.shape };
}

/// Repeat data cyclically to fill the requested shape.
pub fn fill(a: std.mem.Allocator, x: Value, y: Value) !Value {
    if (x.shape.len == 0 and y.shape.len != 0) return full(a, x, y);
    return full(a, y, x);
}

/// Like fill, with the shape bound as the second argument.
pub fn full(a: std.mem.Allocator, value: Value, dimensions: Value) !Value {
    if (value.tuple != null or dimensions.tuple != null or dimensions.shape.len > 1) return error.InvalidInput;
    const shape = try a.alloc(usize, dimensions.data.len);
    var count: usize = 1;
    for (dimensions.data, shape) |n, *dimension| {
        if (!std.math.isFinite(n) or n < 0 or @trunc(n) != n or n >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return error.InvalidInput;
        dimension.* = @intFromFloat(n);
        count = try std.math.mul(usize, count, dimension.*);
    }
    if (count != 0 and value.data.len == 0) return @import("runtime.zig").shapeMismatch(@src().fn_name, &.{ value, dimensions });
    const data = try a.alloc(f64, count);
    for (data, 0..) |*item, i| item.* = value.data[i % value.data.len];
    return .{ .data = data, .shape = shape };
}

/// Uiua keep on the trailing axis. Counts cycle when short and truncate when long.
/// Real scalar counts resample the axis; negative scalars also reverse it.
pub fn keep(a: std.mem.Allocator, x: Value, counts: Value) !Value {
    if (x.tuple != null or counts.tuple != null) return error.InvalidInput;
    const scalar = counts.shape.len == 0;
    const source_shape: []const usize = if (x.shape.len == 0) &.{1} else x.shape;
    const width = source_shape[source_shape.len - 1];
    if (!scalar and width > 0 and counts.data.len == 0) return @import("runtime.zig").shapeMismatch(@src().fn_name, &.{ x, counts });
    for (counts.data) |n| {
        if (!std.math.isFinite(n) or (!scalar and @trunc(n) != n)) return error.InvalidInput;
    }
    var new_width: usize = 0;
    if (scalar) {
        new_width = try keepSize(@round(@abs(counts.data[0]) * @as(f64, @floatFromInt(width))));
    } else {
        for (0..width) |i| {
            new_width = try std.math.add(usize, new_width, try keepSize(@max(0, counts.data[i % counts.data.len])));
        }
    }
    var outer: usize = 1;
    for (source_shape[0 .. source_shape.len - 1]) |dim| outer = try std.math.mul(usize, outer, dim);
    const shape = try a.dupe(usize, source_shape);
    shape[shape.len - 1] = new_width;
    const data = try a.alloc(f64, try std.math.mul(usize, outer, new_width));
    for (0..outer) |row| {
        if (scalar) {
            const delta = @as(f64, @floatFromInt(width)) / @as(f64, @floatFromInt(new_width));
            for (0..new_width) |j| {
                const k = if (counts.data[0] < 0) new_width - 1 - j else j;
                const t = @as(f64, @floatFromInt(k)) * delta;
                const fraction = t - @floor(t);
                const index: usize = if (counts.data[0] >= 1 and @trunc(counts.data[0]) == counts.data[0])
                    j / try keepSize(counts.data[0])
                else
                    @intFromFloat(if (fraction <= std.math.floatEps(f64) or fraction >= 1 - std.math.floatEps(f64)) @round(t) else @floor(t));
                data[row * new_width + j] = x.data[row * width + @min(index, width - 1)];
            }
        } else {
            var dest = row * new_width;
            for (0..width) |i| {
                const count = try keepSize(@max(0, counts.data[i % counts.data.len]));
                @memset(data[dest..][0..count], x.data[row * width + i]);
                dest += count;
            }
        }
    }
    return .{ .data = data, .shape = shape };
}

fn keepSize(n: f64) !usize {
    if (!std.math.isFinite(n) or n >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return error.InvalidInput;
    return @intFromFloat(n);
}

pub fn base10(a: std.mem.Allocator, x: Value, _: Value) !Value {
    return base(a, x, .{ .data = &.{10} });
}

pub fn radix10(a: std.mem.Allocator, x: Value, _: Value) !Value {
    return radix(a, x, .{ .data = &.{10} });
}

fn validateBase(b: f64) !void {
    if (b == 0 or b == 1 or b == -1 or std.math.isNan(b) or (b > -1 and b < 0))
        return error.InvalidInput;
}

fn digitCount(n: f64, b: f64) !usize {
    if (n == 0) return 0;
    const log = if (b == 2) @log2(@abs(n)) else if (b == 10) @log10(@abs(n)) else @log(@abs(n)) / @log(b);
    if (std.math.isNan(log) or log < 0) return 1;
    if (!std.math.isFinite(log) or log >= @as(f64, @floatFromInt(std.math.maxInt(usize) - 1))) return error.InvalidInput;
    return @as(usize, @intFromFloat(log)) + 1;
}

// Adapted from Uiua's algorithm/dyadic/mod.rs. Digits occupy a new trailing axis.
pub fn base(a: std.mem.Allocator, x: Value, bases: Value) !Value {
    if (x.tuple != null or bases.tuple != null or bases.shape.len > 1) return error.InvalidInput;
    const scalar = bases.shape.len == 0;
    for (bases.data) |b| {
        try validateBase(b);
        if (std.math.isNegativeInf(b) or (scalar and !std.math.isFinite(b))) return error.InvalidInput;
    }
    for (x.data) |n| if (std.math.isInf(n)) return error.InvalidInput;
    var width: usize = if (scalar) 0 else bases.data.len;
    var negative_digits: std.ArrayList(f64) = .empty;
    defer negative_digits.deinit(a);
    const b = if (scalar) bases.data[0] else 0;
    if (scalar) {
        for (x.data) |n| {
            if (b > 0) {
                width = @max(width, try digitCount(n, b));
            } else {
                var remaining = n;
                var count: usize = 0;
                while (@abs(remaining) > std.math.floatEps(f64)) {
                    const digit = @mod(remaining, -b);
                    try negative_digits.append(a, digit);
                    remaining = @round((remaining - digit) / b);
                    count += 1;
                }
                width = @max(width, count);
                // NaN marks the end of each variable-length row.
                try negative_digits.append(a, std.math.nan(f64));
            }
        }
    }
    const shape = try a.alloc(usize, x.shape.len + 1);
    @memcpy(shape[0..x.shape.len], x.shape);
    shape[x.shape.len] = width;
    const data = try a.alloc(f64, try std.math.mul(usize, x.data.len, width));
    @memset(data, 0);
    var offset: usize = 0;
    for (x.data, 0..) |n, i| {
        if (scalar and b < 0) {
            var j: usize = 0;
            while (!std.math.isNan(negative_digits.items[offset])) : (offset += 1) {
                data[i * width + j] = negative_digits.items[offset];
                j += 1;
            }
            offset += 1;
        } else {
            var remaining = if (scalar) @abs(n) else n;
            for (0..width) |j| {
                const divisor = if (scalar) b else bases.data[j];
                if (scalar) {
                    const quotient = @floor(remaining / divisor);
                    data[i * width + j] = @mulAdd(f64, quotient, -divisor, remaining) * (if (n < 0) @as(f64, -1) else 1);
                    remaining = quotient;
                } else {
                    if (std.math.isPositiveInf(remaining)) {
                        data[i * width + j] = remaining;
                        break;
                    }
                    const digit = @mod(remaining, @abs(divisor));
                    data[i * width + j] = digit;
                    const remainder = @rem(remaining, divisor);
                    remaining = @trunc(remaining / divisor);
                    if (remainder < 0) remaining += if (divisor < 0) @as(f64, 1) else -1;
                }
            }
        }
    }
    return .{ .data = data, .shape = shape };
}

/// Uiua anti-base: collapse the trailing digit axis.
pub fn radix(a: std.mem.Allocator, x: Value, bases: Value) !Value {
    if (x.tuple != null or bases.tuple != null or bases.shape.len > 1) return error.InvalidInput;
    const shape = x.shape[0 .. x.shape.len - @intFromBool(x.shape.len > 0)];
    const width = if (x.shape.len == 0) 1 else x.shape[x.shape.len - 1];
    var count: usize = 1;
    for (shape) |dim| count = try std.math.mul(usize, count, dim);
    const data = try a.alloc(f64, count);
    @memset(data, 0);
    for (data, 0..) |*output, i| {
        var j = width;
        while (j > 0) {
            j -= 1;
            var b: f64 = if (bases.shape.len == 0) bases.data[0] else if (j < bases.data.len) bases.data[j] else 1;
            if (bases.shape.len != 0 and std.math.isInf(b)) {
                b = 1;
                for (bases.data[0..@min(width - j, bases.data.len)]) |factor| {
                    if (!std.math.isInf(factor)) b *= factor;
                }
            }
            output.* = @mulAdd(f64, output.*, b, x.data[i * width + j]);
        }
    }
    return .{ .data = data, .shape = try a.dupe(usize, shape) };
}
pub fn add(a: std.mem.Allocator, x: Value, y: Value) !Value {
    return arithmetic(a, x, y, .add);
}

pub fn mul(a: std.mem.Allocator, x: Value, y: Value) !Value {
    return arithmetic(a, x, y, .multiply);
}

pub fn sub(a: std.mem.Allocator, x: Value, y: Value) !Value {
    return arithmetic(a, x, y, .subtract);
}

// Numeric pervasive operations adapted from Uiua's algorithm/pervade.rs.
/// Nonzero values are true; boolean operations always return zero or one.
pub fn @"and"(a: std.mem.Allocator, x: Value, y: Value) !Value {
    return arithmetic(a, x, y, .boolean_and);
}

pub fn @"or"(a: std.mem.Allocator, x: Value, y: Value) !Value {
    return arithmetic(a, x, y, .boolean_or);
}

/// Swap the two innermost axes independently in each outer cell.
pub fn transpose(a: std.mem.Allocator, x: Value, _: Value) !Value {
    if (x.tuple != null) return error.InvalidInput;
    if (x.shape.len < 2) return x;
    const shape = try a.dupe(usize, x.shape);
    const rows = shape[shape.len - 2];
    const cols = shape[shape.len - 1];
    shape[shape.len - 2] = cols;
    shape[shape.len - 1] = rows;
    const data = try a.alloc(f64, x.data.len);
    for (data, 0..) |*item, i| {
        const cell_size = rows * cols;
        const offset = i % cell_size;
        item.* = x.data[i / cell_size * cell_size + offset % rows * cols + offset / rows];
    }
    return .{ .data = data, .shape = shape };
}

pub fn div(a: std.mem.Allocator, x: Value, y: Value) !Value {
    return arithmetic(a, x, y, .divide);
}

pub fn floor(a: std.mem.Allocator, x: Value, _: Value) !Value {
    return unary(a, x, .floor);
}

pub fn abs(a: std.mem.Allocator, x: Value, _: Value) !Value {
    return unary(a, x, .abs);
}

/// Uiua not: subtract each element from one, preserving the array's shape.
pub fn not(a: std.mem.Allocator, x: Value, _: Value) !Value {
    return unary(a, x, .not);
}

fn unary(a: std.mem.Allocator, x: Value, comptime op: enum { floor, abs, not }) !Value {
    if (x.tuple != null) return error.InvalidInput;
    const data = try a.alloc(f64, x.data.len);
    for (x.data, data) |item, *output| output.* = switch (op) {
        .floor => @floor(item),
        .abs => @abs(item),
        .not => 1 - item,
    };
    return .{ .data = data, .shape = try a.dupe(usize, x.shape) };
}

pub fn mod(a: std.mem.Allocator, x: Value, y: Value) !Value {
    return arithmetic(a, x, y, .modulo);
}

pub fn eq(a: std.mem.Allocator, x: Value, y: Value) !Value {
    return arithmetic(a, x, y, .equal);
}

pub fn not_eq(a: std.mem.Allocator, x: Value, y: Value) !Value {
    return arithmetic(a, x, y, .not_equal);
}

pub fn max(a: std.mem.Allocator, x: Value, y: Value) !Value {
    return arithmetic(a, x, y, .maximum);
}

fn arithmetic(a: std.mem.Allocator, x: Value, y: Value, comptime op: enum { add, multiply, subtract, divide, modulo, equal, not_equal, less, greater, maximum, boolean_and, boolean_or }) !Value {
    if (x.tuple != null or y.tuple != null) return error.InvalidInput;
    const n = @min(x.shape.len, y.shape.len);
    if (!std.mem.eql(usize, x.shape[0..n], y.shape[0..n])) return @import("runtime.zig").shapeMismatch(@src().fn_name, &.{ x, y });
    const big = if (x.shape.len >= y.shape.len) x else y;
    const data = try a.alloc(f64, big.data.len);
    for (data, 0..) |*d, i| {
        const xi = if (x.shape.len == big.shape.len) i else i / (big.data.len / x.data.len);
        const yi = if (y.shape.len == big.shape.len) i else i / (big.data.len / y.data.len);
        d.* = switch (op) {
            .boolean_and => @floatFromInt(@intFromBool(x.data[xi] != 0) & @intFromBool(y.data[yi] != 0)),
            .boolean_or => @floatFromInt(@intFromBool(x.data[xi] != 0) | @intFromBool(y.data[yi] != 0)),
            .add => x.data[xi] + y.data[yi],
            .multiply => x.data[xi] * y.data[yi],
            .maximum => @max(x.data[xi], y.data[yi]),
            .subtract => x.data[xi] - y.data[yi],
            .divide => x.data[xi] / y.data[yi],
            .modulo => if (y.data[yi] == 0) std.math.nan(f64) else @mod(x.data[xi], y.data[yi]),
            .less => @floatFromInt(@intFromBool(x.data[xi] < y.data[yi])),
            .greater => @floatFromInt(@intFromBool(x.data[xi] > y.data[yi])),
            .equal => @floatFromInt(@intFromBool(x.data[xi] == y.data[yi])),
            .not_equal => @floatFromInt(@intFromBool(x.data[xi] != y.data[yi])),
        };
    }
    return .{ .data = data, .shape = try a.dupe(usize, big.shape) };
}
pub fn couple(a: std.mem.Allocator, x: Value, y: Value) !Value {
    if (x.tuple != null or y.tuple != null) return error.InvalidInput;
    if (!std.mem.eql(usize, x.shape, y.shape)) return @import("runtime.zig").shapeMismatch(@src().fn_name, &.{ x, y });
    const shape = try a.alloc(usize, x.shape.len + 1);
    shape[0] = 2;
    @memcpy(shape[1..], x.shape);
    const data = try a.alloc(f64, x.data.len + y.data.len);
    @memcpy(data[0..x.data.len], x.data);
    @memcpy(data[x.data.len..], y.data);
    return .{ .data = data, .shape = shape };
}

pub fn id(_: std.mem.Allocator, x: Value, _: Value) !Value {
    return x;
}

/// Uiua take: signed counts select leading/trailing rows on each indexed axis.
/// Without a fill context, taking beyond an axis is an error.
pub fn take(a: std.mem.Allocator, x: Value, counts: Value) !Value {
    if (x.tuple != null or counts.tuple != null or counts.shape.len > 1) return error.InvalidInput;
    const source_shape: []const usize = if (x.shape.len == 0) &.{1} else x.shape;
    if (counts.data.len > source_shape.len) return @import("runtime.zig").shapeMismatch(@src().fn_name, &.{ x, counts });
    const shape = try a.dupe(usize, source_shape);
    const starts = try a.alloc(usize, shape.len);
    @memset(starts, 0);
    for (counts.data, 0..) |count, axis| {
        if (!std.math.isFinite(count) or @trunc(count) != count) return error.InvalidInput;
        if (@abs(count) > @as(f64, @floatFromInt(source_shape[axis]))) return @import("runtime.zig").shapeMismatch(@src().fn_name, &.{ x, counts });
        const amount: usize = @intFromFloat(@abs(count));
        shape[axis] = amount;
        if (count < 0) starts[axis] = source_shape[axis] - amount;
    }
    var size: usize = 1;
    for (shape) |dim| size = try std.math.mul(usize, size, dim);
    const data = try a.alloc(f64, size);
    for (data, 0..) |*item, index| {
        var remaining = index;
        var source_index: usize = 0;
        var stride: usize = 1;
        var axis = shape.len;
        while (axis > 0) {
            axis -= 1;
            source_index += (remaining % shape[axis] + starts[axis]) * stride;
            remaining /= shape[axis];
            stride *= source_shape[axis];
        }
        item.* = x.data[source_index];
    }
    return .{ .data = data, .shape = shape };
}

pub fn less(a: std.mem.Allocator, x: Value, y: Value) !Value {
    return arithmetic(a, x, y, .less);
}

pub fn greater(a: std.mem.Allocator, x: Value, y: Value) !Value {
    return arithmetic(a, x, y, .greater);
}
