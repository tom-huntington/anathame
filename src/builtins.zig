const std = @import("std");
const types = @import("types.zig");
const Expr = types.Expr;
const Value = types.Value;

pub fn add(all: std.mem.Allocator, args: *[2]Value) Value {
    const a = args[0];
    const b = args[1];
    switch (a) {
        .scalar => |as| {
            switch (b) {
                .scalar => |bs| {
                    const val = as.value + bs.value;
                    return .{ .scalar = .{ .value = val, .is_char = bs.is_char and as.is_char } };
                },
                .array => {},
            }
        },
        .array => |aa| {
            switch (b) {
                .array => |ba| {
                    if (!std.mem.eql(u32, aa.shape, ba.shape)) {
                        @panic("not implemented");
                    }

                    const data = all.alloc(f64, aa.data.len) catch @panic("out of memory");
                    const shape = all.dupe(u32, aa.shape) catch @panic("out of memory");

                    for (aa.data, ba.data, 0..) |lhs, rhs, i| {
                        data[i] = lhs + rhs;
                    }

                    return .{ .array = .{ .data = data, .shape = shape, .is_char = aa.is_char and ba.is_char } };
                },
                .scalar => {},
            }
        },
    }
    @panic("not implemented");
}
pub fn mul(all: std.mem.Allocator, args: *[2]Value) Value {
    const a = args[0];
    const b = args[1];
    _ = a;
    _ = all;
    return b;
}
pub fn sq(all: std.mem.Allocator, args: *[1]Value) Value {
    const a = args[0];
    switch (a) {
        .scalar => |scalar| {
            const val = scalar.value * scalar.value;
            return .{ .scalar = .{ .value = val, .is_char = false } };
        },
        .array => |array| {
            const data = all.alloc(f64, array.data.len) catch @panic("out of memory");
            const shape = all.dupe(u32, array.shape) catch @panic("out of memory");

            for (array.data, 0..) |item, i| {
                data[i] = item * item;
            }

            return .{ .array = .{ .data = data, .shape = shape, .is_char = false } };
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

pub fn strided(all: std.mem.Allocator, args: *[3]Value) Value {
    const array = switch (args[0]) {
        .array => |array| array,
        else => @panic("strided expects array as first argument"),
    };
    const inner_size = switch (args[1]) {
        .scalar => |scalar| expectNonNegativeInteger(scalar.value),
        else => @panic("strided expects scalar inner size"),
    };
    const stride = switch (args[2]) {
        .scalar => |scalar| expectNonNegativeInteger(scalar.value),
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

    const data = all.alloc(f64, outer_size * inner_size) catch @panic("out of memory");
    const shape = all.alloc(u32, 2) catch @panic("out of memory");
    shape[0] = @intCast(outer_size);
    shape[1] = @intCast(inner_size);

    start = 0;
    var out_index: usize = 0;
    while (start + inner_size <= array.data.len) : (start += step) {
        @memcpy(data[out_index .. out_index + inner_size], array.data[start .. start + inner_size]);
        out_index += inner_size;
    }

    return .{ .array = .{ .data = data, .shape = shape, .is_char = array.is_char } };
}
