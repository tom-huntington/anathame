const std = @import("std");
const Value = @import("runtime.zig").Value;
pub fn mul(a: std.mem.Allocator, x: Value, y: Value) !Value {
    return arithmetic(a, x, y, .multiply);
}

pub fn sub(a: std.mem.Allocator, x: Value, y: Value) !Value {
    return arithmetic(a, x, y, .subtract);
}

pub fn not_eq(a: std.mem.Allocator, x: Value, y: Value) !Value {
    return arithmetic(a, x, y, .not_equal);
}

fn arithmetic(a: std.mem.Allocator, x: Value, y: Value, comptime op: enum { multiply, subtract, not_equal }) !Value {
    if (x.tuple != null or y.tuple != null) return error.InvalidInput;
    const n = @min(x.shape.len, y.shape.len);
    if (!std.mem.eql(usize, x.shape[0..n], y.shape[0..n])) return error.ShapeMismatch;
    const big = if (x.shape.len >= y.shape.len) x else y;
    const data = try a.alloc(f64, big.data.len);
    for (data, 0..) |*d, i| {
        const xi = if (x.shape.len == big.shape.len) i else i / (big.data.len / x.data.len);
        const yi = if (y.shape.len == big.shape.len) i else i / (big.data.len / y.data.len);
        d.* = switch (op) {
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

/// Stack positive marker runs; unequal runs return (rows, cumulative row offsets).
pub fn partition(a: std.mem.Allocator, x: Value, markers: Value) !Value {
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
    var i: usize = 0;
    while (i < markers.data.len) {
        const start = i;
        const marker = markers.data[i];
        i += 1;
        while (i < markers.data.len and markers.data[i] == marker) : (i += 1) {}
        if (marker <= 0) continue;
        if (groups == 0) group_len = i - start else if (group_len != i - start) jagged = true;
        groups += 1;
        try data.appendSlice(a, x.data[start * row_len .. i * row_len]);
        try offsets.append(a, offsets.items[offsets.items.len - 1] + @as(f64, @floatFromInt(i - start)));
    }
    // Uiua returns an empty list when there are no positive groups.
    if (groups == 0) return .{ .data = &.{}, .shape = try a.dupe(usize, &.{0}) };
    if (jagged) {
        const shape = try a.dupe(usize, x.shape);
        shape[0] = @intFromFloat(offsets.items[offsets.items.len - 1]);
        const items = try a.alloc(Value, 2);
        items[0] = .{ .data = try data.toOwnedSlice(a), .shape = shape };
        items[1] = .{ .data = try offsets.toOwnedSlice(a), .shape = try a.dupe(usize, &.{groups + 1}) };
        return .{ .tuple = items };
    }
    const shape = try a.alloc(usize, x.shape.len + 1);
    shape[0] = groups;
    shape[1] = group_len;
    @memcpy(shape[2..], x.shape[1..]);
    return .{ .data = try data.toOwnedSlice(a), .shape = shape };
}
