const std = @import("std");
const Value = @import("runtime.zig").Value;
pub fn mul(a: std.mem.Allocator, x: Value, y: Value) !Value {
    const n = @min(x.shape.len, y.shape.len);
    if (!std.mem.eql(usize, x.shape[0..n], y.shape[0..n])) return error.ShapeMismatch;
    const big = if (x.shape.len >= y.shape.len) x else y;
    const data = try a.alloc(f64, big.data.len);
    for (data, 0..) |*d, i| {
        const xi = if (x.shape.len == big.shape.len) i else i / (big.data.len / x.data.len);
        const yi = if (y.shape.len == big.shape.len) i else i / (big.data.len / y.data.len);
        d.* = x.data[xi] * y.data[yi];
    }
    return .{ .data = data, .shape = try a.dupe(usize, big.shape) };
}
pub fn couple(a: std.mem.Allocator, x: Value, y: Value) !Value {
    if (!std.mem.eql(usize, x.shape, y.shape)) return error.ShapeMismatch;
    const shape = try a.alloc(usize, x.shape.len + 1);
    shape[0] = 2;
    @memcpy(shape[1..], x.shape);
    const data = try a.alloc(f64, x.data.len + y.data.len);
    @memcpy(data[0..x.data.len], x.data);
    @memcpy(data[x.data.len..], y.data);
    return .{ .data = data, .shape = shape };
}
