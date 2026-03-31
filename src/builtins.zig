const std = @import("std");
const types = @import("types.zig");
const Value = types.Value;

pub fn add(all: std.mem.Allocator, a: Value, b: Value) Value {
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
pub fn mul(all: std.mem.Allocator, a: Value, b: Value) Value {
    _ = a;
    _ = all;
    return b;
}
pub fn sq(all: std.mem.Allocator, a: Value) Value {
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

test "sq squares scalar values" {
    const result = sq(std.testing.allocator, .{ .scalar = .{ .value = -3, .is_char = false } });

    try std.testing.expectEqual(@as(types.Value.Tag, .scalar), result);
    try std.testing.expectEqual(@as(f64, 9), result.scalar.value);
    try std.testing.expect(!result.scalar.is_char);
}

test "add adds same-shape arrays elementwise" {
    const allocator = std.testing.allocator;
    const result = add(
        allocator,
        .{
            .array = .{
                .data = &.{ 1, 2, 3 },
                .shape = &.{3},
                .is_char = false,
            },
        },
        .{
            .array = .{
                .data = &.{ 4, 5, 6 },
                .shape = &.{3},
                .is_char = false,
            },
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

    const result = sq(allocator, input);
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
