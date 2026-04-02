const std = @import("std");
const types = @import("types.zig");
const Expr = types.Expr;
const Value = types.Value;

pub fn reduce(all: std.mem.Allocator, args: *[1]Value, fn_arg: Expr.FuncExpr) Value {
    const array = switch (args[0]) {
        .array => |array| array,
        else => @panic("reduce expects an array"),
    };

    if (array.shape.len != 1) @panic("reduce only supports rank-1 arrays");
    if (array.data.len == 0) @panic("reduce requires a non-empty array");

    var acc: Value = .{
        .scalar = .{
            .value = array.data[0],
            .is_char = array.is_char,
        },
    };

    for (array.data[1..]) |item| {
        acc = @import("eval.zig").evalFunc(all, &fn_arg, &.{
            acc,
            .{ .scalar = .{ .value = item, .is_char = array.is_char } },
        }) catch @panic("reduce function evaluation failed");
    }

    return acc;
}

pub fn partition(all: std.mem.Allocator, args: *[1]Value, fn_arg: Expr.FuncExpr) Value {
    const mask = switch (args[0]) {
        .array => |array| array,
        else => @panic("partition expects an array"),
    };

    if (mask.shape.len != 1) @panic("partition only supports rank-1 arrays");

    var results: std.ArrayList(Value) = .empty;
    defer results.deinit(all);

    var start: usize = 0;
    while (start < mask.data.len) {
        while (start < mask.data.len and mask.data[start] == 0) : (start += 1) {}
        if (start >= mask.data.len) break;

        var end = start + 1;
        while (end < mask.data.len and mask.data[end] != 0) : (end += 1) {}

        var group_shape = [_]u32{@intCast(end - start)};
        const group = Value{
            .array = .{
                .data = mask.data[start..end],
                .shape = group_shape[0..],
                .is_char = mask.is_char,
            },
        };

        const result = @import("eval.zig").evalFunc(all, &fn_arg, &.{group}) catch {
            @panic("partition function evaluation failed");
        };
        results.append(all, result) catch @panic("out of memory");
        start = end;
    }

    if (results.items.len == 0) {
        const data = all.alloc(f64, 0) catch @panic("out of memory");
        const shape = all.alloc(u32, 1) catch @panic("out of memory");
        shape[0] = 0;
        return .{ .array = .{ .data = data, .shape = shape, .is_char = false } };
    }

    return materializeHomogeneousResults(all, results.items);
}

fn materializeHomogeneousResults(all: std.mem.Allocator, items: []const Value) Value {
    const first_shape = switch (items[0]) {
        .scalar => &[_]u32{},
        .array => |array| array.shape,
    };
    const elem_len = switch (items[0]) {
        .scalar => @as(usize, 1),
        .array => |array| array.data.len,
    };

    var is_char = switch (items[0]) {
        .scalar => |scalar| scalar.is_char,
        .array => |array| array.is_char,
    };

    for (items[1..]) |item| {
        switch (item) {
            .scalar => |scalar| {
                if (first_shape.len != 0) @panic("partition function returned non-homogeneous shapes");
                is_char = is_char and scalar.is_char;
            },
            .array => |array| {
                if (!std.mem.eql(u32, first_shape, array.shape)) {
                    @panic("partition function returned non-homogeneous shapes");
                }
                if (array.data.len != elem_len) {
                    @panic("partition function returned non-homogeneous shapes");
                }
                is_char = is_char and array.is_char;
            },
        }
    }

    const data = all.alloc(f64, items.len * elem_len) catch @panic("out of memory");
    const shape = all.alloc(u32, first_shape.len + 1) catch @panic("out of memory");
    shape[0] = @intCast(items.len);
    @memcpy(shape[1..], first_shape);

    var data_index: usize = 0;
    for (items) |item| {
        switch (item) {
            .scalar => |scalar| {
                data[data_index] = scalar.value;
                data_index += 1;
            },
            .array => |array| {
                @memcpy(data[data_index .. data_index + array.data.len], array.data);
                data_index += array.data.len;
            },
        }
    }

    return .{ .array = .{ .data = data, .shape = shape, .is_char = is_char } };
}
