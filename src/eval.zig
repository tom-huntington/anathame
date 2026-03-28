const std = @import("std");
const types = @import("types.zig");
const Expr = types.Expr;
const Value = types.Value;

pub const Args = union(enum) {
    monad: [1]Value,
    dyad: [2]Value,
};

pub const EvalError = error{
    ArityMismatch,
    UnsupportedFunctionKind,
};

pub fn evalFunc(allocator: std.mem.Allocator, func: *const Expr.FuncExpr, args: Args) EvalError!Value {
    switch (func.type) {
        .builtin => |builtin| switch (builtin) {
            .monad => |f| {
                const monad_args = switch (args) {
                    .monad => |monad_args| monad_args,
                    .dyad => return error.ArityMismatch,
                };
                return f(allocator, monad_args[0]);
            },
            .dyad => |f| {
                const dyad_args = switch (args) {
                    .dyad => |dyad_args| dyad_args,
                    .monad => return error.ArityMismatch,
                };
                return f(allocator, dyad_args[0], dyad_args[1]);
            },
        },
        .scope => |scoped| return evalFunc(allocator, scoped, args),
        .userFn => |user_fn| return evalFunc(allocator, user_fn, args),
        .combinator => |com| {
            switch (com.op) {
                .B1 => {
                    const a = try evalFunc(allocator, com.left, args);
                    return evalFunc(allocator, com.right, .{ .monad = .{a} });
                },
                else => {
                    @panic("not implemented");
                },
            }
        },
        .partial_apply => return error.UnsupportedFunctionKind,
    }
}
