const std = @import("std");
const types = @import("types.zig");
const Expr = types.Expr;
const Value = types.Value;

pub const Symbol = struct {
    lexeme: []const u8,
    name: []const u8,
};

pub const symbols = [_]Symbol{
    .{ .lexeme = "/", .name = "reduce" },
};

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
