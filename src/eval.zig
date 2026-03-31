const std = @import("std");
const parse = @import("parse.zig");
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
    UnboundIdentifier,
};

const EvalContext = struct {
    allocator: std.mem.Allocator,
    bindings: std.StringHashMap(Value),

    fn init(allocator: std.mem.Allocator) EvalContext {
        return .{
            .allocator = allocator,
            .bindings = std.StringHashMap(Value).init(allocator),
        };
    }

    fn deinit(self: *EvalContext) void {
        self.bindings.deinit();
    }
};

pub fn foldFileConstants(allocator: std.mem.Allocator, file_ast: *parse.FileAst) EvalError!void {
    for (file_ast.consts) |const_def| {
        _ = try foldExpr(allocator, const_def.expr);
    }
    try foldFuncExpr(allocator, file_ast.main);
}

pub fn evalFunc(allocator: std.mem.Allocator, func: *const Expr.FuncExpr, args: Args) EvalError!Value {
    var ctx = EvalContext.init(allocator);
    defer ctx.deinit();
    return evalFuncInContext(&ctx, func, args);
}

fn evalFuncInContext(ctx: *EvalContext, func: *const Expr.FuncExpr, args: Args) EvalError!Value {
    switch (func.type) {
        .builtin => |builtin| switch (builtin) {
            .monad => |f| {
                const monad_args = switch (args) {
                    .monad => |monad_args| monad_args,
                    .dyad => return error.ArityMismatch,
                };
                return f(ctx.allocator, monad_args[0]);
            },
            .dyad => |f| {
                const dyad_args = switch (args) {
                    .dyad => |dyad_args| dyad_args,
                    .monad => return error.ArityMismatch,
                };
                return f(ctx.allocator, dyad_args[0], dyad_args[1]);
            },
        },
        .scope => |scoped| return evalFuncInContext(ctx, scoped, args),
        .userFn => |user_fn| return evalUserFunc(ctx, user_fn, args),
        .combinator => |com| {
            switch (com.op) {
                .B1, .B => {
                    const a = try evalFuncInContext(ctx, com.left, args);
                    return evalFuncInContext(ctx, com.right, .{ .monad = .{a} });
                },
                else => {
                    @panic("not implemented");
                },
            }
        },
        .reduce => |reduced| {
            const monad_args = switch (args) {
                .monad => |monad_args| monad_args,
                .dyad => return error.ArityMismatch,
            };
            return evalReduce(ctx, reduced, monad_args[0]);
        },
        .partial_apply => |partial| {
            const right = try evalValueExpr(ctx, partial.right);
            return applyRightArg(ctx, partial.left, args, right);
        },
        .right_partial_apply => |partial| {
            const right = try evalRightFunc(ctx, partial.right, args);
            return applyRightArg(ctx, partial.left, args, right);
        },
    }
}

fn evalUserFunc(ctx: *EvalContext, user_fn: anytype, args: Args) EvalError!Value {
    const old_left = ctx.bindings.get(user_fn.left);
    defer restoreBinding(ctx, user_fn.left, old_left);

    switch (args) {
        .monad => |monad_args| {
            if (user_fn.right != null) return error.ArityMismatch;
            try putBinding(ctx, user_fn.left, monad_args[0]);
        },
        .dyad => |dyad_args| {
            const right_name = user_fn.right orelse return error.ArityMismatch;
            const old_right = ctx.bindings.get(right_name);
            defer restoreBinding(ctx, right_name, old_right);

            try putBinding(ctx, user_fn.left, dyad_args[0]);
            try putBinding(ctx, right_name, dyad_args[1]);
        },
    }

    return switch (user_fn.body.*) {
        .func => |*body_func| evalFuncInContext(ctx, body_func, args),
        .value => |*body_value| evalValueExpr(ctx, body_value),
    };
}

fn putBinding(ctx: *EvalContext, name: []const u8, value: Value) EvalError!void {
    ctx.bindings.put(name, value) catch @panic("out of memory");
}

fn restoreBinding(ctx: *EvalContext, name: []const u8, old_value: ?Value) void {
    if (old_value) |value| {
        ctx.bindings.put(name, value) catch @panic("out of memory");
    } else {
        _ = ctx.bindings.remove(name);
    }
}

