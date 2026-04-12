const std = @import("std");
const types = @import("types.zig");
const ReservedBumpAllocator = @import("ReservedBumpAllocator").ReservedBumpAllocator; // ../vendor/ReservedBumpAllocator/root.zig
const Expr = types.Expr;
const Value = types.Value;

pub const EvalError = error{
    ArityMismatch,
    NotImplemented,
    MultiValueResult,
    TableMiss,
    UnsupportedFunctionKind,
    UnsupportedValueKind,
    UnboundIdentifier,
};

pub fn evalFunc(ctx: *EvalContext, result_dest: ?[]f64, func: *const Expr.FuncExpr, args: []const Value) EvalError!Value {
    const values = try evalFuncValues(ctx, result_dest, func, args);
    if (values.len != 1) return error.MultiValueResult;
    return values[0];
}

fn evalFuncValues(ctx: *EvalContext, result_dest: ?[]f64, func: *const Expr.FuncExpr, args: []const Value) EvalError![]const Value {
    switch (func.type) {
        .builtin => |builtin| {
            if (args.len != builtin.arity) return error.ArityMismatch;
            if (result_dest != null and builtin.ret_arity != 1) return error.MultiValueResult;
            return builtin.pointer(ctx.allocator, result_dest, args);
        },
        .scope => |scoped| return evalFuncValues(ctx, result_dest, scoped, args),
        .userFn => |user_fn| return evalUserFuncValues(ctx, result_dest, user_fn, args),
        .combinator => |com| {
            switch (com.op) {
                .B1, .B => {
                    var values = try evalFuncValues(ctx, if (com.remaining_args.len == 0) result_dest else null, com.first_arg, args);
                    for (com.remaining_args, 0..) |arg, i| {
                        const child_dest = if (i + 1 == com.remaining_args.len) result_dest else null;
                        values = try evalFuncValues(ctx, child_dest, arg, values);
                    }
                    return values;
                },
                .S => {
                    //
                    const value = try evalFunc(ctx, null, com.first_arg, &.{args[0].shared()});
                    std.debug.assert(args.len == 1);
                    std.debug.assert(com.remaining_args.len == 1);
                    const args2 = [_]Value{ args[0], value };
                    return evalFuncValues(ctx, result_dest, com.remaining_args[0], &args2);
                },
                else => {
                    @panic("not implemented");
                },
            }
        },
        .hof => |hof| {
            if (args.len != hof.arity) return error.ArityMismatch;
            return oneValue(ctx, hof.pointer(ctx, result_dest, args, hof.funcArg.*));
        },
        .partial_apply_permute => |partial| return applyRightArgsValues(ctx, result_dest, partial, args),
        .table => |table| return oneValue(ctx, try evalTableFunc(ctx.allocator, result_dest, table, args)),
    }
}

fn oneValue(ctx: *EvalContext, value: Value) []const Value {
    const values = ctx.allocator.allocator().alloc(Value, 1) catch @panic("out of memory");
    values[0] = value;
    return values;
}

fn evalUserFuncValues(ctx: *EvalContext, result_dest: ?[]f64, user_fn: anytype, args: []const Value) EvalError![]const Value {
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
        .func => |*body_func| evalFuncValues(ctx, result_dest, body_func, args),
        .value => |*body_value| oneValue(ctx, try evalValueExpr(ctx, result_dest, body_value)),
    };
}

fn applyRightArgsValues(
    ctx: *EvalContext,
    result_dest: ?[]f64,
    partial: anytype,
    args: []const Value,
) EvalError![]const Value {
    const right = ctx.allocator.allocator().alloc(Value, partial.arguments.len) catch @panic("out of memory");
    for (partial.arguments, 0..) |*expr, i| {
        right[i] = try evalValueExpr(ctx, null, expr);
    }
    return applyRightArgsValuesForFunc(ctx, result_dest, partial.func, args, right, partial.permutation_index);
}

fn evalTableFunc(allocator: *ReservedBumpAllocator, result_dest: ?[]f64, table: anytype, args: []const Value) EvalError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const lookup_shape = table.lookup.shape;
    if (lookup_shape.len != 2 or lookup_shape[1] != 2) return error.NotImplemented;

    return switch (args[0]) {
        .scalar => |scalar| .{ .scalar = try evalTableScalar(table, scalar) },
        .array => |array| blk: {
            const data = result_dest orelse (allocator.allocator().alloc(f64, array.data.len) catch @panic("out of memory"));
            var meta = types.Array.initWithShape(allocator, array.shape);

            for (array.data, 0..) |item, i| {
                data[i] = try evalTableScalar(table, item);
            }

            meta.data = data;
            break :blk .{ .array = meta };
        },
    };
}

fn evalTableScalar(table: anytype, key: f64) EvalError!f64 {
    const row_count = table.lookup.shape[0];
    for (0..row_count) |row| {
        const row_offset = row * 2;
        const candidate = table.lookup.data[row_offset];
        if (candidate == key) {
            return table.lookup.data[row_offset + 1];
        }
    }

    return switch (table.unmatched) {
        .Error => error.TableMiss,
        .Identity => key,
    };
}

