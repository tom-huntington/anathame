const std = @import("std");
const types = @import("types.zig");
const ReservedBumpAllocator = @import("ReservedBumpAllocator").ReservedBumpAllocator; // ../vendor/ReservedBumpAllocator/root.zig
const Expr = types.Expr;
const Value = types.Value;

pub fn add(all: *ReservedBumpAllocator, result_dest: ?[]f64, args: *[2]Value) Value {
    const checkpoint = all.checkpoint();
    const av = args[0];
    const bv = args[1];
    if (std.meta.activeTag(av) == std.meta.activeTag(bv)) {
        switch (av) {
            .scalar => |a| {
                const res = a + bv.scalar;
                if (result_dest) |dest|
                    dest[0] = res;
                return .{ .scalar = res };
            },
            .array => |a| {
                const b = bv.array;
                if (!std.mem.eql(usize, a.shape, b.shape)) {
                    @panic("not implemented");
                }
                if (result_dest == null) {
                    if (if (a.status == .Exclusive) .{ a, b } else if (b.status == .Exclusive) .{ b, a } else null) |pair| {
                        const inplace, const arg = pair;

                        for (inplace.data, arg.data) |*inp, el| {
                            inp.* += el;
                        }
                        return inplace.Return(all, checkpoint);
                    }
                }

                const result = @import("array_helpers.zig").InitOutofplaceResult(all, result_dest, @import("array_helpers.zig").topmost_shape(a, b));
                for (a.data, b.data, result.data) |lhs, rhs, *d| {
                    d.* = lhs + rhs;
                }
                return result.Return(all, checkpoint);
            },
        }
    } else {
        const pair = switch (av) {
            .array => |a| .{ a, bv.scalar },
            .scalar => |a| .{ bv.array, a },
        };
        const arr, const val = pair;
        switch (arr.status) {
            .Exclusive => {
                for (arr.data) |*inp| {
                    inp.* += val;
                }
                return arr.Return(all, checkpoint);
            },
            .Shared => {
                const result = @import("array_helpers.zig").InitOutofplaceResult(all, result_dest, arr);
                for (arr.data, result.data) |el, *d| {
                    d.* = el + val;
                }
                return result.Return(all, checkpoint);
            },
        }
    }
    @panic("not implemented");
}

pub fn sq(all: *ReservedBumpAllocator, result_dest: ?[]f64, args: *[1]Value) Value {
    const checkpoint = all.checkpoint();
    const a = args[0];
    switch (a) {
        .scalar => |scalar| {
            return .{ .scalar = scalar * scalar };
        },
        .array => |array| {
            if (result_dest == null) {
                if (array.status == .Exclusive) {
                    for (array.data) |*inp| {
                        inp.* *= inp.*;
                    }
                    return array.Return(all, checkpoint);
                }
            }
            const result = @import("array_helpers.zig").InitOutofplaceResult(all, result_dest, array);

            for (array.data, result.data) |item, *dst| {
                dst.* = item * item;
            }

            return result.Return(all, checkpoint);
        },
    }
    @panic("not implemented");
}

fn expectNonNegativeInteger(value: f64) usize {
    if (!std.math.isFinite(value) or value < 0 or @floor(value) != value) {
        @panic("expected non-negative integer");
    }
    return @intFromFloat(value);
}

pub fn strided(all: *ReservedBumpAllocator, result_dest: ?[]f64, args: *[3]Value) Value {
    const checkpoint = all.checkpoint();
    _ = result_dest;
    const array = switch (args[0]) {
        .array => |array| array,
        else => @panic("strided expects array as first argument"),
    };
    const inner_size = switch (args[1]) {
        .scalar => |scalar| expectNonNegativeInteger(scalar),
        else => @panic("strided expects scalar inner size"),
    };
    const stride = switch (args[2]) {
        .scalar => |scalar| expectNonNegativeInteger(scalar),
        else => @panic("strided expects scalar stride"),
    };

    if (array.shape.len != 1) @panic("strided only supports rank-1 arrays");
    if (inner_size == 0) @panic("strided inner size must be greater than zero");

    const step = inner_size + stride - 1;
    if (step == 0) @panic("strided step must be greater than zero");

    var outer_size: usize = 0;
    var start: usize = 0;
    while (start + inner_size <= array.data.len) : (start += step) {
        outer_size += 1;
    }

    var result = types.Array.initWithShape(all, &.{ outer_size, inner_size });

    start = 0;
    var out_index: usize = 0;
    while (start + inner_size <= array.data.len) : (start += step) {
        @memcpy(result.data[out_index .. out_index + inner_size], array.data[start .. start + inner_size]);
        out_index += inner_size;
    }

    return result.Return(all, checkpoint);
}

pub fn not_eq(all: *ReservedBumpAllocator, result_dest: ?[]f64, args: *[2]Value) Value {
    const checkpoint = all.checkpoint();
    _ = result_dest;
    const rhs = switch (args[1]) {
        .scalar => |scalar| scalar,
        else => @panic("not_eq expects args[1] to be scalar"),
    };

    switch (args[0]) {
        .scalar => |lhs| {
            return .{ .scalar = if (lhs != rhs) 1 else 0 };
        },
        .array => |lhs| {
            var result = types.Array.initWithShape(all, lhs.shape);

            for (lhs.data, 0..) |item, i| {
                result.data[i] = if (item != rhs) 1 else 0;
            }

            return result.Return(all, checkpoint);
        },
    }
}

pub fn first(all: *ReservedBumpAllocator, result_dest: ?[]f64, args: *[1]Value) Value {
    _ = all;
    _ = result_dest;

    const array = switch (args[0]) {
        .array => |array| array,
        else => @panic("first expects an array"),
    };

    if (array.shape.len != 1) @panic("first only supports rank-1 arrays");
    if (array.data.len == 0) @panic("first requires a non-empty array");

    return .{ .scalar = array.data[0] };
}
