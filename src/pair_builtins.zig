const std = @import("std");
const types = @import("types.zig");
const ReservedBumpAllocator = @import("ReservedBumpAllocator").ReservedBumpAllocator;
const Value = types.Value;

fn expectNonNegativeInteger(value: f64) usize {
    if (!std.math.isFinite(value) or value < 0 or @floor(value) != value) {
        @panic("expected non-negative integer");
    }
    return @intFromFloat(value);
}

pub fn split_at(all: *ReservedBumpAllocator, args: *[2]Value) types.PairBuiltinResult {
    const array = switch (args[0]) {
        .array => |array| array,
        else => @panic("split_at expects array as first argument"),
    };
    const idx = switch (args[1]) {
        .scalar => |scalar| expectNonNegativeInteger(scalar),
        else => @panic("split_at expects scalar index"),
    };

    if (array.shape.len != 1) @panic("split_at only supports rank-1 arrays");
    if (idx > array.data.len) @panic("split_at index out of bounds");

    const left_shape = all.allocator().alloc(usize, 1) catch @panic("out of memory");
    const right_shape = all.allocator().alloc(usize, 1) catch @panic("out of memory");
    left_shape[0] = idx;
    right_shape[0] = array.data.len - idx;

    const left = types.Array{
        .data = array.data[0..idx],
        .ownership = .Shared,
        .shape = left_shape,
    };
    const right = types.Array{
        .data = array.data[idx..],
        .ownership = .Shared,
        .shape = right_shape,
    };

    return .{
        .{ .array = left },
        .{ .array = right },
    };
}
