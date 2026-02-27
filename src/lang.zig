const std = @import("std");

pub const Arity = enum { value, monad, dyad };

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

pub const Value = union(enum) {
    scalar: struct { value: f64, is_char: bool },
    array: struct { data: []f64, shape: []u32, is_char: bool },
};

pub const Expr = union(enum) {
    value: ValueUnion,
    func: FuncUnion,

    pub const FuncUnion = struct {
        arity: Arity,
        union_: union(enum) {
            //prefix: struct { op: TokenTag, right: *Expr },
            combinator: struct { op: Combinator, left: *FuncUnion, right: *FuncUnion },
            partial_apply: struct { op: PartialApply, left: *FuncUnion, right: *FuncUnion },
            scope: *FuncUnion,
            builtin: union(enum) { monad: MonadFn, dyad: DyadFn },
        },
    };

    pub const ValueUnion = union(enum) {
        literal: Value,
        strand: struct { left: *Expr, right: *Expr },
        apply_rev: struct { func: *Expr, arg: *Expr },
    };
};

fn builtinStubMonad(_: std.mem.Allocator, _: Value) Value {
    @panic("builtin monad not implemented");
}

fn builtinStubDyad(_: std.mem.Allocator, _: Value, _: Value) Value {
    @panic("builtin dyad not implemented");
}

pub const ConstDef = struct {
    name: []const u8,
    expr: *Expr,
};

pub const FileAst = struct {
    consts: []ConstDef,
    main: *Expr,
};

pub const TokenTag = enum {
    ident,
    combinator,
    number,
    char_lit,
    raw_string,
    comma,
    caret,
    underscore,
    pipe_gt,
    lparen,
    rparen,
    lbrace,
    rbrace,
    backslash,
    dbl_backslash,
    equal,
};

pub const Token = struct {
    tag: TokenTag,
    start: usize,
    end: usize,

    pub fn lexeme(self: Token, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }
};

pub fn lex(allocator: std.mem.Allocator, source: []const u8) !std.ArrayList(std.ArrayList(Token)) {
    //var lines = std.ArrayList(std.ArrayList(Token)).init(allocator);
    var lines = try std.ArrayList(std.ArrayList(Token)).initCapacity(allocator, 0);
    errdefer {
        for (lines.items) |*line| line.deinit(allocator);
        lines.deinit(allocator);
    }

    var it = std.mem.splitScalar(u8, source, '\n');
    var offset: usize = 0;
    while (it.next()) |line| {
        var tokens: std.ArrayList(Token) = .empty;
        // missing `defer list.deinit(gpa);`
        //try list.append(gpa, '☔');
        try lexLine(allocator, &tokens, line, offset);
        try lines.append(allocator, tokens);
        offset += line.len + 1;
    }
    return lines;
}

