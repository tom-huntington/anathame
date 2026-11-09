//! Non-pervasive operations with a natural interpretation independent of axis selection.

const std = @import("std");
const Value = @import("../runtime.zig").Value;

/// Pick a cell by leading-axis coordinates, or a batch of coordinate vectors.
/// The last index axis holds coordinates; preceding axes shape the batch.
pub fn pick(a: std.mem.Allocator, source: Value, indices: Value) !Value {
    if (source.tuple != null or indices.tuple != null) return error.ExpectedArray;
    const depth = if (indices.shape.len == 0) @as(usize, 1) else indices.shape[indices.shape.len - 1];
    if (depth > source.shape.len) return error.InvalidInput;
    const batch = indices.shape[0..indices.shape.len -| 1];
    const trailing = source.shape[depth..];
    const shape = try a.alloc(usize, batch.len + trailing.len);
    errdefer a.free(shape);
    @memcpy(shape[0..batch.len], batch);
    @memcpy(shape[batch.len..], trailing);
    var cell_count: usize = 1;
    for (batch) |dim| cell_count = try std.math.mul(usize, cell_count, dim);
    var width: usize = 1;
    for (trailing) |dim| width = try std.math.mul(usize, width, dim);
    const data = try a.alloc(f64, try std.math.mul(usize, cell_count, width));
    errdefer a.free(data);
    // Uiua returns empty batches without resolving their coordinates.
    if (indices.shape.len > 1 and data.len == 0) return .{ .data = data, .shape = shape };
    for (0..cell_count) |cell| {
        var offset: usize = 0;
        for (source.shape[0..depth], indices.data[cell * depth ..][0..depth]) |dim, index| {
            offset = try std.math.add(usize, try std.math.mul(usize, offset, dim), try selectionIndex(index, dim));
        }
        const start = try std.math.mul(usize, offset, width);
        @memcpy(data[cell * width ..][0..width], source.data[start..][0..width]);
    }
    return .{ .data = data, .shape = shape };
}

