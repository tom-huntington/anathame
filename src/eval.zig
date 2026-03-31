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
    UnsupportedValueKind,
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
                .B1, .B => {
                    const a = try evalFunc(allocator, com.left, args);
                    return evalFunc(allocator, com.right, .{ .monad = .{a} });
                },
                else => {
                    @panic("not implemented");
                },
            }
        },
        .partial_apply => |partial| {
            const right = try evalValueExpr(allocator, partial.right);
            return applyRightArg(allocator, partial.left, args, right);
        },
        .right_partial_apply => |partial| {
            const right = try evalRightFunc(allocator, partial.right, args);
            return applyRightArg(allocator, partial.left, args, right);
        },
    }
}

fn evalExpr(allocator: std.mem.Allocator, expr: *const Expr) EvalError!Value {
    return switch (expr.*) {
        .func => return error.UnsupportedValueKind,
        .value => |*value_expr| evalValueExpr(allocator, value_expr),
    };
}

fn evalValueExpr(allocator: std.mem.Allocator, expr: *const Expr.ValueExpr) EvalError!Value {
    return switch (expr.*) {
        .literal => |literal| literal,
        .strand => return error.UnsupportedValueKind,
        .apply => |apply| {
            const func = switch (apply.func.*) {
                .func => |*func| func,
                .value => return error.UnsupportedValueKind,
            };
            return evalFunc(allocator, func, try evalArgs(allocator, apply.arg));
        },
    };
}

fn evalArgs(allocator: std.mem.Allocator, expr: *const Expr) EvalError!Args {
    return switch (expr.*) {
        .func => return error.UnsupportedValueKind,
        .value => |value_expr| switch (value_expr) {
            .literal, .apply => .{ .monad = .{try evalExpr(allocator, expr)} },
            .strand => |strand| .{
                .dyad = .{
                    try evalExpr(allocator, strand.left),
                    try evalExpr(allocator, strand.right),
                },
            },
        },
    };
}

fn evalRightFunc(allocator: std.mem.Allocator, func: *const Expr.FuncExpr, args: Args) EvalError!Value {
    return switch (args) {
        .monad => |monad_args| evalFunc(allocator, func, .{ .monad = monad_args }),
        .dyad => |dyad_args| switch (func.arity) {
            .dyad => evalFunc(allocator, func, .{ .dyad = dyad_args }),
            .monad => evalFunc(allocator, func, .{ .monad = .{dyad_args[1]} }),
            .value => error.ArityMismatch,
        },
    };
}

fn applyRightArg(
    allocator: std.mem.Allocator,
    func: *const Expr.FuncExpr,
    args: Args,
    right: Value,
) EvalError!Value {
    return switch (func.arity) {
        .monad => evalFunc(allocator, func, .{ .monad = .{right} }),
        .dyad => {
            const dyad_args = switch (args) {
                .dyad => |dyad_args| dyad_args,
                .monad => return error.ArityMismatch,
            };
            return evalFunc(allocator, func, .{ .dyad = .{ dyad_args[0], right } });
        },
        .value => error.ArityMismatch,
    };
}

test "eval comma partial application fixes the right argument" {
    const allocator = std.testing.allocator;
    const source = "add,3";

    var lexed = try @import("lex.zig").lex(allocator, source);
    defer lexed.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var parser = @import("parse.zig").Parser.init(arena.allocator(), source, lexed.tokens.items, lexed.line_offsets.items);
    defer parser.deinit();
    const file_ast = try parser.parseFile(arena.allocator());

    const result = try evalFunc(arena.allocator(), file_ast.main, .{
        .dyad = .{
            .{ .scalar = .{ .value = 2, .is_char = false } },
            .{ .scalar = .{ .value = 99, .is_char = false } },
        },
    });

    try std.testing.expectEqual(@as(Value.Tag, .scalar), result);
    try std.testing.expectEqual(@as(f64, 5), result.scalar.value);
}

test "eval caret partial application transforms the right argument" {
    const allocator = std.testing.allocator;
    const source = "add^sq";

    var lexed = try @import("lex.zig").lex(allocator, source);
    defer lexed.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var parser = @import("parse.zig").Parser.init(arena.allocator(), source, lexed.tokens.items, lexed.line_offsets.items);
    defer parser.deinit();
    const file_ast = try parser.parseFile(arena.allocator());

    const result = try evalFunc(arena.allocator(), file_ast.main, .{
        .dyad = .{
            .{ .scalar = .{ .value = 2, .is_char = false } },
            .{ .scalar = .{ .value = 3, .is_char = false } },
        },
    });

    try std.testing.expectEqual(@as(Value.Tag, .scalar), result);
    try std.testing.expectEqual(@as(f64, 11), result.scalar.value);
}