fn lexLine(allocator: std.mem.Allocator, tokens: *std.ArrayList(Token), line: []const u8, base: usize) !void {
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        if (std.ascii.isWhitespace(c)) {
            i += 1;
            continue;
        }

        const start = base + i;

        switch (c) {
            ',' => {
                try tokens.append(allocator, .{ .tag = .comma, .start = start, .end = start + 1 });
                i += 1;
            },
            '^' => {
                try tokens.append(allocator, .{ .tag = .caret, .start = start, .end = start + 1 });
                i += 1;
            },
            '_' => {
                try tokens.append(allocator, .{ .tag = .underscore, .start = start, .end = start + 1 });
                i += 1;
            },
            '(' => {
                if (i + 1 < line.len and std.ascii.isAlphabetic(line[i + 1])) {
                    var j = i + 1;
                    while (j < line.len and std.ascii.isAlphanumeric(line[j])) : (j += 1) {}
                    try tokens.append(allocator, .{ .tag = .combinator, .start = start, .end = base + j });
                    i = j;
                } else {
                    try tokens.append(allocator, .{ .tag = .lparen, .start = start, .end = start + 1 });
                    i += 1;
                }
            },
            ')' => {
                try tokens.append(allocator, .{ .tag = .rparen, .start = start, .end = start + 1 });
                i += 1;
            },
            '{' => {
                try tokens.append(allocator, .{ .tag = .lbrace, .start = start, .end = start + 1 });
                i += 1;
            },
            '}' => {
                try tokens.append(allocator, .{ .tag = .rbrace, .start = start, .end = start + 1 });
                i += 1;
            },
            '|' => {
                if (i + 1 < line.len and line[i + 1] == '>') {
                    try tokens.append(allocator, .{ .tag = .pipe_gt, .start = start, .end = start + 2 });
                    i += 2;
                } else {
                    return error.UnexpectedChar;
                }
            },
            '\\' => {
                if (i + 1 < line.len and line[i + 1] == '\\') {
                    try tokens.append(allocator, .{ .tag = .dbl_backslash, .start = start, .end = start + 2 });
                    i += 2;
                } else {
                    try tokens.append(allocator, .{ .tag = .backslash, .start = start, .end = start + 1 });
                    i += 1;
                }
            },
            '=' => {
                try tokens.append(allocator, .{ .tag = .equal, .start = start, .end = start + 1 });
                i += 1;
            },
            '$' => {
                // Raw string literal: consume rest of line.
                try tokens.append(allocator, .{ .tag = .raw_string, .start = start, .end = base + line.len });
                break;
            },
            '@' => {
                if (i + 1 >= line.len) return error.UnexpectedChar;
                try tokens.append(allocator, .{ .tag = .char_lit, .start = start, .end = start + 2 });
                i += 2;
            },
            else => {
                if (std.ascii.isDigit(c)) {
                    var j = i;
                    while (j < line.len and std.ascii.isDigit(line[j])) : (j += 1) {}
                    if (j < line.len and line[j] == '.') {
                        j += 1;
                        if (j >= line.len or !std.ascii.isDigit(line[j])) return error.InvalidNumber;
                        while (j < line.len and std.ascii.isDigit(line[j])) : (j += 1) {}
                        try tokens.append(allocator, .{ .tag = .number, .start = start, .end = base + j });
                        i = j;
                    } else {
                        return error.InvalidNumber;
                    }
                } else if (std.ascii.isAlphabetic(c)) {
                    var j = i;
                    while (j < line.len and std.ascii.isAlphabetic(line[j])) : (j += 1) {}
                    try tokens.append(allocator, .{ .tag = .ident, .start = start, .end = base + j });
                    i = j;
                } else {
                    return error.UnexpectedChar;
                }
            },
        }
    }
}