fn evalExpr(ctx: *EvalContext, expr: *const Expr) EvalError!Value {
    return switch (expr.*) {
        .func => return error.UnsupportedValueKind,
        .value => |*value_expr| evalValueExpr(ctx, value_expr),
    };
}

fn evalValueExpr(ctx: *EvalContext, expr: *const Expr.ValueExpr) EvalError!Value {
    return switch (expr.*) {
        .literal => |literal| switch (literal) {
            .ident => |name| ctx.bindings.get(name) orelse error.UnboundIdentifier,
            else => literal,
        },
        .strand => |strand| evalStrand(ctx, strand.left, strand.right),
        .apply => |apply| {
            const func = switch (apply.func.*) {
                .func => |*func| func,
                .value => return error.UnsupportedValueKind,
            };
            return evalFuncInContext(ctx, func, try evalArgs(ctx, apply.arg));
        },
    };
}

fn foldExpr(allocator: std.mem.Allocator, expr: *Expr) EvalError!bool {
    switch (expr.*) {
        .func => {
            try foldFuncExpr(allocator, &expr.func);
            return false;
        },
        .value => {
            if (try tryFoldValueExpr(allocator, &expr.value)) |value| {
                expr.* = .{ .value = .{ .literal = value } };
                return true;
            }
            return false;
        },
    }
}

fn foldFuncExpr(allocator: std.mem.Allocator, func: *Expr.FuncExpr) EvalError!void {
    switch (func.type) {
        .builtin => {},
        .scope => |scoped| try foldFuncExpr(allocator, scoped),
        .userFn => |user_fn| {
            _ = try foldExpr(allocator, user_fn.body);
        },
        .combinator => |com| {
            try foldFuncExpr(allocator, com.left);
            try foldFuncExpr(allocator, com.right);
        },
        .reduce => |reduced| {
            try foldFuncExpr(allocator, reduced);
        },
        .partial_apply => |partial| {
            if (try tryFoldValueExpr(allocator, partial.right)) |value| {
                partial.right.* = .{ .literal = value };
            }
            try foldFuncExpr(allocator, partial.left);
        },
        .right_partial_apply => |partial| {
            try foldFuncExpr(allocator, partial.left);
            try foldFuncExpr(allocator, partial.right);
        },
    }
}

fn tryFoldValueExpr(allocator: std.mem.Allocator, expr: *Expr.ValueExpr) EvalError!?Value {
    switch (expr.*) {
        .literal => |literal| {
            if (literal == .ident) return null;
            return literal;
        },
        .strand => |strand| {
            const left_const = try foldExpr(allocator, strand.left);
            const right_const = try foldExpr(allocator, strand.right);
            if (!left_const or !right_const) return null;
        },
        .apply => |apply| {
            if (apply.func.* != .func) return null;
            try foldFuncExpr(allocator, &apply.func.func);
            const arg_const = try foldExpr(allocator, apply.arg);
            if (!arg_const) return null;
        },
    }

    var ctx = EvalContext.init(allocator);
    defer ctx.deinit();
    return evalValueExpr(&ctx, expr) catch |err| switch (err) {
        error.UnboundIdentifier => null,
        else => return err,
    };
}

fn evalArgs(ctx: *EvalContext, expr: *const Expr) EvalError!Args {
    return switch (expr.*) {
        .func => return error.UnsupportedValueKind,
        .value => |value_expr| switch (value_expr) {
            .literal, .apply => .{ .monad = .{try evalExpr(ctx, expr)} },
            .strand => |strand| .{
                .dyad = .{
                    try evalExpr(ctx, strand.left),
                    try evalExpr(ctx, strand.right),
                },
            },
        },
    };
}

fn evalRightFunc(ctx: *EvalContext, func: *const Expr.FuncExpr, args: Args) EvalError!Value {
    return switch (args) {
        .monad => |monad_args| evalFuncInContext(ctx, func, .{ .monad = monad_args }),
        .dyad => |dyad_args| switch (func.arity) {
            .dyad => evalFuncInContext(ctx, func, .{ .dyad = dyad_args }),
            .monad => evalFuncInContext(ctx, func, .{ .monad = .{dyad_args[1]} }),
            .value => error.ArityMismatch,
        },
    };
}

