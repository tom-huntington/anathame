const std = @import("std");
const types = @import("types.zig");
const Expr = types.Expr;
const Value = types.Value;

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

pub fn evalFunc(allocator: std.mem.Allocator, func: *const Expr.FuncExpr, args: []const Value) EvalError!Value {
    var ctx = EvalContext.init(allocator);
    defer ctx.deinit();
    return evalFuncInContext(&ctx, func, args);
}

fn evalFuncInContext(ctx: *EvalContext, func: *const Expr.FuncExpr, args: []const Value) EvalError!Value {
    switch (func.type) {
        .builtin => |builtin| {
            if (args.len != builtin.arity) return error.ArityMismatch;
            return builtin.pointer(ctx.allocator, args);
        },
        .scope => |scoped| return evalFuncInContext(ctx, scoped, args),
        .userFn => |user_fn| return evalUserFunc(ctx, user_fn, args),
        .combinator => |com| {
            switch (com.op) {
                .B1, .B => {
                    const a = try evalFuncInContext(ctx, com.left, args);
                    return evalFuncInContext(ctx, com.right, &.{a});
                },
                else => {
                    @panic("not implemented");
                },
            }
        },
        .hof => |hof| {
            if (args.len != hof.arity) return error.ArityMismatch;
            return hof.pointer(ctx.allocator, args, hof.funcArg.*);
        },
        .partial_apply_permute => |partial| {
            const right = ctx.allocator.alloc(Value, partial.arguments.len) catch @panic("out of memory");
            for (partial.arguments, 0..) |*expr, i| {
                right[i] = try evalValueExpr(ctx, expr);
            }
            return applyRightArgs(ctx, partial.func, args, right, partial.permutation_index);
        },
    }
}

fn evalUserFunc(ctx: *EvalContext, user_fn: anytype, args: []const Value) EvalError!Value {
    const old_left = ctx.bindings.get(user_fn.left);
    defer restoreBinding(ctx, user_fn.left, old_left);

    switch (args.len) {
        1 => {
            if (user_fn.right != null) return error.ArityMismatch;
            try putBinding(ctx, user_fn.left, args[0]);
        },
        2 => {
            const right_name = user_fn.right orelse return error.ArityMismatch;
            const old_right = ctx.bindings.get(right_name);
            defer restoreBinding(ctx, right_name, old_right);

            try putBinding(ctx, user_fn.left, args[0]);
            try putBinding(ctx, right_name, args[1]);
        },
        else => return error.ArityMismatch,
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
        .literal => |literal| literal,
        .ident => |name| ctx.bindings.get(name) orelse error.UnboundIdentifier,
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

fn evalArgs(ctx: *EvalContext, expr: *const Expr) EvalError![]const Value {
    return switch (expr.*) {
        .func => return error.UnsupportedValueKind,
        .value => |value_expr| switch (value_expr) {
            .literal, .ident, .apply => blk: {
                const args = ctx.allocator.alloc(Value, 1) catch @panic("out of memory");
                args[0] = try evalExpr(ctx, expr);
                break :blk args;
            },
            .strand => |strand| blk: {
                const args = ctx.allocator.alloc(Value, 2) catch @panic("out of memory");
                args[0] = try evalExpr(ctx, strand.left);
                args[1] = try evalExpr(ctx, strand.right);
                break :blk args;
            },
        },
    };
}

fn applyRightArgs(
    ctx: *EvalContext,
    func: *const Expr.FuncExpr,
    args: []const Value,
    right: []const Value,
    permutation_index: u32,
) EvalError!Value {
    const combined = ctx.allocator.alloc(Value, args.len + right.len) catch @panic("out of memory");
    @memcpy(combined[0..args.len], args);
    @memcpy(combined[args.len..], right);
    if (permutation_index == 0 or combined.len <= 1) {
        return evalFuncInContext(ctx, func, combined);
    }

    const order = try nthPermutation(ctx.allocator, combined.len, permutation_index);
    const permuted = ctx.allocator.alloc(Value, combined.len) catch @panic("out of memory");
    for (order, 0..) |source_index, i| {
        permuted[i] = combined[source_index];
    }
    return evalFuncInContext(ctx, func, permuted);
}

fn nthPermutation(allocator: std.mem.Allocator, len: usize, permutation_index: u32) EvalError![]usize {
    var max_index: u64 = 1;
    for (2..len + 1) |n| {
        max_index *= n;
    }
    if (permutation_index >= max_index) return error.ArityMismatch;

    const indices = allocator.alloc(usize, len) catch @panic("out of memory");
    const order = allocator.alloc(usize, len) catch @panic("out of memory");
    for (0..len) |i| {
        indices[i] = i;
    }

    var remaining: u64 = permutation_index;
    var remaining_len = len;
    var out_index: usize = 0;
    while (remaining_len > 0) : (remaining_len -= 1) {
        const block = factorial(remaining_len - 1);
        const pick = if (remaining_len == 1) 0 else @as(usize, @intCast(remaining / block));
        remaining = if (remaining_len == 1) 0 else remaining % block;

        order[out_index] = indices[pick];
        out_index += 1;

        var i = pick;
        while (i + 1 < remaining_len) : (i += 1) {
            indices[i] = indices[i + 1];
        }
    }

    return order;
}

fn factorial(n: usize) u64 {
    if (n < 2) return 1;

    var result: u64 = 1;
    for (2..n + 1) |i| {
        result *= i;
    }
    return result;
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
            .scalar => {
                if (first_shape.len != 0) return error.UnsupportedValueKind;
                is_char = is_char and item.scalar.is_char;
            },
            .array => |array| {
                if (!std.mem.eql(u32, first_shape, array.shape)) return error.UnsupportedValueKind;
                if (array.data.len != elem_len) return error.UnsupportedValueKind;
                is_char = is_char and array.is_char;
            },
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
        }
    }

    return .{ .array = .{ .data = data, .shape = shape, .is_char = is_char } };
}
