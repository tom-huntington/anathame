const std = @import("std");
const Value = @import("runtime.zig").Value;

/// Print a value and return it unchanged.
pub fn log(a: std.mem.Allocator, x: Value, _: Value) !Value {
    var text: std.Io.Writer.Allocating = .init(a);
    defer text.deinit();
    try @import("runtime.zig").writeValue(&text.writer, x);
    std.debug.print("{s}\n", .{text.written()});
    return x;
}

/// Number of leading-axis rows; scalars have one row.
pub fn length(a: std.mem.Allocator, x: Value, _: Value) !Value {
    if (x.tuple != null) return error.ExpectedArray;
    const data = try a.alloc(f64, 1);
    data[0] = @floatFromInt(if (x.shape.len == 0) @as(usize, 1) else x.shape[0]);
    return .{ .data = data };
}

/// Integers from start up to, but excluding, sentinel. Reversed bounds are empty.
pub fn range(a: std.mem.Allocator, start: Value, sentinel: Value) !Value {
    return integerRange(a, start, sentinel, false);
}

/// Integers from start through end, including both bounds. Reversed bounds are empty.
pub fn range_inclusive(a: std.mem.Allocator, start: Value, end: Value) !Value {
    return integerRange(a, start, end, true);
}

fn integerRange(a: std.mem.Allocator, start: Value, sentinel: Value, inclusive: bool) !Value {
    if (start.tuple != null or sentinel.tuple != null or
        start.shape.len != 0 or sentinel.shape.len != 0 or
        start.data.len != 1 or sentinel.data.len != 1) return error.InvalidInput;
    const first = start.data[0];
    const end = sentinel.data[0];
    if (!std.math.isFinite(first) or !std.math.isFinite(end) or
        @trunc(first) != first or @trunc(end) != end) return error.InvalidInput;
    const range_length = if (end < first) 0 else end - first + @as(f64, if (inclusive) 1 else 0);
    if (range_length >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return error.InvalidInput;
    const size: usize = @intFromFloat(range_length);
    const data = try a.alloc(f64, size);
    for (data, 0..) |*item, i| item.* = first + @as(f64, @floatFromInt(i));
    return .{ .data = data, .shape = try a.dupe(usize, &.{size}) };
}

/// Zero-based integer indices below a nonnegative scalar count.
pub fn iota(a: std.mem.Allocator, x: Value, _: Value) !Value {
    if (x.tuple != null or x.shape.len != 0 or x.data.len != 1 or x.data[0] < 0)
        return error.InvalidInput;
    return range(a, .{ .data = &.{0} }, x);
}

/// Count occurrences of scalar y among the elements of array x.
pub fn count(a: std.mem.Allocator, x: Value, y: Value) !Value {
    if (x.tuple != null or y.tuple != null or y.shape.len != 0 or y.data.len != 1)
        return error.InvalidInput;
    var occurrences: usize = 0;
    for (x.data) |item| {
        if (item == y.data[0]) occurrences += 1;
    }
    return .{ .data = try a.dupe(f64, &.{@floatFromInt(occurrences)}) };
}

/// Parse a scalar character or character vector as a number.
pub fn parse(a: std.mem.Allocator, x: Value, _: Value) !Value {
    if (x.tuple != null or x.shape.len > 1) return error.InvalidInput;
    const bytes = try a.alloc(u8, try std.math.mul(usize, x.data.len, 4));
    defer a.free(bytes);
    var len: usize = 0;
    for (x.data) |value| {
        if (!std.math.isFinite(value) or value < 0 or value > 0x10ffff or
            @trunc(value) != value) return error.InvalidInput;
        const codepoint: u21 = @intFromFloat(value);
        len += std.unicode.utf8Encode(codepoint, bytes[len..]) catch return error.InvalidInput;
    }
    const number = std.fmt.parseFloat(f64, bytes[0..len]) catch return error.InvalidInput;
    return .{ .data = try a.dupe(f64, &.{number}) };
}

/// Extract contiguous runs of ASCII digits as a vector of numbers.
pub fn ints(a: std.mem.Allocator, x: Value, _: Value) !Value {
    if (x.tuple != null or x.shape.len > 1) return error.InvalidInput;
    var numbers: std.ArrayList(f64) = .empty;
    defer numbers.deinit(a);
    var number: f64 = 0;
    var in_digits = false;
    for (x.data) |character| {
        if (!std.math.isFinite(character) or character < 0 or character > 0x10ffff or
            @trunc(character) != character or (character >= 0xd800 and character <= 0xdfff))
            return error.InvalidInput;
        if (character >= '0' and character <= '9') {
            number = number * 10 + character - '0';
            in_digits = true;
        } else if (in_digits) {
            try numbers.append(a, number);
            number = 0;
            in_digits = false;
        }
    }
    if (in_digits) try numbers.append(a, number);
    const shape = try a.dupe(usize, &.{numbers.items.len});
    errdefer a.free(shape);
    return .{ .data = try numbers.toOwnedSlice(a), .shape = shape };
}

/// Extract individual ASCII digits as a vector.
pub fn digits(a: std.mem.Allocator, x: Value, _: Value) !Value {
    return extractDigits(a, x, false);
}

/// Extract digit-bearing lines as equally sized rows of a matrix.
pub fn digits2d(a: std.mem.Allocator, x: Value, _: Value) !Value {
    return extractDigits(a, x, true);
}

fn extractDigits(a: std.mem.Allocator, x: Value, matrix: bool) !Value {
    if (x.tuple != null or x.shape.len > 1) return error.InvalidInput;
    var numbers: std.ArrayList(f64) = .empty;
    defer numbers.deinit(a);
    var width: ?usize = null;
    var row_start: usize = 0;
    var rows: usize = 0;
    for (0..x.data.len + 1) |i| {
        const character = if (i < x.data.len) x.data[i] else '\n';
        if (!std.math.isFinite(character) or character < 0 or character > 0x10ffff or
            @trunc(character) != character or (character >= 0xd800 and character <= 0xdfff))
            return error.InvalidInput;
        if (character >= '0' and character <= '9') {
            try numbers.append(a, character - '0');
        } else if (matrix and character == '\n' and numbers.items.len > row_start) {
            const row_width = numbers.items.len - row_start;
            if (width) |expected| {
                if (row_width != expected) return error.ShapeMismatch;
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
        try @import("runtime.zig").writeValue(&text.writer, .{ .data = &.{number} });
        const length_ = text.written().len - start;
        if (i == 0) width = length_ else if (length_ != width) return error.ShapeMismatch;
    }
    const bytes = text.written();
    const data = try a.alloc(f64, bytes.len);
    for (bytes, data) |byte, *character| character.* = @floatFromInt(byte);
    const shape = try a.alloc(usize, x.shape.len + 1);
    @memcpy(shape[0..x.shape.len], x.shape);
    shape[x.shape.len] = width;
    return .{ .data = data, .shape = shape };
}

pub fn sq(a: std.mem.Allocator, x: Value, _: Value) !Value {
    return @import("uiua_builtins.zig").mul(a, x, x);
}

/// Split an array's rows at an integer index; negative indices count from the end.
pub fn split_at(a: std.mem.Allocator, x: Value, index: Value) !Value {
    if (x.tuple != null or x.shape.len == 0 or index.tuple != null or
        index.shape.len != 0 or index.data.len != 1) return error.InvalidInput;
    const row_count = index.data[0];
    if (!std.math.isFinite(row_count) or @trunc(row_count) != row_count) return error.InvalidInput;
    if (@abs(row_count) > @as(f64, @floatFromInt(x.shape[0]))) return error.ShapeMismatch;
    const amount: usize = @intFromFloat(@abs(row_count));
    const split = if (row_count < 0) x.shape[0] - amount else amount;
    var row_size: usize = 1;
    for (x.shape[1..]) |dim| row_size = try std.math.mul(usize, row_size, dim);
    const left_shape = try a.dupe(usize, x.shape);
    const right_shape = try a.dupe(usize, x.shape);
    left_shape[0] = split;
    right_shape[0] -= split;
    const values = try a.alloc(Value, 2);
    values[0] = .{ .data = x.data[0 .. split * row_size], .shape = left_shape };
    values[1] = .{ .data = x.data[split * row_size ..], .shape = right_shape };
    return .{ .tuple = values };
}

/// Return the first row and the remaining rows.
pub fn uncons(a: std.mem.Allocator, x: Value, _: Value) !Value {
    const parts = try split_at(a, x, .{ .data = &.{1} });
    const values = try a.dupe(Value, parts.tuple.?);
    values[0].shape = values[0].shape[1..];
    return .{ .tuple = values };
}

/// Take rows from the front, or from the back for a negative count.
pub fn take(a: std.mem.Allocator, x: Value, row_count: Value) !Value {
    const parts = try split_at(a, x, row_count);
    return parts.tuple.?[if (row_count.data[0] < 0) @as(usize, 1) else 0];
}

/// Drop rows from the front, or from the back for a negative count.
pub fn drop(a: std.mem.Allocator, x: Value, row_count: Value) !Value {
    const parts = try split_at(a, x, row_count);
    return parts.tuple.?[if (row_count.data[0] < 0) @as(usize, 0) else 1];
}

/// Prepend a row y to the leading axis of array x.
pub fn prepend(a: std.mem.Allocator, x: Value, y: Value) !Value {
    if (x.tuple != null or y.tuple != null) return error.ExpectedArray;
    if (x.shape.len == 0 or !std.mem.eql(usize, x.shape[1..], y.shape)) return error.ShapeMismatch;
    const shape = try a.dupe(usize, x.shape);
    shape[0] = try std.math.add(usize, shape[0], 1);
    const data = try a.alloc(f64, try std.math.add(usize, x.data.len, y.data.len));
    @memcpy(data[0..y.data.len], y.data);
    @memcpy(data[y.data.len..], x.data);
    return .{ .data = data, .shape = shape };
}
