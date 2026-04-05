const std = @import("std");
const types = @import("types.zig");
const ReservedBufferAllocator = @import("ReservedBumpAllocator").ReservedBumpAllocator;
const Expr = types.Expr;
const Value = types.Value;

pub fn add(all: *ReservedBufferAllocator, result_dest: ?[]f64, args: *[2]Value) Value {
    _ = result_dest;
    const a = args[0];
    const b = args[1];
    switch (a) {
        .scalar => |as| {
            switch (b) {
                .scalar => |bs| {
                    return .{ .scalar = as + bs };
                },
                .array => {},
            }
        },
        .array => |aa| {
            switch (b) {
                .array => |ba| {
                    if (!std.mem.eql(usize, aa.shape(), ba.shape())) {
                        @panic("not implemented");
                    }

                    var result = types.Array.init(all, aa.shape());

                    for (aa.data, ba.data, 0..) |lhs, rhs, i| {
                        result.data[i] = lhs + rhs;
                    }

                    return .{ .array = result };
                },
                .scalar => {},
            }
        },
    }
    @panic("not implemented");
}
pub fn mul(all: *ReservedBufferAllocator, result_dest: ?[]f64, args: *[2]Value) Value {
    const a = args[0];
    const b = args[1];
    _ = a;
    _ = all;
    _ = result_dest;
    return b;
}
pub fn sq(all: *ReservedBufferAllocator, result_dest: ?[]f64, args: *[1]Value) Value {
    _ = result_dest;
    const a = args[0];
    switch (a) {
        .scalar => |scalar| {
            return .{ .scalar = scalar * scalar };
        },
        .array => |array| {
            var result = types.Array.init(all, array.shape());

            for (array.data, 0..) |item, i| {
                result.data[i] = item * item;
            }

            return .{ .array = result };
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

pub fn strided(all: *ReservedBufferAllocator, result_dest: ?[]f64, args: *[3]Value) Value {
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

    if (array.shape().len != 1) @panic("strided only supports rank-1 arrays");
    if (inner_size == 0) @panic("strided inner size must be greater than zero");

    const step = inner_size + stride - 1;
    if (step == 0) @panic("strided step must be greater than zero");

    var outer_size: usize = 0;
    var start: usize = 0;
    while (start + inner_size <= array.data.len) : (start += step) {
        outer_size += 1;
    }

    var result = types.Array.init(all, &.{ outer_size, inner_size });

    start = 0;
    var out_index: usize = 0;
    while (start + inner_size <= array.data.len) : (start += step) {
        @memcpy(result.data[out_index .. out_index + inner_size], array.data[start .. start + inner_size]);
        out_index += inner_size;
    }

    return .{ .array = result };
}

pub fn not_eq(all: *ReservedBufferAllocator, result_dest: ?[]f64, args: *[2]Value) Value {
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
            var result = types.Array.init(all, lhs.shape());

            for (lhs.data, 0..) |item, i| {
                result.data[i] = if (item != rhs) 1 else 0;
            }

            return .{ .array = result };
        },
    }
}

pub fn first(all: *ReservedBufferAllocator, result_dest: ?[]f64, args: *[1]Value) Value {
    _ = all;
    _ = result_dest;

    const array = switch (args[0]) {
        .array => |array| array,
        else => @panic("first expects an array"),
    };

    if (array.shape().len != 1) @panic("first only supports rank-1 arrays");
    if (array.data.len == 0) @panic("first requires a non-empty array");

    return .{ .scalar = array.data[0] };
}
