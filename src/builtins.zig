const std = @import("std");
const Value = @import("runtime.zig").Value;

/// Keep every nth element along the trailing axis, starting with the first.
pub fn stride(a: std.mem.Allocator, x: Value, step: Value) !Value {
    return strideAxis(a, x, step, 1);
}

/// Keep every nth row along axis -2 in each outer cell.
pub fn @"stride.rows"(a: std.mem.Allocator, x: Value, step: Value) !Value {
    return strideAxis(a, x, step, 2);
}

fn strideAxis(a: std.mem.Allocator, x: Value, step: Value, depth: usize) !Value {
    if (x.tuple != null) return error.ExpectedArray;
    if (step.tuple != null or step.shape.len != 0 or step.data.len != 1)
        return error.InvalidInput;
    const n = step.data[0];
    if (!std.math.isFinite(n) or n <= 0 or @trunc(n) != n or
        n >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return error.InvalidInput;
    const amount: usize = @intFromFloat(n);
    if (x.shape.len < depth) return x;
    const axis = x.shape.len - depth;
    const size = x.shape[axis];
    const selected = size / amount + @intFromBool(size % amount != 0);
    const shape = try a.dupe(usize, x.shape);
    errdefer a.free(shape);
    shape[axis] = selected;
    var width: usize = 1;
    for (x.shape[axis + 1 ..]) |dim| width = try std.math.mul(usize, width, dim);
    var cells: usize = 1;
    for (x.shape[0..axis]) |dim| cells = try std.math.mul(usize, cells, dim);
    const data = try a.alloc(f64, try std.math.mul(usize, cells, try std.math.mul(usize, selected, width)));
    for (0..cells) |cell| {
        for (0..selected) |i| {
            const source = (cell * size + i * amount) * width;
            const dest = (cell * selected + i) * width;
            @memcpy(data[dest..][0..width], x.data[source..][0..width]);
        }
    }
    return .{ .data = data, .shape = shape };
}

/// Return the first tuple element. Array support is not implemented yet.
pub fn first(_: std.mem.Allocator, x: Value, _: Value) !Value {
    const items = x.tuple orelse return error.UnimplementedPrimitive;
    if (items.len == 0) return error.InvalidInput;
    return items[0];
}

/// Select the last row along axis -2 in each outer cell, removing that axis.
/// Scalars and vectors have no row axis and are returned unchanged.
pub fn lastrow(a: std.mem.Allocator, x: Value, _: Value) !Value {
    if (x.tuple != null) return error.ExpectedArray;
    if (x.shape.len < 2) return x;
    const axis = x.shape.len - 2;
    const rows = x.shape[axis];
    if (rows == 0) return error.InvalidInput;
    const width = x.shape[axis + 1];
    var cells: usize = 1;
    for (x.shape[0..axis]) |dim| cells = try std.math.mul(usize, cells, dim);
    const shape = try a.alloc(usize, x.shape.len - 1);
    errdefer a.free(shape);
    @memcpy(shape[0..axis], x.shape[0..axis]);
    shape[axis] = width;
    const data = try a.alloc(f64, try std.math.mul(usize, cells, width));
    for (0..cells) |cell| {
        const start = (cell * rows + rows - 1) * width;
        @memcpy(data[cell * width ..][0..width], x.data[start..][0..width]);
    }
    return .{ .data = data, .shape = shape };
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

/// Reverse the trailing axis, preserving the order of all outer axes.
pub fn reverse(a: std.mem.Allocator, x: Value, _: Value) !Value {
    if (x.tuple != null) return error.ExpectedArray;
    const data = try a.dupe(f64, x.data);
    const width = if (x.shape.len == 0) 1 else x.shape[x.shape.len - 1];
    if (width > 1) {
        var offset: usize = 0;
        while (offset < data.len) : (offset += width) {
            std.mem.reverse(f64, data[offset..][0..width]);
        }
    }
    return .{ .data = data, .shape = x.shape };
}

/// Print a value and return it unchanged.
pub fn log(a: std.mem.Allocator, x: Value, _: Value) !Value {
    try printArguments(a, x, null, false);
    return x;
}

/// Print both arguments and return the right argument unchanged.
pub fn logr(a: std.mem.Allocator, x: Value, y: Value) !Value {
    try printArguments(a, x, y, false);
    return y;
}

/// Print both arguments and return the left argument unchanged.
pub fn logl(a: std.mem.Allocator, x: Value, y: Value) !Value {
    try printArguments(a, x, y, false);
    return x;
}

/// Print rows as Unicode strings and return the original numeric value.
pub fn @"log.str"(a: std.mem.Allocator, x: Value, _: Value) !Value {
    try printArguments(a, x, null, true);
    return x;
}

fn printArguments(a: std.mem.Allocator, x: Value, y: ?Value, strings: bool) !void {
    var text: std.Io.Writer.Allocating = .init(a);
    defer text.deinit();
    if (strings) try @import("display.zig").writeString(&text.writer, x) else try @import("runtime.zig").writeValue(&text.writer, x);
    if (y) |right| {
        try text.writer.writeAll("\n");
        try @import("runtime.zig").writeValue(&text.writer, right);
    }
    try text.writer.writeAll("\n");
    @import("console.zig").init();
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.Writer.init(.stdout(), std.Io.Threaded.global_single_threaded.io(), &buffer);
    try output.interface.writeAll(text.written());
    try output.interface.flush();
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

/// Extract contiguous runs of ASCII digits along the trailing axis, skipping empty rows.
pub fn ints(a: std.mem.Allocator, x: Value, _: Value) !Value {
    if (x.tuple != null) return error.InvalidInput;
    if (x.shape.len <= 1) return extractNumbers(a, x, false, true);
    const cell_width = x.shape[x.shape.len - 1];
    var cells: usize = 1;
    for (x.shape[0 .. x.shape.len - 1]) |dim| cells = try std.math.mul(usize, cells, dim);
    var numbers: std.ArrayList(f64) = .empty;
    defer numbers.deinit(a);
    var width: ?usize = null;
    var rows: usize = 0;
    var first_row: usize = 0;
    for (0..cells) |i| {
        const row = try extractNumbers(a, .{
            .data = x.data[i * cell_width ..][0..cell_width],
            .shape = &.{cell_width},
        }, false, true);
        defer a.free(row.data);
        defer a.free(row.shape);
        if (row.data.len == 0) continue;
        if (width) |expected| {
            if (row.data.len != expected) return @import("runtime.zig").shapeMismatchIndexed(@src().fn_name, &.{
                .{ .data = numbers.items[0..expected], .shape = &.{expected} }, row,
            }, &.{ first_row, i });
        } else {
            width = row.data.len;
            first_row = i;
        }
        try numbers.appendSlice(a, row.data);
        rows += 1;
    }
    const shape = if (rows == cells)
        try a.dupe(usize, x.shape)
    else
        try a.dupe(usize, &.{ rows, width orelse 0 });
    errdefer a.free(shape);
    shape[shape.len - 1] = width orelse 0;
    return .{ .data = try numbers.toOwnedSlice(a), .shape = shape };
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

fn extractNumbers(a: std.mem.Allocator, x: Value, matrix: bool, integers: bool) !Value {
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
                if (row_width != expected) return @import("runtime.zig").shapeMismatch(@src().fn_name, &.{ .{ .data = numbers.items[0..expected], .shape = &.{expected} }, .{ .data = numbers.items[row_start..], .shape = &.{row_width} } });
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
            return @import("runtime.zig").shapeMismatch(@src().fn_name, &.{ .{ .data = x.data[0..1] }, .{ .data = x.data[i..][0..1] } });
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

pub fn sq(a: std.mem.Allocator, x: Value, _: Value) !Value {
    return @import("uiua_builtins.zig").mul(a, x, x);
}

/// Split an array's rows at an integer index; negative indices count from the end.
fn splitRowsAt(a: std.mem.Allocator, x: Value, index: Value) !Value {
    if (x.tuple != null or x.shape.len == 0 or index.tuple != null or
        index.shape.len != 0 or index.data.len != 1) return error.InvalidInput;
    const row_count = index.data[0];
    if (!std.math.isFinite(row_count) or @trunc(row_count) != row_count) return error.InvalidInput;
    if (@abs(row_count) > @as(f64, @floatFromInt(x.shape[0]))) return @import("runtime.zig").shapeMismatch(@src().fn_name, &.{ x, index });
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
    const parts = try splitRowsAt(a, x, .{ .data = &.{1} });
    const values = try a.dupe(Value, parts.tuple.?);
    values[0].shape = values[0].shape[1..];
    return .{ .tuple = values };
}

/// Take rows from the front, or from the back for a negative count.
pub fn take(a: std.mem.Allocator, x: Value, row_count: Value) !Value {
    const parts = try splitRowsAt(a, x, row_count);
    return parts.tuple.?[if (row_count.data[0] < 0) @as(usize, 1) else 0];
}

/// Drop rows from the front, or from the back for a negative count.
pub fn drop(a: std.mem.Allocator, x: Value, row_count: Value) !Value {
    const parts = try splitRowsAt(a, x, row_count);
    return parts.tuple.?[if (row_count.data[0] < 0) @as(usize, 0) else 1];
}

/// Prepend a row y to the leading axis of array x.
pub fn prepend(a: std.mem.Allocator, x: Value, y: Value) !Value {
    if (x.tuple != null or y.tuple != null) return error.ExpectedArray;
    if (x.shape.len == 0 or !std.mem.eql(usize, x.shape[1..], y.shape)) return @import("runtime.zig").shapeMismatch(@src().fn_name, &.{ x, y });
    const shape = try a.dupe(usize, x.shape);
    shape[0] = try std.math.add(usize, shape[0], 1);
    const data = try a.alloc(f64, try std.math.add(usize, x.data.len, y.data.len));
    @memcpy(data[0..y.data.len], y.data);
    @memcpy(data[y.data.len..], x.data);
    return .{ .data = data, .shape = shape };
}

/// Construct a pair without requiring equally shaped values.
pub fn tuple(a: std.mem.Allocator, x: Value, y: Value) !Value {
    return .{ .tuple = try a.dupe(Value, &.{ x, y }) };
}

pub fn second(_: std.mem.Allocator, x: Value, _: Value) !Value {
    if (x.tuple) |items| {
        if (items.len < 2) return error.InvalidInput;
        return items[1];
    }
    if (x.shape.len == 0 or x.shape[0] < 2) return error.InvalidInput;
    const width = x.data.len / x.shape[0];
    return .{ .data = x.data[width..][0..width], .shape = x.shape[1..] };
}
