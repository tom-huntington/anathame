const std = @import("std");
const types = @import("types.zig");
const ReservedBumpAllocator = @import("ReservedBumpAllocator").ReservedBumpAllocator; // ../vendor/ReservedBumpAllocator/root.zig
const Expr = types.Expr;
const Value = types.Value;

pub fn add(all: *ReservedBumpAllocator, result_dest: ?[]f64, args: *[2]Value) Value {
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
                    if (if (a.ownership == .Exclusive) .{ a, b } else if (b.ownership == .Exclusive) .{ b, a } else null) |pair| {
                        const inplace, const arg = pair;

                        for (inplace.data, arg.data) |*inp, el| {
                            inp.* += el;
                        }
                        return .{ .array = inplace };
                    }
                }

                const result = @import("array_helpers.zig").InitOutofplaceResult(all, result_dest, @import("array_helpers.zig").topmost_shape(a, b));
                for (a.data, b.data, result.data) |lhs, rhs, *d| {
                    d.* = lhs + rhs;
                }
                return .{ .array = result };
            },
        }
    } else {
        const pair = switch (av) {
            .array => |a| .{ a, bv.scalar },
            .scalar => |a| .{ bv.array, a },
        };
        const arr, const val = pair;
        switch (arr.ownership) {
            .Exclusive => {
                for (arr.data) |*inp| {
                    inp.* += val;
                }
                return .{ .array = arr };
            },
            .Shared => {
                const result = @import("array_helpers.zig").InitOutofplaceResult(all, result_dest, arr);
                for (arr.data, result.data) |el, *d| {
                    d.* = el + val;
                }
                return .{ .array = result };
            },
        }
    }
    @panic("not implemented");
}

pub fn mul(all: *ReservedBumpAllocator, result_dest: ?[]f64, args: *[2]Value) Value {
    const av = args[0];
    const bv = args[1];
    if (std.meta.activeTag(av) == std.meta.activeTag(bv)) {
        switch (av) {
            .scalar => |a| {
                const res = a * bv.scalar;
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
                    if (if (a.ownership == .Exclusive) .{ a, b } else if (b.ownership == .Exclusive) .{ b, a } else null) |pair| {
                        const inplace, const arg = pair;

                        for (inplace.data, arg.data) |*inp, el| {
                            inp.* *= el;
                        }
                        return .{ .array = inplace };
                    }
                }

                const result = @import("array_helpers.zig").InitOutofplaceResult(all, result_dest, @import("array_helpers.zig").topmost_shape(a, b));
                for (a.data, b.data, result.data) |lhs, rhs, *d| {
                    d.* = lhs * rhs;
                }
                return .{ .array = result };
            },
        }
    } else {
        const pair = switch (av) {
            .array => |a| .{ a, bv.scalar },
            .scalar => |a| .{ bv.array, a },
        };
        const arr, const val = pair;
        switch (arr.ownership) {
            .Exclusive => {
                for (arr.data) |*inp| {
                    inp.* *= val;
                }
                return .{ .array = arr };
            },
            .Shared => {
                const result = @import("array_helpers.zig").InitOutofplaceResult(all, result_dest, arr);
                for (arr.data, result.data) |el, *d| {
                    d.* = el * val;
                }
                return .{ .array = result };
            },
        }
    }
    @panic("not implemented");
}

pub fn parse(all: *ReservedBumpAllocator, result_dest: ?[]f64, args: *[1]Value) Value {
    const array = switch (args[0]) {
        .array => |array| array,
        else => @panic("parse expects an array"),
    };

    var bytes = all.allocator().alloc(u8, array.data.len * 4) catch @panic("out of memory");
    var len: usize = 0;
    for (array.data) |value| {
        if (!std.math.isFinite(value) or value < 0 or @floor(value) != value) {
            @panic("parse expects integer unicode values");
        }

        const codepoint: u21 = std.math.cast(u21, @as(u64, @intFromFloat(value))) orelse {
            @panic("parse expects valid unicode values");
        };
        if (!std.unicode.utf8ValidCodepoint(codepoint)) {
            @panic("parse expects valid unicode values");
        }

        len += std.unicode.utf8Encode(codepoint, bytes[len..]) catch {
            @panic("parse expects valid unicode values");
        };
    }

    const res = std.fmt.parseFloat(f64, bytes[0..len]) catch {
        @panic("parse expects a number");
    };
    if (result_dest) |dest|
        dest[0] = res;
    return .{ .scalar = res };
}

