//! Elementwise scalar operations that preserve array shape.

const std = @import("std");
const Value = @import("../runtime.zig").Value;

pub fn sq(a: std.mem.Allocator, x: Value, _: Value) !Value {
    return mul(a, x, x);
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

/// Nonzero values are true; boolean operations always return zero or one.
pub fn @"and"(a: std.mem.Allocator, x: Value, y: Value) !Value {
    return arithmetic(a, x, y, .boolean_and);
}

pub fn @"or"(a: std.mem.Allocator, x: Value, y: Value) !Value {
    return arithmetic(a, x, y, .boolean_or);
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

pub fn negate(a: std.mem.Allocator, x: Value, _: Value) !Value {
    return unary(a, x, .negate);
}

/// Uiua not: subtract each element from one, preserving the array's shape.
pub fn not(a: std.mem.Allocator, x: Value, _: Value) !Value {
    return unary(a, x, .not);
}

fn unary(a: std.mem.Allocator, x: Value, comptime op: enum { floor, abs, negate, not }) !Value {
    if (x.tuple != null) return error.InvalidInput;
    const data = try a.alloc(f64, x.data.len);
    for (x.data, data) |item, *output| output.* = switch (op) {
        .floor => @floor(item),
        .abs => @abs(item),
        .negate => -item,
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

pub fn min(a: std.mem.Allocator, x: Value, y: Value) !Value {
    return arithmetic(a, x, y, .minimum);
}

fn arithmetic(a: std.mem.Allocator, x: Value, y: Value, comptime op: enum { add, multiply, subtract, divide, modulo, equal, not_equal, less, greater, less_eq, greater_eq, maximum, minimum, boolean_and, boolean_or }) !Value {
    if (x.tuple != null or y.tuple != null) return error.InvalidInput;
    const n = @min(x.shape.len, y.shape.len);
    // Lower-rank arguments repeat over leading axes, matching trailing axes.
    if (!std.mem.eql(usize, x.shape[x.shape.len - n ..], y.shape[y.shape.len - n ..])) return @import("../runtime.zig").shapeMismatch(@src().fn_name, &.{ x, y });
    const big = if (x.shape.len >= y.shape.len) x else y;
    const data = try a.alloc(f64, big.data.len);
    for (data, 0..) |*d, i| {
        const xi = i % x.data.len;
        const yi = i % y.data.len;
        d.* = switch (op) {
            .boolean_and => @floatFromInt(@intFromBool(x.data[xi] != 0) & @intFromBool(y.data[yi] != 0)),
            .boolean_or => @floatFromInt(@intFromBool(x.data[xi] != 0) | @intFromBool(y.data[yi] != 0)),
            .add => x.data[xi] + y.data[yi],
            .multiply => x.data[xi] * y.data[yi],
            .maximum => @max(x.data[xi], y.data[yi]),
            .minimum => @min(x.data[xi], y.data[yi]),
            .subtract => x.data[xi] - y.data[yi],
            .divide => x.data[xi] / y.data[yi],
            .modulo => if (y.data[yi] == 0) std.math.nan(f64) else @mod(x.data[xi], y.data[yi]),
            .less => @floatFromInt(@intFromBool(x.data[xi] < y.data[yi])),
            .greater => @floatFromInt(@intFromBool(x.data[xi] > y.data[yi])),
            .less_eq => @floatFromInt(@intFromBool(x.data[xi] <= y.data[yi])),
            .greater_eq => @floatFromInt(@intFromBool(x.data[xi] >= y.data[yi])),
            .equal => @floatFromInt(@intFromBool(x.data[xi] == y.data[yi])),
            .not_equal => @floatFromInt(@intFromBool(x.data[xi] != y.data[yi])),
        };
    }
    return .{ .data = data, .shape = try a.dupe(usize, big.shape) };
}

pub fn less(a: std.mem.Allocator, x: Value, y: Value) !Value {
    return arithmetic(a, x, y, .less);
}

pub fn greater(a: std.mem.Allocator, x: Value, y: Value) !Value {
    return arithmetic(a, x, y, .greater);
}

pub fn less_eq(a: std.mem.Allocator, x: Value, y: Value) !Value {
    return arithmetic(a, x, y, .less_eq);
}

pub fn greater_eq(a: std.mem.Allocator, x: Value, y: Value) !Value {
    return arithmetic(a, x, y, .greater_eq);
}
