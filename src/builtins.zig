const std = @import("std");
const types = @import("types.zig");
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
                else => {},
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
                else => {},
            }
        },
        else => {},
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
        else => {},
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

test "sq squares scalar values" {
    const result = sq(std.testing.allocator, &.{
        .{ .scalar = .{ .value = -3, .is_char = false } },
    });

    try std.testing.expectEqual(@as(types.Value.Tag, .scalar), result);
    try std.testing.expectEqual(@as(f64, 9), result.scalar.value);
    try std.testing.expect(!result.scalar.is_char);
}

test "add adds same-shape arrays elementwise" {
    const allocator = std.testing.allocator;
    const result = add(
        allocator,
        &.{
            .{ .array = .{
                .data = &.{ 1, 2, 3 },
                .shape = &.{3},
                .is_char = false,
            } },
            .{ .array = .{
                .data = &.{ 4, 5, 6 },
                .shape = &.{3},
                .is_char = false,
            } },
        },
    );
    defer switch (result) {
        .array => |array| {
            allocator.free(array.data);
            allocator.free(array.shape);
        },
        else => {},
    };

    try std.testing.expectEqual(@as(types.Value.Tag, .array), result);
    try std.testing.expectEqualSlices(f64, &.{ 5, 7, 9 }, result.array.data);
    try std.testing.expectEqualSlices(u32, &.{3}, result.array.shape);
    try std.testing.expect(!result.array.is_char);
}

test "sq squares arrays elementwise" {
    const allocator = std.testing.allocator;
    const input = Value{
        .array = .{
            .data = &.{ -2, 3, 4 },
            .shape = &.{3},
            .is_char = false,
        },
    };

    const result = sq(allocator, &.{input});
    defer switch (result) {
        .array => |array| {
            allocator.free(array.data);
            allocator.free(array.shape);
        },
        else => {},
    };

    try std.testing.expectEqual(@as(types.Value.Tag, .array), result);
    try std.testing.expectEqualSlices(f64, &.{ 4, 9, 16 }, result.array.data);
    try std.testing.expectEqualSlices(u32, &.{3}, result.array.shape);
    try std.testing.expect(!result.array.is_char);
}

test "strided chunks a rank-1 array using the requested inner size and stride" {
    const allocator = std.testing.allocator;
    const result = strided(
        allocator,
        &.{
            .{ .array = .{
                .data = &.{ 1, 2, 3, 4, 5, 6, 7, 8 },
                .shape = &.{8},
                .is_char = false,
            } },
            .{ .scalar = .{ .value = 2, .is_char = false } },
            .{ .scalar = .{ .value = 2, .is_char = false } },
        },
    );
    defer switch (result) {
        .array => |array| {
            allocator.free(array.data);
            allocator.free(array.shape);
        },
        else => {},
    };

    try std.testing.expectEqual(@as(types.Value.Tag, .array), result);
    try std.testing.expectEqualSlices(f64, &.{ 1, 2, 4, 5, 7, 8 }, result.array.data);
    try std.testing.expectEqualSlices(u32, &.{ 3, 2 }, result.array.shape);
    try std.testing.expect(!result.array.is_char);
}