pub fn sq(all: *ReservedBumpAllocator, result_dest: ?[]f64, args: *[1]Value) Value {
    const a = args[0];
    switch (a) {
        .scalar => |scalar| {
            return .{ .scalar = scalar * scalar };
        },
        .array => |array| {
            if (result_dest == null) {
                if (array.ownership == .Exclusive) {
                    for (array.data) |*inp| {
                        inp.* *= inp.*;
                    }
                    return .{ .array = array };
                }
            }
            const result = @import("array_helpers.zig").InitOutofplaceResult(all, result_dest, array);

            for (array.data, result.data) |item, *dst| {
                dst.* = item * item;
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

pub fn strided(all: *ReservedBumpAllocator, result_dest: ?[]f64, args: *[3]Value) Value {
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

    const result_len = outer_size * inner_size;
    const result_shape = all.allocator().alloc(usize, 2) catch @panic("out of memory");
    result_shape[0] = outer_size;
    result_shape[1] = inner_size;

    var result = if (result_dest) |dest|
        types.Array{ .data = dest[0..result_len], .ownership = .Shared, .shape = result_shape }
    else if (array.ownership == .Exclusive and step >= inner_size)
        types.Array{ .data = array.data[0..result_len], .ownership = .Exclusive, .shape = result_shape }
    else
        types.Array.initWithShape(all, result_shape);

    start = 0;
    var out_index: usize = 0;
    while (start + inner_size <= array.data.len) : (start += step) {
        std.mem.copyForwards(f64, result.data[out_index .. out_index + inner_size], array.data[start .. start + inner_size]);
        out_index += inner_size;
    }

    return .{ .array = result };
}

pub fn not_eq(all: *ReservedBumpAllocator, result_dest: ?[]f64, args: *[2]Value) Value {
    const rhs = switch (args[1]) {
        .scalar => |scalar| scalar,
        else => @panic("not_eq expects args[1] to be scalar"),
    };

    switch (args[0]) {
        .scalar => |lhs| {
            const res: f64 = if (lhs != rhs) 1.0 else 0.0;
            if (result_dest) |dest|
                dest[0] = res;
            return .{ .scalar = res };
        },
        .array => |lhs| {
            if (result_dest == null and lhs.ownership == .Exclusive) {
                for (lhs.data) |*item| {
                    item.* = if (item.* != rhs) 1.0 else 0.0;
                }
                return .{ .array = lhs };
            }

            const result = @import("array_helpers.zig").InitOutofplaceResult(all, result_dest, lhs);

            for (lhs.data, result.data) |item, *dst| {
                dst.* = if (item != rhs) 1.0 else 0.0;
            }

            return .{ .array = result };
        },
    }
}

pub fn first(all: *ReservedBumpAllocator, result_dest: ?[]f64, args: *[1]Value) Value {
    _ = all;

    const array = switch (args[0]) {
        .array => |array| array,
        else => @panic("first expects an array"),
    };

    if (array.shape.len != 1) @panic("first only supports rank-1 arrays");
    if (array.data.len == 0) @panic("first requires a non-empty array");

    const result = array.data[0];
    if (result_dest) |dst| dst[0] = result;
    return .{ .scalar = result };
}

pub fn prepend(all: *ReservedBumpAllocator, result_dest: ?[]f64, args: *[2]Value) Value {
    const array = switch (args[0]) {
        .array => |array| array,
        else => @panic("prepend expects array as first argument"),
    };
    const value = switch (args[1]) {
        .scalar => |scalar| scalar,
        else => @panic("prepend expects scalar as second argument"),
    };

    if (array.shape.len != 1) @panic("prepend only supports rank-1 arrays");

    const result_len = array.data.len + 1;
    const result_shape = all.allocator().alloc(usize, 1) catch @panic("out of memory");
    result_shape[0] = result_len;

    const result_data = if (result_dest) |dest| blk: {
        if (dest.len < result_len) @panic("prepend result destination too small");
        break :blk dest[0..result_len];
    } else all.allocator().alloc(f64, result_len) catch @panic("out of memory");

    result_data[0] = value;
    @memcpy(result_data[1..], array.data);

    return .{ .array = .{
        .data = result_data,
        .ownership = if (result_dest == null) .Exclusive else .Shared,
        .shape = result_shape,
    } };
}

test "mul multiplies scalars and arrays" {
    var all = try ReservedBumpAllocator.init(1024 * 1024);
    defer all.deinit();

    var scalar_args = [_]Value{ .{ .scalar = 6 }, .{ .scalar = 7 } };
    try std.testing.expectEqual(@as(f64, 42), mul(&all, null, &scalar_args).scalar);

    var shape = [_]usize{2};
    var data = [_]f64{ 3, 4 };
    var array_args = [_]Value{
        .{ .array = .{ .data = &data, .ownership = .Shared, .shape = &shape } },
        .{ .scalar = 2 },
    };

    const result = mul(&all, null, &array_args).array;
    try std.testing.expectEqualSlices(f64, &.{ 6, 8 }, result.data);
    try std.testing.expectEqualSlices(usize, &shape, result.shape);
}

test "parse converts unicode value arrays to numbers" {
    var all = try ReservedBumpAllocator.init(1024 * 1024);
    defer all.deinit();

    var shape = [_]usize{5};
    var data = [_]f64{ '-', '1', '2', '.', '5' };
    var args = [_]Value{.{ .array = .{ .data = &data, .ownership = .Shared, .shape = &shape } }};

    var dest = [_]f64{0};
    const result = parse(&all, dest[0..], &args);
    try std.testing.expectEqual(@as(f64, -12.5), result.scalar);
    try std.testing.expectEqual(@as(f64, -12.5), dest[0]);
}

test "prepend adds a scalar to the front of a rank-1 array" {
    var all = try ReservedBumpAllocator.init(1024 * 1024);
    defer all.deinit();

    var shape = [_]usize{3};
    var data = [_]f64{ 2, 3, 4 };
    var args = [_]Value{
        .{ .array = .{ .data = &data, .ownership = .Shared, .shape = &shape } },
        .{ .scalar = 1 },
    };

    const result = prepend(&all, null, &args).array;
    try std.testing.expectEqualSlices(f64, &.{ 1, 2, 3, 4 }, result.data);
    try std.testing.expectEqualSlices(usize, &.{4}, result.shape);
    try std.testing.expectEqual(types.Ownership.Exclusive, result.ownership);
}
