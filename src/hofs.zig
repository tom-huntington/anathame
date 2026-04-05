const std = @import("std");
const types = @import("types.zig");
const ReservedBufferAllocator = @import("ReservedBumpAllocator").ReservedBumpAllocator;
const Expr = types.Expr;
const Value = types.Value;

pub fn isHofName(name: []const u8) bool {
    inline for (@typeInfo(@This()).@"struct".decls) |decl| {
        const member = @field(@This(), decl.name);
        if (isHofFunction(member) and std.mem.eql(u8, name, decl.name)) {
            return true;
        }
    }
    return false;
}

pub fn reduce(all: *ReservedBufferAllocator, result_dest: ?[]f64, args: *[1]Value, fn_arg: Expr.FuncExpr) Value {
    _ = result_dest;
    const array = switch (args[0]) {
        .array => |array| array,
        else => @panic("reduce expects an array"),
    };

    if (array.shape().len != 1) @panic("reduce only supports rank-1 arrays");
    if (array.data.len == 0) @panic("reduce requires a non-empty array");

    var acc: Value = .{
        .scalar = array.data[0],
    };

    for (array.data[1..]) |item| {
        acc = @import("eval.zig").evalFunc(all, &fn_arg, &.{
            acc,
            .{ .scalar = item },
        }) catch @panic("reduce function evaluation failed");
    }

    return acc;
}

pub fn partition(all: *ReservedBufferAllocator, result_dest: ?[]f64, args: *[2]Value, fn_arg: Expr.FuncExpr) Value {
    const array = switch (args[0]) {
        .array => |arr| arr,
        else => @panic("partition expects an array"),
    };
    const mask = switch (args[1]) {
        .array => |arr| arr,
        else => @panic("partition expects an array"),
    };

    if (array.shape().len != 1) @panic("not implemented");
    if (!std.mem.eql(usize, array.shape(), mask.shape())) @panic("not implemented");

    _ = all;
    _ = result_dest;
    _ = fn_arg;
    //@panic("not implemented");
    return args[0];
}

fn isHofFunction(comptime member: anytype) bool {
    const member_info = @typeInfo(@TypeOf(member));
    if (member_info != .@"fn") return false;

    const params = member_info.@"fn".params;
    if (params.len != 4) return false;
    if ((params[1].type orelse return false) != ?[]f64) return false;
    if ((params[3].type orelse return false) != Expr.FuncExpr) return false;

    const args_type = params[2].type orelse return false;
    const args_info = @typeInfo(args_type);
    if (args_info != .pointer) return false;
    if (args_info.pointer.size != .one) return false;

    const child_info = @typeInfo(args_info.pointer.child);
    if (child_info != .array) return false;
    return child_info.array.child == Value;
}