fn applyRightArg(
    ctx: *EvalContext,
    func: *const Expr.FuncExpr,
    args: Args,
    right: Value,
) EvalError!Value {
    return switch (func.arity) {
        .monad => evalFuncInContext(ctx, func, .{ .monad = .{right} }),
        .dyad => {
            const monad_args = switch (args) {
                .monad => |monad_args| monad_args,
                .dyad => return error.ArityMismatch,
            };
            return evalFuncInContext(ctx, func, .{ .dyad = .{ monad_args[0], right } });
        },
        .value => error.ArityMismatch,
    };
}

fn evalReduce(ctx: *EvalContext, func: *const Expr.FuncExpr, value: Value) EvalError!Value {
    const array = switch (value) {
        .array => |array| array,
        else => return error.UnsupportedValueKind,
    };

    if (array.shape.len != 1) return error.UnsupportedValueKind;
    if (array.data.len == 0) return error.UnsupportedValueKind;

    var acc: Value = .{
        .scalar = .{
            .value = array.data[0],
            .is_char = array.is_char,
        },
    };

    for (array.data[1..]) |item| {
        acc = try evalFuncInContext(ctx, func, .{
            .dyad = .{
                acc,
                .{ .scalar = .{ .value = item, .is_char = array.is_char } },
            },
        });
    }

    return acc;
}

fn evalStrand(ctx: *EvalContext, left: *const Expr, right: *const Expr) EvalError!Value {
    var items: std.ArrayList(Value) = .empty;
    defer items.deinit(ctx.allocator);

    try appendStrandItems(ctx, &items, left);
    try appendStrandItems(ctx, &items, right);
    return materializeArrayStrand(ctx.allocator, items.items);
}

fn appendStrandItems(ctx: *EvalContext, items: *std.ArrayList(Value), expr: *const Expr) EvalError!void {
    switch (expr.*) {
        .func => return error.UnsupportedValueKind,
        .value => |value_expr| switch (value_expr) {
            .strand => |strand| {
                try appendStrandItems(ctx, items, strand.left);
                try appendStrandItems(ctx, items, strand.right);
            },
            else => items.append(ctx.allocator, try evalValueExpr(ctx, &value_expr)) catch @panic("out of memory"),
        },
    }
}

fn materializeArrayStrand(allocator: std.mem.Allocator, items: []const Value) EvalError!Value {
    if (items.len == 0) return error.UnsupportedValueKind;

    const first_shape = switch (items[0]) {
        .scalar => &[_]u32{},
        .array => |array| array.shape,
        .ident => return error.UnsupportedValueKind,
    };
    const elem_len = switch (items[0]) {
        .scalar => @as(usize, 1),
        .array => |array| array.data.len,
        .ident => unreachable,
    };

    var is_char = switch (items[0]) {
        .scalar => |scalar| scalar.is_char,
        .array => |array| array.is_char,
        .ident => unreachable,
    };

    for (items[1..]) |item| {
        switch (item) {
            .scalar => {
                if (first_shape.len != 0) return error.UnsupportedValueKind;
                is_char = is_char and item.scalar.is_char;
            },
            .array => |array| {
                if (!std.mem.eql(u32, first_shape, array.shape)) return error.UnsupportedValueKind;
                if (array.data.len != elem_len) return error.UnsupportedValueKind;
                is_char = is_char and array.is_char;
            },
            .ident => return error.UnsupportedValueKind,
        }
    }

    const data = allocator.alloc(f64, items.len * elem_len) catch @panic("out of memory");
    const shape = allocator.alloc(u32, first_shape.len + 1) catch @panic("out of memory");
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
            .ident => return error.UnsupportedValueKind,
        }
    }

    return .{ .array = .{ .data = data, .shape = shape, .is_char = is_char } };
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
        .monad = .{
            .{ .scalar = .{ .value = 2, .is_char = false } },
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
        .monad = .{
            .{ .scalar = .{ .value = 3, .is_char = false } },
        },
    });

    try std.testing.expectEqual(@as(Value.Tag, .scalar), result);
    try std.testing.expectEqual(@as(f64, 12), result.scalar.value);
}

test "eval strand materializes a constant array" {
    const allocator = std.testing.allocator;
    const source = "1_2_3";

    var lexed = try @import("lex.zig").lex(allocator, source);
    defer lexed.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var parser = @import("parse.zig").Parser.init(arena.allocator(), source, lexed.tokens.items, lexed.line_offsets.items);
    defer parser.deinit();
    try parser.populateBuiltins();

    var index: usize = 0;
    const expr = try parser.parseExpr(&index, lexed.tokens.items.len, 0, null);

    var ctx = EvalContext.init(arena.allocator());
    defer ctx.deinit();
    const result = try evalExpr(&ctx, expr);
    try std.testing.expectEqual(@as(Value.Tag, .array), result);
    try std.testing.expectEqualSlices(f64, &.{ 1, 2, 3 }, result.array.data);
    try std.testing.expectEqualSlices(u32, &.{ 3 }, result.array.shape);
}