pub const EvalContext = struct {
    allocator: *ReservedBumpAllocator,
    bindings: std.StringHashMap(Value),

    pub fn init(allocator: *ReservedBumpAllocator) EvalContext {
        return .{
            .allocator = allocator,
            .bindings = std.StringHashMap(Value).init(allocator.allocator()),
        };
    }

    pub fn deinit(self: *EvalContext) void {
        self.bindings.deinit();
    }
};

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
        .value => |*value_expr| evalValueExpr(ctx, null, value_expr),
    };
}

fn evalValueExpr(ctx: *EvalContext, result_dest: ?[]f64, expr: *const Expr.ValueExpr) EvalError!Value {
    return switch (expr.*) {
        .literal => |literal| literal,
        .param_ident => |name| ctx.bindings.get(name) orelse error.UnboundIdentifier,
        .strand => |strand| evalStrand(ctx, strand.left, strand.right),
        .apply => |apply| {
            const func = switch (apply.func.*) {
                .func => |*func| func,
                .value => return error.UnsupportedValueKind,
            };
            return evalFunc(ctx, result_dest, func, try evalArgs(ctx, apply.arg));
        },
    };
}

fn evalArgs(ctx: *EvalContext, expr: *const Expr) EvalError![]const Value {
    return switch (expr.*) {
        .func => return error.UnsupportedValueKind,
        .value => |value_expr| switch (value_expr) {
            .literal, .param_ident, .apply => blk: {
                const args = ctx.allocator.allocator().alloc(Value, 1) catch @panic("out of memory");
                args[0] = try evalExpr(ctx, expr);
                break :blk args;
            },
            .strand => |strand| blk: {
                const args = ctx.allocator.allocator().alloc(Value, 2) catch @panic("out of memory");
                args[0] = try evalExpr(ctx, strand.left);
                args[1] = try evalExpr(ctx, strand.right);
                break :blk args;
            },
        },
    };
}

fn applyRightArgsValuesForFunc(
    ctx: *EvalContext,
    result_dest: ?[]f64,
    func: *const Expr.FuncExpr,
    args: []const Value,
    right: []const Value,
    permutation_index: u32,
) EvalError![]const Value {
    const combined = ctx.allocator.allocator().alloc(Value, args.len + right.len) catch @panic("out of memory");
    @memcpy(combined[0..args.len], args);
    @memcpy(combined[args.len..], right);
    if (permutation_index == 0 or combined.len <= 1) {
        return evalFuncValues(ctx, result_dest, func, combined);
    }

    const order = try nthPermutation(ctx.allocator, combined.len, permutation_index);
    const permuted = ctx.allocator.allocator().alloc(Value, combined.len) catch @panic("out of memory");
    for (order, 0..) |source_index, i| {
        permuted[i] = combined[source_index];
    }
    return evalFuncValues(ctx, result_dest, func, permuted);
}

fn nthPermutation(allocator: *ReservedBumpAllocator, len: usize, permutation_index: u32) EvalError![]usize {
    var max_index: u64 = 1;
    for (2..len + 1) |n| {
        max_index *= n;
    }
    if (permutation_index >= max_index) return error.ArityMismatch;

    const indices = allocator.allocator().alloc(usize, len) catch @panic("out of memory");
    const order = allocator.allocator().alloc(usize, len) catch @panic("out of memory");
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
    defer items.deinit(ctx.allocator.allocator());

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
            else => items.append(ctx.allocator.allocator(), try evalValueExpr(ctx, null, &value_expr)) catch @panic("out of memory"),
        },
    }
}

fn materializeArrayStrand(allocator: *ReservedBumpAllocator, items: []const Value) EvalError!Value {
    if (items.len == 0) return error.UnsupportedValueKind;

    const first_shape = switch (items[0]) {
        .scalar => &[_]usize{},
        .array => |array| array.shape,
    };
    const elem_len = switch (items[0]) {
        .scalar => @as(usize, 1),
        .array => |array| array.data.len,
    };

    for (items[1..]) |item| {
        switch (item) {
            .scalar => {
                if (first_shape.len != 0) return error.UnsupportedValueKind;
            },
            .array => |array| {
                if (!std.mem.eql(usize, first_shape, array.shape)) return error.UnsupportedValueKind;
                if (array.data.len != elem_len) return error.UnsupportedValueKind;
            },
        }
    }

    const shape = allocator.allocator().alloc(usize, first_shape.len + 1) catch @panic("out of memory");
    shape[0] = items.len;
    @memcpy(shape[1..], first_shape);
    var meta = types.Array.initWithShape(allocator, shape);

    var data_index: usize = 0;
    for (items) |item| {
        switch (item) {
            .scalar => |scalar| {
                meta.data[data_index] = scalar;
                data_index += 1;
            },
            .array => |array| {
                @memcpy(meta.data[data_index .. data_index + array.data.len], array.data);
                data_index += array.data.len;
            },
        }
    }

    return .{ .array = meta };
}
