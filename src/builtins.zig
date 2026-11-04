const std = @import("std");
const Value = @import("runtime.zig").Value;

pub fn sq(a: std.mem.Allocator, x: Value, _: Value) !Value {
    return @import("uiua_builtins.zig").mul(a, x, x);
}

/// Split an array's rows at an integer index; negative indices count from the end.
pub fn split_at(a: std.mem.Allocator, x: Value, index: Value) !Value {
    if (x.tuple != null or x.shape.len == 0 or index.tuple != null or
        index.shape.len != 0 or index.data.len != 1) return error.InvalidInput;
    const count = index.data[0];
    if (!std.math.isFinite(count) or @trunc(count) != count) return error.InvalidInput;
    if (@abs(count) > @as(f64, @floatFromInt(x.shape[0]))) return error.ShapeMismatch;
    const amount: usize = @intFromFloat(@abs(count));
    const split = if (count < 0) x.shape[0] - amount else amount;
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