pub const Symbol = struct {
    expr: *Expr,
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    lines: []std.ArrayList(Token),
    symbols: std.StringHashMap(Symbol),

    pub fn init(allocator: std.mem.Allocator, source: []const u8, lines: []std.ArrayList(Token)) Parser {
        const symbols = std.StringHashMap(Symbol).init(allocator);
        return .{
            .allocator = allocator,
            .source = source,
            .lines = lines,
            .symbols = symbols,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.symbols.deinit();
    }

    pub fn parseFile(self: *Parser, allocator: std.mem.Allocator) !FileAst {
        try self.installBuiltins();

        var consts: std.ArrayList(ConstDef) = .empty;
        errdefer consts.deinit(allocator);

        var last_nonempty: ?usize = null;
        for (self.lines, 0..) |line, i| {
            if (line.items.len > 0) last_nonempty = i;
        }
        if (last_nonempty == null) return error.MissingMain;

        var line_index: usize = 0;
        while (line_index < self.lines.len) : (line_index += 1) {
            const line = &self.lines[line_index];
            if (line.items.len == 0) continue;

            const is_last = line_index == last_nonempty.?;
            if (!is_last) {
                const const_def = try self.parseConst(line);
                try consts.append(allocator, const_def);
            } else {
                const main_expr = try self.parseExprLine(line, null);
                if (main_expr.* != .func) return error.MainMustBeFunction;
                return FileAst{
                    .consts = try consts.toOwnedSlice(allocator),
                    .main = main_expr,
                };
            }
        }
        return error.MissingMain;
    }

    fn installBuiltins(self: *Parser) !void {
        const add_expr = try self.allocExpr(.{
            .func = .{ .arity = .dyad, .union_ = .{ .builtin = .{ .dyad = builtinStubDyad } } },
        });
        try self.symbols.put("add", .{ .expr = add_expr });

        const mult_expr = try self.allocExpr(.{
            .func = .{ .arity = .dyad, .union_ = .{ .builtin = .{ .dyad = builtinStubDyad } } },
        });
        try self.symbols.put("mult", .{ .expr = mult_expr });

        const inf_expr = try self.allocExpr(.{
            .value = .{ .literal = .{ .scalar = .{ .value = std.math.inf(f64), .is_char = false } } },
        });
        try self.symbols.put("inf", .{ .expr = inf_expr });

        const pi_expr = try self.allocExpr(.{
            .value = .{ .literal = .{ .scalar = .{ .value = std.math.pi, .is_char = false } } },
        });
        try self.symbols.put("pi", .{ .expr = pi_expr });
    }

    fn parseConst(self: *Parser, line: *const std.ArrayList(Token)) !ConstDef {
        if (line.items.len < 3) return error.InvalidConst;
        const name_tok = line.items[0];
        if (name_tok.tag != .ident) return error.InvalidConst;
        const eq_tok = line.items[1];
        if (eq_tok.tag != .equal) return error.InvalidConst;

        var sub = self.makeSubParser(line, 2);
        const expr = try sub.parseExpr(0, null);
        try self.symbols.put(name_tok.lexeme(self.source), .{ .expr = expr });
        return .{ .name = name_tok.lexeme(self.source), .expr = expr };
    }

    fn parseExprLine(self: *Parser, line: *const std.ArrayList(Token), end_tag: ?TokenTag) !*Expr {
        var sub = self.makeSubParser(line, 0);
        return sub.parseExpr(0, end_tag);
    }

    fn makeSubParser(self: *Parser, line: *const std.ArrayList(Token), start_index: usize) SubParser {
        return .{ .parser = self, .line = line, .index = start_index };
    }

    fn allocExpr(self: *Parser, expr: Expr) !*Expr {
        const ptr = try self.allocator.create(Expr);
        ptr.* = expr;
        return ptr;
    }
};

const SubParser = struct {
    parser: *Parser,
    line: *const std.ArrayList(Token),
    index: usize,

    fn parseExpr(self: *SubParser, min_bp: u8, end_tag: ?TokenTag) !*Expr {
        var left = try self.parsePrefix(end_tag);

        while (self.index < self.line.items.len) {
            const tok = self.line.items[self.index];
            if (end_tag) |tag| {
                if (tok.tag == tag) break;
            }

            const op_info = infixInfo(tok.tag) orelse break;
            if (op_info.lbp < min_bp) break;
            self.index += 1;

            const right = try self.parseExpr(op_info.rbp, end_tag);
            left = try self.buildInfix(tok, left, right);
        }

        return left;
    }

    const SubParserError = error{
        UnexpectedEof,
        UnknownIdentifier,
        MissingRightParen,
        MissingRightBrace,
        UnexpectedToken,
        ExpectedFunction,
        UnknownCombinator,
    };

    fn parsePrefix(self: *SubParser, end_tag: ?TokenTag) (SubParserError || std.fmt.ParseFloatError || std.mem.Allocator.Error)!*Expr {
        if (self.index >= self.line.items.len) return error.UnexpectedEof;
        const tok = self.line.items[self.index];
        self.index += 1;

        switch (tok.tag) {
            .number => {
                const slice = tok.lexeme(self.parser.source);
                const val = try std.fmt.parseFloat(f64, slice);
                return self.parser.allocExpr(.{
                    .value = .{ .literal = .{ .scalar = .{ .value = val, .is_char = false } } },
                });
            },
            .char_lit => {
                const slice = tok.lexeme(self.parser.source);
                const ch = slice[1];
                return self.parser.allocExpr(.{
                    .value = .{ .literal = .{ .scalar = .{ .value = @floatFromInt(ch), .is_char = true } } },
                });
            },
            .raw_string => {
                // Placeholder: raw strings are parsed as value arrays later.
                return self.parser.allocExpr(.{
                    .value = .{ .literal = .{ .array = .{ .data = &.{}, .shape = &.{}, .is_char = true } } },
                });
            },
            .ident => {
                const name = tok.lexeme(self.parser.source);
                const sym = self.parser.symbols.get(name) orelse return error.UnknownIdentifier;
                return sym.expr;
            },
            .lparen => {
                const body = try self.parseExpr(0, .rparen);
                if (self.index >= self.line.items.len or self.line.items[self.index].tag != .rparen) {
                    return error.MissingRightParen;
                }
                self.index += 1;
                return self.parser.allocExpr(.{
                    .func = .{ .arity = .monad, .union_ = .{ .scope = &body.func } },
                });
            },
            .lbrace => {
                const body = try self.parseExpr(0, .rbrace);
                if (self.index >= self.line.items.len or self.line.items[self.index].tag != .rbrace) {
                    return error.MissingRightBrace;
                }
                self.index += 1;
                return self.parser.allocExpr(.{
                    .func = .{ .arity = .dyad, .union_ = .{ .scope = .{body} } },
                });
            },
            .backslash => {
                const body = try self.parseExpr(0, end_tag);
                _ = body;
                return self.parser.allocExpr(.{
                    .func = .{ .arity = .monad, .union_ = .{ .builtin = .{ .monad = builtinStubMonad } } },
                });
            },
            .dbl_backslash => {
                const body = try self.parseExpr(0, end_tag);
                _ = body;
                return self.parser.allocExpr(.{
                    .func = .{ .arity = .dyad, .union_ = .{ .builtin = .{ .dyad = builtinStubDyad } } },
                });
            },
            else => return error.UnexpectedToken,
        }
    }

    fn buildInfix(self: *SubParser, tok: Token, left: *Expr, right: *Expr) !*Expr {
        switch (tok.tag) {
            .comma => {
                const left_func = switch (left.*) {
                    .func => |f| f,
                    .value => return error.ExpectedFunction,
                };
                return self.parser.allocExpr(.{
                    .func = .{ .arity = left_func.arity, .union_ = .{ .partial_apply = .{ .op = .comma, .left = &left.func, .right = &right.func } } },
                });
            },
            .underscore => {
                return self.parser.allocExpr(.{
                    .value = .{ .strand = .{ .left = left, .right = right } },
                });
            },
            .pipe_gt => {
                if (left.* != .func) return error.ExpectedFunction;
                return self.parser.allocExpr(.{
                    .value = .{ .apply_rev = .{ .func = left, .arg = right } },
                });
            },
            .combinator => {
                const left_func = switch (left.*) {
                    .func => |f| f,
                    .value => return error.ExpectedFunction,
                };
                const right_func = switch (right.*) {
                    .func => |f| f,
                    .value => return error.ExpectedFunction,
                };
                const arity = if (left_func.arity == right_func.arity) left_func.arity else .dyad;
                const op = parseCombinator(tok, self.parser.source) orelse return error.UnknownCombinator;
                return self.parser.allocExpr(.{
                    .func = .{ .arity = arity, .union_ = .{ .combinator = .{ .op = op, .left = &left.func, .right = &right.func } } },
                });
            },
            .caret => {
                const left_func = switch (left.*) {
                    .func => |f| f,
                    .value => return error.ExpectedFunction,
                };
                return self.parser.allocExpr(.{
                    .func = .{ .arity = left_func.arity, .union_ = .{ .partial_apply = .{ .op = .caret, .left = &left.func, .right = &right.func } } },
                });
            },
            else => return error.UnexpectedToken,
        }
    }
};

const InfixInfo = struct { lbp: u8, rbp: u8 };

fn infixInfo(tag: TokenTag) ?InfixInfo {
    return switch (tag) {
        .comma => .{ .lbp = 90, .rbp = 91 },
        .underscore => .{ .lbp = 80, .rbp = 81 },
        .combinator => .{ .lbp = 60, .rbp = 61 },
        .caret => .{ .lbp = 55, .rbp = 56 },
        .pipe_gt => .{ .lbp = 10, .rbp = 11 },
        else => null,
    };
}

fn parseCombinator(tok: Token, source: []const u8) ?Combinator {
    const ident = tok.lexeme(source);
    if (ident.len < 2 or ident[0] != '(') return null;
    const name = ident[1..];

    if (std.ascii.eqlIgnoreCase(name, "b")) return .B;
    if (std.ascii.eqlIgnoreCase(name, "b1")) return .B1;
    if (std.ascii.eqlIgnoreCase(name, "s")) return .S;
    if (std.ascii.eqlIgnoreCase(name, "sig")) return .Sig;
    if (std.ascii.eqlIgnoreCase(name, "d")) return .D;
    if (std.ascii.eqlIgnoreCase(name, "delta")) return .Delta;
    if (std.ascii.eqlIgnoreCase(name, "phi")) return .Phi;
    if (std.ascii.eqlIgnoreCase(name, "psi")) return .Psi;
    if (std.ascii.eqlIgnoreCase(name, "d1")) return .D1;
    if (std.ascii.eqlIgnoreCase(name, "d2")) return .D2;
    if (std.ascii.eqlIgnoreCase(name, "n")) return .N;
    if (std.ascii.eqlIgnoreCase(name, "v")) return .V;
    if (std.ascii.eqlIgnoreCase(name, "x")) return .X;
    if (std.ascii.eqlIgnoreCase(name, "xi")) return .Xi;
    if (std.ascii.eqlIgnoreCase(name, "phi1")) return .Phi1;

    return null;
}
