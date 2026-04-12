const std = @import("std");
const eval = @import("eval.zig");
const ReservedBumpAllocator = @import("ReservedBumpAllocator").ReservedBumpAllocator; // ../vendor/ReservedBumpAllocator/root.zig

pub const TokenTag = enum {
    ident,
    cases,
    combinator,
    arrow,
    number,
    char_lit,
    raw_string,
    comma,
    caret,
    underscore,
    lparen,
    rparen,
    lbrace,
    rbrace,
    lbracket,
    rbracket,
    backslash,
    dbl_backslash,
    hof,
    equal,
    whitespace,
};

pub const Token = struct {
    tag: TokenTag,
    start: usize,
    end: usize,
    lexeme: []const u8,
};

pub const Ownership = enum {
    Exclusive,
    Shared,
};
pub const Array = struct {
    data: []f64,
    ownership: Ownership,
    shape: []usize,

    pub fn initWithDepth(
        allocator: *ReservedBumpAllocator,
        depth: usize,
        size: usize,
    ) @This() {
        return @import("array_helpers.zig").initWithDepth(allocator, depth, size);
    }

    pub fn initWithShape(
        allocator: *ReservedBumpAllocator,
        shape: []const usize,
    ) @This() {
        const array = initWithDepth(allocator, shape.len, @import("array_helpers.zig").prod(shape));
        @memcpy(array.shape, shape);
        return array;
    }
};

pub const Value = union(enum) {
    scalar: f64,
    array: Array,

    pub fn shared(self: *const @This()) @This() {
        var r = self.*;
        switch (r) {
            .array => {
                r.array.ownership = .Shared;
            },
            else => {},
        }
        return r;
    }

    pub fn Return(self: *const @This(), all: *ReservedBumpAllocator, checkpoint: usize) @This() {
        return @import("array_helpers.zig").Return(all, checkpoint, self);
    }
};

pub const Combinator = enum {
    B,
    B1,
    S,
    Sig,
    D,
    Delta,
    Phi,
    Psi,
    D1,
    D2,
    N,
    V,
    X,
    Xi,
    Phi1,

    pub fn arity(self: Combinator) u32 {
        return switch (self) {
            .B, .B1, .S => 1,
            .Sig, .D, .Delta, .Phi, .Psi, .D1, .D2, .N, .V, .X, .Xi, .Phi1 => std.debug.panic("not implemnted arity for combinator {s}", .{@tagName(self)}),
        };
    }
};

pub const Builtin = struct {
    arity: u32,
    pointer: *const fn (*ReservedBumpAllocator, ?[]f64, []const Value) Value,
};

pub const Hof = struct {
    arity: u32,
    funcArg: *Expr.FuncExpr,
    pointer: *const fn (*eval.EvalContext, ?[]f64, []const Value, Expr.FuncExpr) Value,
};

pub const PartialApply = enum { comma, caret };

pub const Expr = union(enum) {
    value: ValueExpr,
    func: FuncExpr,

    pub const FuncExpr = struct {
        arity: u32,
        type: union(enum) {
            combinator: struct { op: Combinator, first_arg: *FuncExpr, remaining_args: []*FuncExpr },
            hof: Hof,
            table: struct { lookup: Array, unmatched: enum { Error, Identity } },
            partial_apply_permute: struct { func: *FuncExpr, arguments: []ValueExpr, permutation_index: u32 },
            scope: *FuncExpr,
            userFn: struct { left: []const u8, right: ?[]const u8, body: *Expr },
            builtin: Builtin,
        },
    };

    pub const ValueExpr = union(enum) {
        literal: Value,
        // TODO remove strand??
        strand: struct { left: *Expr, right: *Expr },
        apply: struct { func: *Expr, arg: *Expr },
        param_ident: []const u8,
    };
};
