const std = @import("std");
const Value = @import("runtime.zig").Value;
pub fn add(a: std.mem.Allocator, x: Value, y: Value) !Value {
    return arithmetic(a, x, y, .add);
}

pub fn mul(a: std.mem.Allocator, x: Value, y: Value) !Value {
    return arithmetic(a, x, y, .multiply);
}

pub fn sub(a: std.mem.Allocator, x: Value, y: Value) !Value {
    return arithmetic(a, x, y, .subtract);
}

pub fn not_eq(a: std.mem.Allocator, x: Value, y: Value) !Value {
    return arithmetic(a, x, y, .not_equal);
}

fn arithmetic(a: std.mem.Allocator, x: Value, y: Value, comptime op: enum { add, multiply, subtract, not_equal }) !Value {
    if (x.tuple != null or y.tuple != null) return error.InvalidInput;
    const n = @min(x.shape.len, y.shape.len);
    if (!std.mem.eql(usize, x.shape[0..n], y.shape[0..n])) return error.ShapeMismatch;
    const big = if (x.shape.len >= y.shape.len) x else y;
    const data = try a.alloc(f64, big.data.len);
    for (data, 0..) |*d, i| {
        const xi = if (x.shape.len == big.shape.len) i else i / (big.data.len / x.data.len);
        const yi = if (y.shape.len == big.shape.len) i else i / (big.data.len / y.data.len);
        d.* = switch (op) {
            .add => x.data[xi] + y.data[yi],
            .multiply => x.data[xi] * y.data[yi],
            .subtract => x.data[xi] - y.data[yi],
            .not_equal => @floatFromInt(@intFromBool(x.data[xi] != y.data[yi])),
        };
    }
    return .{ .data = data, .shape = try a.dupe(usize, big.shape) };
}
pub fn couple(a: std.mem.Allocator, x: Value, y: Value) !Value {
    if (x.tuple != null or y.tuple != null) return error.InvalidInput;
    if (!std.mem.eql(usize, x.shape, y.shape)) return error.ShapeMismatch;
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
    if (counts.data.len > source_shape.len) return error.ShapeMismatch;
    const shape = try a.dupe(usize, source_shape);
    const starts = try a.alloc(usize, shape.len);
    @memset(starts, 0);
    for (counts.data, 0..) |count, axis| {
        if (!std.math.isFinite(count) or @trunc(count) != count) return error.InvalidInput;
        if (@abs(count) > @as(f64, @floatFromInt(source_shape[axis]))) return error.ShapeMismatch;
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