fn selectionIndex(index: f64, size: usize) !usize {
    if (!std.math.isFinite(index) or @trunc(index) != index) return error.InvalidInput;
    const limit: f64 = @floatFromInt(size);
    if (index >= limit or index < -limit or @abs(index) >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return error.IndexOutOfBounds;
    const magnitude: usize = @intFromFloat(@abs(index));
    return if (index < 0) size - magnitude else magnitude;
}

/// Look up a process environment variable and parse its value as one literal.
pub fn env(a: std.mem.Allocator, x: Value, _: Value) !Value {
    if (x.tuple != null or x.shape.len != 1) return error.ExpectedString;
    var name: std.ArrayList(u8) = .empty;
    defer name.deinit(a);
    for (x.data) |number| {
        if (!std.math.isFinite(number) or number < 0 or number > 0x10ffff or @trunc(number) != number)
            return error.InvalidCharacter;
        var encoded: [4]u8 = undefined;
        const length = try std.unicode.utf8Encode(@intFromFloat(number), &encoded);
        try name.appendSlice(a, encoded[0..length]);
    }
    const text = try @import("../environment.zig").get(a, name.items);
    defer a.free(text);
    const instructions = try @import("../parser.zig").parse(a, text);
    if (instructions.len != 1) return error.ExpectedLiteral;
    return switch (instructions[0]) {
        .literal => |value| value,
        else => error.ExpectedLiteral,
    };
}

/// Uiua deshape: collect all elements into a single vector in storage order.
pub fn flatten(a: std.mem.Allocator, x: Value, _: Value) !Value {
    if (x.tuple != null) return error.ExpectedArray;
    return .{ .data = x.data, .shape = try a.dupe(usize, &.{x.data.len}) };
}

/// Remove every length-one axis without changing the array's data.
pub fn squeeze(a: std.mem.Allocator, x: Value, _: Value) !Value {
    if (x.tuple != null) return error.ExpectedArray;
    var rank: usize = 0;
    for (x.shape) |dimension| {
        if (dimension != 1) rank += 1;
    }
    if (rank == x.shape.len) return x;
    const shape = try a.alloc(usize, rank);
    var axis: usize = 0;
    for (x.shape) |dimension| {
        if (dimension != 1) {
            shape[axis] = dimension;
            axis += 1;
        }
    }
    return .{ .data = x.data, .shape = shape };
}

/// Print a value and return it unchanged.
pub fn log(a: std.mem.Allocator, x: Value, _: Value) !Value {
    try @import("../logging.zig").printArguments(a, x, null, false, null);
    return x;
}

/// Print both arguments and return the right argument unchanged.
pub fn logr(a: std.mem.Allocator, x: Value, y: Value) !Value {
    try @import("../logging.zig").printArguments(a, x, y, false, null);
    return y;
}

/// Print both arguments and return the left argument unchanged.
pub fn logl(a: std.mem.Allocator, x: Value, y: Value) !Value {
    try @import("../logging.zig").printArguments(a, x, y, false, null);
    return x;
}

/// Print rows as Unicode strings and return the original numeric value.
pub fn @"log.str"(a: std.mem.Allocator, x: Value, _: Value) !Value {
    try @import("../logging.zig").printArguments(a, x, null, true, null);
    return x;
}

/// Integers from start up to, but excluding, sentinel. Reversed bounds are empty.
pub fn range(a: std.mem.Allocator, start: Value, sentinel: Value) !Value {
    return integerRange(a, start, sentinel, false);
}

/// Integers from start through end, including both bounds. Reversed bounds are empty.
pub fn range_inclusive(a: std.mem.Allocator, start: Value, end: Value) !Value {
    return integerRange(a, start, end, true);
}

/// Elementwise membership in the inclusive interval [lower, upper].
pub fn @"in.closed"(a: std.mem.Allocator, x: Value, bounds: Value) !Value {
    if (x.tuple != null or bounds.tuple != null or
        bounds.shape.len != 1 or bounds.shape[0] != 2 or bounds.data.len != 2)
        return error.InvalidInput;
    const data = try a.alloc(f64, x.data.len);
    for (x.data, data) |item, *result| {
        result.* = @floatFromInt(@intFromBool(item >= bounds.data[0] and item <= bounds.data[1]));
    }
    return .{ .data = data, .shape = x.shape };
}

fn integerRange(a: std.mem.Allocator, start: Value, sentinel: Value, inclusive: bool) !Value {
    if (start.tuple != null or sentinel.tuple != null or
        start.shape.len != 0 or sentinel.shape.len != 0 or
        start.data.len != 1 or sentinel.data.len != 1) return error.InvalidInput;
    const begin = start.data[0];
    const end = sentinel.data[0];
    if (!std.math.isFinite(begin) or !std.math.isFinite(end) or
        @trunc(begin) != begin or @trunc(end) != end) return error.InvalidInput;
    const range_length = if (end < begin) 0 else end - begin + @as(f64, if (inclusive) 1 else 0);
    if (range_length >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return error.InvalidInput;
    const size: usize = @intFromFloat(range_length);
    const data = try a.alloc(f64, size);
    for (data, 0..) |*item, i| item.* = begin + @as(f64, @floatFromInt(i));
    return .{ .data = data, .shape = try a.dupe(usize, &.{size}) };
}

/// Zero-based integer indices below a nonnegative scalar count.
pub fn iota(a: std.mem.Allocator, x: Value, _: Value) !Value {
    if (x.tuple != null or x.shape.len != 0 or x.data.len != 1 or x.data[0] < 0)
        return error.InvalidInput;
    return range(a, .{ .data = &.{0} }, x);
}

/// Extract integer-bearing lines as equally sized rows of a matrix.
pub fn ints2d(a: std.mem.Allocator, x: Value, _: Value) !Value {
    return extractNumbers(a, x, true, true);
}

/// Extract individual ASCII digits as a vector.
pub fn digits(a: std.mem.Allocator, x: Value, _: Value) !Value {
    return extractNumbers(a, x, false, false);
}

/// Extract digit-bearing lines as equally sized rows of a matrix.
pub fn digits2d(a: std.mem.Allocator, x: Value, _: Value) !Value {
    return extractNumbers(a, x, true, false);
}

pub fn extractNumbers(a: std.mem.Allocator, x: Value, matrix: bool, integers: bool) !Value {
    if (x.tuple != null or x.shape.len > 1) return error.InvalidInput;
    var numbers: std.ArrayList(f64) = .empty;
    defer numbers.deinit(a);
    var width: ?usize = null;
    var row_start: usize = 0;
    var rows: usize = 0;
    var number: f64 = 0;
    var in_digits = false;
    for (0..x.data.len + 1) |i| {
        const character = if (i < x.data.len) x.data[i] else '\n';
        if (!std.math.isFinite(character) or character < 0 or character > 0x10ffff or
            @trunc(character) != character or (character >= 0xd800 and character <= 0xdfff))
            return error.InvalidInput;
        if (character >= '0' and character <= '9') {
            if (integers) {
                number = number * 10 + character - '0';
                in_digits = true;
            } else {
                try numbers.append(a, character - '0');
            }
        } else if (in_digits) {
            try numbers.append(a, number);
            number = 0;
            in_digits = false;
        }
        if (matrix and character == '\n' and numbers.items.len > row_start) {
            const row_width = numbers.items.len - row_start;
            if (width) |expected| {
                if (row_width != expected) return @import("../runtime.zig").shapeMismatch(@src().fn_name, &.{ .{ .data = numbers.items[0..expected], .shape = &.{expected} }, .{ .data = numbers.items[row_start..], .shape = &.{row_width} } });
            } else width = row_width;
            rows += 1;
            row_start = numbers.items.len;
        }
    }
    const shape = if (matrix)
        try a.dupe(usize, &.{ rows, width orelse 0 })
    else
        try a.dupe(usize, &.{numbers.items.len});
    errdefer a.free(shape);
    return .{ .data = try numbers.toOwnedSlice(a), .shape = shape };
}

/// Format each scalar as characters, appending a character axis to the shape.
pub fn to_string(a: std.mem.Allocator, x: Value, _: Value) !Value {
    if (x.tuple != null) return error.ExpectedArray;
    var text: std.Io.Writer.Allocating = .init(a);
    defer text.deinit();
    var width: usize = 0;
    for (x.data, 0..) |number, i| {
        const start = text.written().len;
        try text.writer.print("{d}", .{number});
        const length_ = text.written().len - start;
        if (i == 0) width = length_ else if (length_ != width) {
            std.debug.print("Formatted widths differ: {d} and {d}\n", .{ width, length_ });
            return @import("../runtime.zig").shapeMismatch(@src().fn_name, &.{ .{ .data = x.data[0..1] }, .{ .data = x.data[i..][0..1] } });
        }
    }
    const bytes = text.written();
    const data = try a.alloc(f64, bytes.len);
    for (bytes, data) |byte, *character| character.* = @floatFromInt(byte);
    const shape = try a.alloc(usize, x.shape.len + 1);
    @memcpy(shape[0..x.shape.len], x.shape);
    shape[x.shape.len] = width;
    return .{ .data = data, .shape = shape };
}

/// Construct a pair without requiring equally shaped values.
pub fn tuple(a: std.mem.Allocator, x: Value, y: Value) !Value {
    return .{ .tuple = try a.dupe(Value, &.{ x, y }) };
}

fn natural(value: f64) !usize {
    if (!std.math.isFinite(value) or value < 0 or @trunc(value) != value or
        value >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return error.InvalidInput;
    return @intFromFloat(value);
}

/// Ones on the main diagonal of a shape; a scalar requests a square matrix.
pub fn eye(a: std.mem.Allocator, dimensions: Value, _: Value) !Value {
    if (dimensions.tuple != null or dimensions.shape.len > 1) return error.InvalidInput;
    const scalar = dimensions.shape.len == 0;
    if (scalar and dimensions.data.len != 1) return error.InvalidInput;
    const shape = try a.alloc(usize, if (scalar) 2 else dimensions.data.len);
    errdefer a.free(shape);
    for (shape, 0..) |*dimension, axis| {
        dimension.* = try natural(dimensions.data[if (scalar) 0 else axis]);
    }
    var count: usize = 1;
    var diagonal: usize = if (shape.len == 0) 1 else std.math.maxInt(usize);
    for (shape) |dimension| {
        count = try std.math.mul(usize, count, dimension);
        diagonal = @min(diagonal, dimension);
    }
    const data = try a.alloc(f64, count);
    @memset(data, 0);
    for (0..diagonal) |i| {
        var index: usize = 0;
        for (shape) |dimension| index = index * dimension + i;
        data[index] = 1;
    }
    return .{ .data = data, .shape = shape };
}

/// Repeat each index (or coordinate row) by its natural-number count, as in Uiua.
pub fn where(a: std.mem.Allocator, value: Value, _: Value) !Value {
    if (value.tuple != null) return error.InvalidInput;
    var total: usize = 0;
    for (value.data) |count| total = try std.math.add(usize, total, try natural(count));
    const rank = value.shape.len;
    const width = @max(1, rank);
    const data = try a.alloc(f64, try std.math.mul(usize, total, width));
    errdefer a.free(data);
    var offset: usize = 0;
    for (value.data, 0..) |count, index| {
        for (0..try natural(count)) |_| {
            if (rank <= 1) {
                data[offset] = @floatFromInt(if (rank == 0) 0 else index);
            } else {
                var remaining = index;
                var axis = rank;
                while (axis > 0) {
                    axis -= 1;
                    data[offset + axis] = @floatFromInt(remaining % value.shape[axis]);
                    remaining /= value.shape[axis];
                }
            }
            offset += width;
        }
    }
    const shape = try a.alloc(usize, if (rank <= 1) 1 else 2);
    shape[0] = total;
    if (rank > 1) shape[1] = rank;
    return .{ .data = data, .shape = shape };
}

/// Count indices or coordinate rows, inferring each axis from its maximum index.
pub fn unwhere(a: std.mem.Allocator, value: Value, _: Value) !Value {
    if (value.tuple != null or value.shape.len > 2) return error.InvalidInput;
    const coordinates = value.shape.len == 2;
    const rank = if (coordinates) value.shape[1] else 1;
    const rows = if (coordinates) value.shape[0] else value.data.len;
    const shape = try a.alloc(usize, rank);
    errdefer a.free(shape);
    @memset(shape, 0);
    for (value.data, 0..) |item, i| {
        const size = try std.math.add(usize, try natural(item), 1);
        const axis = if (coordinates) i % rank else 0;
        shape[axis] = @max(shape[axis], size);
    }
    var size: usize = 1;
    for (shape) |dim| size = try std.math.mul(usize, size, dim);
    const data = try a.alloc(f64, size);
    @memset(data, 0);
    for (0..rows) |row| {
        var index: usize = 0;
        for (shape, 0..) |dim, axis| {
            index = index * dim + (natural(value.data[if (coordinates) row * rank + axis else row]) catch unreachable);
        }
        data[index] += 1;
    }
    return .{ .data = data, .shape = shape };
}

/// Count directed edge pairs, padding the smaller axis with zeros to make a square.
pub fn adjacency_matrix(a: std.mem.Allocator, value: Value, unused: Value) !Value {
    if (value.tuple != null or value.shape.len != 2 or value.shape[1] != 2) return error.InvalidInput;
    const matrix = try unwhere(a, value, unused);
    const side = @max(matrix.shape[0], matrix.shape[1]);
    if (matrix.shape[0] == matrix.shape[1]) return matrix;
    defer a.free(matrix.data);
    defer a.free(matrix.shape);
    const shape = try a.dupe(usize, &.{ side, side });
    errdefer a.free(shape);
    const data = try a.alloc(f64, try std.math.mul(usize, side, side));
    @memset(data, 0);
    for (0..matrix.shape[0]) |row| {
        @memcpy(data[row * side ..][0..matrix.shape[1]], matrix.data[row * matrix.shape[1] ..][0..matrix.shape[1]]);
    }
    return .{ .data = data, .shape = shape };
}

/// Dimension sizes as a vector, as in Uiua; scalars have an empty shape.
pub fn arrayShape(a: std.mem.Allocator, value: Value, _: Value) !Value {
    if (value.tuple != null) return error.ExpectedArray;
    const data = try a.alloc(f64, value.shape.len);
    errdefer a.free(data);
    for (value.shape, data) |dimension, *item| item.* = @floatFromInt(dimension);
    return .{ .data = data, .shape = try a.dupe(usize, &.{value.shape.len}) };
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
    if (count > 0 and value.data.len == 0) return @import("../runtime.zig").shapeMismatch(@src().fn_name, &.{ value, dimensions });
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
    if (count != 0 and value.data.len == 0) return @import("../runtime.zig").shapeMismatch(@src().fn_name, &.{ value, dimensions });
    const data = try a.alloc(f64, count);
    for (data, 0..) |*item, i| item.* = value.data[i % value.data.len];
    return .{ .data = data, .shape = shape };
}

pub fn base10(a: std.mem.Allocator, x: Value, _: Value) !Value {
    return base(a, x, .{ .data = &.{10} });
}

fn validateBase(b: f64) !void {
    if (b == 0 or b == 1 or b == -1 or std.math.isNan(b) or (b > -1 and b < 0))
        return error.InvalidInput;
}

fn digitCount(n: f64, b: f64) !usize {
    if (n == 0) return 0;
    const logarithm = if (b == 2) @log2(@abs(n)) else if (b == 10) @log10(@abs(n)) else @log(@abs(n)) / @log(b);
    if (std.math.isNan(logarithm) or logarithm < 0) return 1;
    if (!std.math.isFinite(logarithm) or logarithm >= @as(f64, @floatFromInt(std.math.maxInt(usize) - 1))) return error.InvalidInput;
    return @as(usize, @intFromFloat(logarithm)) + 1;
}

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

/// Uiua join: concatenate rows, extending lower-rank arguments to a full row.
pub fn join(a: std.mem.Allocator, x: Value, y: Value) !Value {
    if (x.tuple != null or y.tuple != null) return error.ExpectedArray;
    const xr = x.shape.len;
    const yr = y.shape.len;
    // Uiua's empty vector is an identity when joining different ranks.
    if (xr < yr and xr == 1 and x.shape[0] == 0) return y;
    if (yr < xr and yr == 1 and y.shape[0] == 0) return x;
    const rank = @max(1, @max(xr, yr));
    const larger = if (xr >= yr) x else y;
    const row_shape = larger.shape[@min(1, larger.shape.len)..];
    if (xr == yr) {
        if (xr > 0 and !std.mem.eql(usize, x.shape[1..], y.shape[1..]))
            return @import("../runtime.zig").shapeMismatch(@src().fn_name, &.{ x, y });
    } else {
        const smaller = if (xr < yr) x else y;
        if (!std.mem.endsWith(usize, row_shape, smaller.shape))
            return @import("../runtime.zig").shapeMismatch(@src().fn_name, &.{ x, y });
    }
    var row_size: usize = 1;
    for (row_shape) |dim| row_size = try std.math.mul(usize, row_size, dim);
    const x_rows = if (xr == rank) x.shape[0] else 1;
    const y_rows = if (yr == rank) y.shape[0] else 1;
    const shape = try a.alloc(usize, rank);
    errdefer a.free(shape);
    shape[0] = try std.math.add(usize, x_rows, y_rows);
    @memcpy(shape[1..], row_shape);
    const x_size = try std.math.mul(usize, x_rows, row_size);
    const data = try a.alloc(f64, try std.math.mul(usize, shape[0], row_size));
    // Lower-rank arrays repeat cyclically to fill the missing row dimensions.
    for (data[0..x_size], 0..) |*item, i| item.* = x.data[i % x.data.len];
    for (data[x_size..], 0..) |*item, i| item.* = y.data[i % y.data.len];
    return .{ .data = data, .shape = shape };
}

pub fn couple(a: std.mem.Allocator, x: Value, y: Value) !Value {
    if (x.tuple != null or y.tuple != null) return error.InvalidInput;
    if (!std.mem.eql(usize, x.shape, y.shape)) return @import("../runtime.zig").shapeMismatch(@src().fn_name, &.{ x, y });
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