test "constant folding rewrites partial application constants before main eval" {
    const allocator = std.testing.allocator;
    const source =
        \\a = 1_1
        \\add,a )b1 sq
    ;

    var lexed = try @import("lex.zig").lex(allocator, source);
    defer lexed.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var parser = @import("parse.zig").Parser.init(arena.allocator(), source, lexed.tokens.items, lexed.line_offsets.items);
    defer parser.deinit();
    var file_ast = try parser.parseFile(arena.allocator());

    try foldFileConstants(arena.allocator(), &file_ast);

    try std.testing.expectEqual(@as(Expr.ValueExpr.Tag, .literal), file_ast.consts[0].expr.value);
    try std.testing.expectEqual(@as(Value.Tag, .array), file_ast.consts[0].expr.value.literal);

    const partial = switch (file_ast.main.type) {
        .combinator => |com| switch (com.left.type) {
            .partial_apply => |partial| partial,
            else => return error.UnsupportedFunctionKind,
        },
        else => return error.UnsupportedFunctionKind,
    };

    try std.testing.expectEqual(@as(Expr.ValueExpr.Tag, .literal), partial.right.*);
    try std.testing.expectEqual(@as(Value.Tag, .array), partial.right.literal);
}

test "eval monadic arrow function evaluates a value body with a bound parameter" {
    const allocator = std.testing.allocator;
    const source = "x -> x sq";

    var lexed = try @import("lex.zig").lex(allocator, source);
    defer lexed.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var parser = @import("parse.zig").Parser.init(arena.allocator(), source, lexed.tokens.items, lexed.line_offsets.items);
    defer parser.deinit();
    const file_ast = try parser.parseFile(arena.allocator());

    const result = try evalFunc(arena.allocator(), file_ast.main, .{
        .monad = .{
            .{ .scalar = .{ .value = 4, .is_char = false } },
        },
    });

    try std.testing.expectEqual(@as(Value.Tag, .scalar), result);
    try std.testing.expectEqual(@as(f64, 16), result.scalar.value);
}

test "eval dyadic arrow function binds both parameters in a value body" {
    const allocator = std.testing.allocator;
    const source = "x y -> x_y";

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

    try std.testing.expectEqual(@as(Value.Tag, .array), result);
    try std.testing.expectEqualSlices(f64, &.{ 2, 3 }, result.array.data);
}

test "eval monadic arrow function tail-calls a function body" {
    const allocator = std.testing.allocator;
    const source = "x -> sq";

    var lexed = try @import("lex.zig").lex(allocator, source);
    defer lexed.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var parser = @import("parse.zig").Parser.init(arena.allocator(), source, lexed.tokens.items, lexed.line_offsets.items);
    defer parser.deinit();
    const file_ast = try parser.parseFile(arena.allocator());

    const result = try evalFunc(arena.allocator(), file_ast.main, .{
        .monad = .{
            .{ .scalar = .{ .value = 5, .is_char = false } },
        },
    });

    try std.testing.expectEqual(@as(Value.Tag, .scalar), result);
    try std.testing.expectEqual(@as(f64, 25), result.scalar.value);
}

test "eval slash reduce folds rank-1 arrays" {
    const allocator = std.testing.allocator;
    const source = "/ add";

    var lexed = try @import("lex.zig").lex(allocator, source);
    defer lexed.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var parser = @import("parse.zig").Parser.init(arena.allocator(), source, lexed.tokens.items, lexed.line_offsets.items);
    defer parser.deinit();
    const file_ast = try parser.parseFile(arena.allocator());

    const result = try evalFunc(arena.allocator(), file_ast.main, .{
        .monad = .{
            .{ .array = .{ .data = &.{ 1, 2, 3, 4 }, .shape = &.{4}, .is_char = false } },
        },
    });

    try std.testing.expectEqual(@as(Value.Tag, .scalar), result);
    try std.testing.expectEqual(@as(f64, 10), result.scalar.value);
}
