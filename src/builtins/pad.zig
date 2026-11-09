const std = @import("std");
const Value = @import("../runtime.zig").Value;

/// Extend the leading dimension to at least size, filling new cells with fill.
pub fn pad(a: std.mem.Allocator, x: Value, size: Value, fill: Value) !Value {
    if (x.tuple != null or size.tuple != null or fill.tuple != null) return error.ExpectedArray;
    if (x.shape.len == 0 or size.shape.len != 0 or size.data.len != 1 or
        fill.shape.len != 0 or fill.data.len != 1) return error.InvalidInput;
    const number = size.data[0];
    if (!std.math.isFinite(number) or number < 0 or @trunc(number) != number or
        number >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return error.InvalidInput;
    const length: usize = @intFromFloat(number);
    if (length <= x.shape[0]) return x;
    var row_size: usize = 1;
    for (x.shape[1..]) |dimension| row_size = try std.math.mul(usize, row_size, dimension);
    const shape = try a.dupe(usize, x.shape);
    shape[0] = length;
    const data = try a.alloc(f64, try std.math.mul(usize, length, row_size));
    @memcpy(data[0..x.data.len], x.data);
    @memset(data[x.data.len..], fill.data[0]);
    return .{ .data = data, .shape = shape };
}
