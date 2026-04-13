const std = @import("std");
const types = @import("types.zig");
const ReservedBumpAllocator = @import("ReservedBumpAllocator").ReservedBumpAllocator;
const Value = types.Value;

fn expectInteger(value: f64) isize {
    if (!std.math.isFinite(value) or @floor(value) != value) {
        @panic("expected integer");
    }
    return @intFromFloat(value);
}

fn splitIndex(len: usize, idx: isize) usize {
    if (idx >= 0) {
        const positive_idx: usize = @intCast(idx);
        if (positive_idx > len) @panic("split_at index out of bounds");
        return positive_idx;
    }

    const from_end: usize = @intCast(-idx);
    if (from_end > len) @panic("split_at index out of bounds");
    return len - from_end;
}

fn sliceValue(all: *ReservedBumpAllocator, data: []f64) Value {
    if (data.len == 1) return .{ .scalar = data[0] };

    const shape = all.allocator().alloc(usize, 1) catch @panic("out of memory");
    shape[0] = data.len;
    return .{ .array = .{
        .data = data,
        .ownership = .Shared,
        .shape = shape,
    } };
}

pub fn split_at(all: *ReservedBumpAllocator, args: *[2]Value) types.PairBuiltinResult {
    const array = switch (args[0]) {
        .array => |array| array,
        else => @panic("split_at expects array as first argument"),
    };
    const raw_idx = switch (args[1]) {
        .scalar => |scalar| expectInteger(scalar),
        else => @panic("split_at expects scalar index"),
    };

    if (array.shape.len != 1) @panic("split_at only supports rank-1 arrays");
    const idx = splitIndex(array.data.len, raw_idx);

    return .{
        sliceValue(all, array.data[0..idx]),
        sliceValue(all, array.data[idx..]),
    };
}
