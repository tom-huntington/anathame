const std = @import("std");

pub const TokenTag = enum {
    ident,
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
    backslash,
    dbl_backslash,
    slash,
    equal,
    whitespace,
};

pub const Token = struct {
    tag: TokenTag,
    start: usize,
    end: usize,
    lexeme: []const u8,
};

pub const Arity = enum { value, monad, dyad };

pub const Value = union(enum) {
    scalar: struct { value: f64, is_char: bool },
    array: struct { data: []f64, shape: []u32, is_char: bool },
    ident: []const u8,
};

pub const MonadFn = *const fn (std.mem.Allocator, Value) Value;
pub const DyadFn = *const fn (std.mem.Allocator, Value, Value) Value;

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
};

pub const PartialApply = enum { comma, caret };

pub const Expr = union(enum) {
    value: ValueExpr,
    func: FuncExpr,

    pub const FuncExpr = struct {
        arity: Arity,
        type: union(enum) {
            combinator: struct { op: Combinator, left: *FuncExpr, right: *FuncExpr },
            reduce: *FuncExpr,
            partial_apply: struct { left: *FuncExpr, right: *ValueExpr },
            right_partial_apply: struct { left: *FuncExpr, right: *FuncExpr },
            scope: *FuncExpr,
            userFn: struct { left: []const u8, right: ?[]const u8, body: *Expr },
            builtin: union(enum) { monad: MonadFn, dyad: DyadFn },
        },
    };

    pub const ValueExpr = union(enum) {
        literal: Value,
        strand: struct { left: *Expr, right: *Expr },
        apply: struct { func: *Expr, arg: *Expr },
    };
};
