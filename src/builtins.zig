const std = @import("std");
const types = @import("types.zig");
const Value = types.Value;

pub fn add(all: std.mem.Allocator, a: Value, b: Value) Value {
    _ = all;
    switch (.{ a, b }) {
        .{ Value.scalar, Value.scalar } => {},
        else => {},
    }
    return b;
}
pub fn mul(all: std.mem.Allocator, a: Value, b: Value) Value {
    _ = a;
    _ = all;
    return b;
}
pub fn sq(all: std.mem.Allocator, a: Value) Value {
    _ = all;
    return a;
}
