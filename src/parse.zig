const std = @import("std");
const builtins = @import("builtins.zig");
const types = @import("types.zig");
const Token = types.Token;
const Value = types.Value;
const Arity = types.Arity;
const Expr = types.Expr;
const TokenTag = types.TokenTag;
const Combinator = types.Combinator;

pub const ConstDef = struct {
    name: []const u8,
    expr: *Expr,
};

pub const FileAst = struct {
    consts: []ConstDef,
    main: *Expr.FuncExpr,
};

pub const Symbol = struct {
    expr: *Expr,
};

const StatementKind = enum {
    const_def,
    expr,
};

const Statement = struct {
    kind: StatementKind,
    start: usize,
    end: usize,
};

const ParseError = error{
    UnexpectedEof,
    UnknownIdentifier,
    MissingRightParen,
    MissingRightBrace,
    UnexpectedToken,
    ExpectedFunction,
    ExpectedValue,
    UnknownCombinator,
    MissingMain,
    MainMustBeFunction,
    InvalidConst,
} || std.fmt.ParseFloatError || std.mem.Allocator.Error;

pub const Parser = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const Token,
    line_offsets: []const u32,
    symbols: std.StringHashMap(Symbol),
    local_params: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator, source: []const u8, tokens: []const Token, line_offsets: []const u32) Parser {
        const symbols = std.StringHashMap(Symbol).init(allocator);
        return .{
            .allocator = allocator,
            .source = source,
            .tokens = tokens,
            .line_offsets = line_offsets,
            .symbols = symbols,
            .local_params = .empty,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.symbols.deinit();
        self.local_params.deinit(self.allocator);
    }

    pub fn parseFile(self: *Parser, allocator: std.mem.Allocator) ParseError!FileAst {
        try self.populateBuiltins();

        var consts: std.ArrayList(ConstDef) = .empty;
        errdefer consts.deinit(allocator);

        var statements = try self.collectStatements(allocator);
        defer statements.deinit(allocator);

        if (statements.items.len == 0) return error.MissingMain;

        const main_stmt = statements.items[statements.items.len - 1];
        if (main_stmt.kind != .expr) return error.MissingMain;

        for (statements.items[0 .. statements.items.len - 1]) |stmt| {
            if (stmt.kind != .const_def) return error.InvalidConst;
            const const_def = try self.parseConst(stmt);
            try consts.append(allocator, const_def);
        }

        var main_index = main_stmt.start;
        const main_expr = try self.parseExpr(&main_index, main_stmt.end, 0, null);
        self.skipWhitespace(&main_index, main_stmt.end);
        if (main_index != main_stmt.end) return error.UnexpectedToken;
        if (main_expr.* != .func) return error.MainMustBeFunction;

        return .{
            .consts = try consts.toOwnedSlice(allocator),
            .main = &main_expr.func,
        };
    }

    pub fn populateBuiltins(self: *Parser) ParseError!void {
        inline for (@typeInfo(builtins).@"struct".decls) |decl| {
            const member = @field(builtins, decl.name);
            const member_info = @typeInfo(@TypeOf(member));

            switch (member_info) {
                .@"fn" => {
                    const params = member_info.@"fn".params;
                    if (params.len == 2) {
                        const expr = try self.allocExpr(.{
                            .func = .{ .arity = .monad, .type = .{ .builtin = .{ .monad = member } } },
                        });
                        try self.symbols.put(decl.name, .{ .expr = expr });
                    } else if (params.len == 3) {
                        const expr = try self.allocExpr(.{
                            .func = .{ .arity = .dyad, .type = .{ .builtin = .{ .dyad = member } } },
                        });
                        try self.symbols.put(decl.name, .{ .expr = expr });
                    }
                },
                else => {},
            }
        }
    }

    fn collectStatements(self: *Parser, allocator: std.mem.Allocator) ParseError!std.ArrayList(Statement) {
        var statements: std.ArrayList(Statement) = .empty;
        errdefer statements.deinit(allocator);

        var pending_expr_start: ?usize = null;

        for (0..self.lineCount()) |line_index| {
            const line = self.lineTokens(line_index);
            const line_start = firstNonWhitespaceIndex(line) orelse continue;
            const global_start = @as(usize, self.line_offsets[line_index]) + line_start;
            const kind = if (isConstStart(line, line_start)) StatementKind.const_def else StatementKind.expr;

            switch (kind) {
                .const_def => {
                    if (pending_expr_start) |_| return error.InvalidConst;
                    try statements.append(allocator, .{
                        .kind = .const_def,
                        .start = global_start,
                        .end = self.tokens.len,
                    });
                },
                .expr => {
                    if (pending_expr_start == null) {
                        pending_expr_start = global_start;
                        try statements.append(allocator, .{
                            .kind = .expr,
                            .start = global_start,
                            .end = self.tokens.len,
                        });
                    }
                },
            }
        }

        if (statements.items.len == 0) return statements;

        for (0..statements.items.len - 1) |i| {
            statements.items[i].end = statements.items[i + 1].start;
        }
        statements.items[statements.items.len - 1].end = self.tokens.len;

        return statements;
    }

    fn lineCount(self: *const Parser) usize {
        return if (self.line_offsets.len == 0) 0 else self.line_offsets.len - 1;
    }

    fn lineTokens(self: *const Parser, line_index: usize) []const Token {
        const start = self.line_offsets[line_index];
        const end = self.line_offsets[line_index + 1];
        return self.tokens[start..end];
    }

    fn parseConst(self: *Parser, stmt: Statement) ParseError!ConstDef {
        var index = stmt.start;
        const name_tok = self.nextNonWhitespaceToken(&index, stmt.end) orelse return error.InvalidConst;
        if (name_tok.tag != .ident) return error.InvalidConst;

        const eq_tok = self.nextNonWhitespaceToken(&index, stmt.end) orelse return error.InvalidConst;
        if (eq_tok.tag != .equal) return error.InvalidConst;

        const expr = try self.parseExpr(&index, stmt.end, 0, null);
        self.skipWhitespace(&index, stmt.end);
        if (index != stmt.end) return error.UnexpectedToken;

        try self.symbols.put(name_tok.lexeme, .{ .expr = expr });
        return .{ .name = name_tok.lexeme, .expr = expr };
    }

    fn parseExpr(self: *Parser, index: *usize, end_index: usize, min_bp: u8, end_tag: ?TokenTag) ParseError!*Expr {
        var left = try self.parsePrefix(index, end_index, end_tag);

        while (true) {
            self.skipWhitespace(index, end_index);
            if (index.* >= end_index) break;

            const tok = self.tokens[index.*];
            if (end_tag) |tag| {
                if (tok.tag == tag) break;
            }

            const op_info = infixInfo(tok.tag) orelse break;
            if (op_info.lbp < min_bp) break;
            index.* += 1;

            const right = try self.parseExpr(index, end_index, op_info.rbp, end_tag);
            left = try self.buildInfix(tok, left, right);
        }

        left = try self.maybeParseImplicitApply(index, end_index, end_tag, left);
        return left;
    }

    fn maybeParseImplicitApply(self: *Parser, index: *usize, end_index: usize, end_tag: ?TokenTag, left: *Expr) ParseError!*Expr {
        if (left.* != .value) return left;

        var apply_index = index.*;
        self.skipWhitespace(&apply_index, end_index);
        if (apply_index >= end_index) return left;
        if (end_tag) |tag| {
            if (self.tokens[apply_index].tag == tag) return left;
        }
        if (!tokenStartsExpr(self.tokens[apply_index].tag)) return left;

        var func_index = apply_index;
        if (self.parseExpr(&func_index, end_index, 0, end_tag)) |func_expr| {
            if (func_expr.* == .func) {
                index.* = func_index;
                return self.allocExpr(.{
                    .value = .{ .apply = .{ .func = func_expr, .arg = left } },
                });
            }
        } else |err| switch (err) {
            error.UnexpectedEof,
            error.UnexpectedToken,
            error.ExpectedFunction,
            => {},
            else => return err,
        }

        var second_index = apply_index;
        const second_arg = try self.parsePrefix(&second_index, end_index, end_tag);
        if (second_arg.* != .value) return left;

        var func_start = second_index;
        self.skipWhitespace(&func_start, end_index);
        if (func_start >= end_index) return left;
        if (end_tag) |tag| {
            if (self.tokens[func_start].tag == tag) return left;
        }
        if (!tokenStartsExpr(self.tokens[func_start].tag)) return left;

        var final_index = func_start;
        const func_expr = self.parseExpr(&final_index, end_index, 0, end_tag) catch |err| switch (err) {
            error.UnexpectedEof,
            error.UnexpectedToken,
            error.ExpectedFunction,
            => return left,
            else => return err,
        };
        if (func_expr.* != .func) return left;

        const args = try self.allocExpr(.{
            .value = .{ .strand = .{ .left = left, .right = second_arg } },
        });
        index.* = final_index;
        return self.allocExpr(.{
            .value = .{ .apply = .{ .func = func_expr, .arg = args } },
        });
    }

    fn parsePrefix(self: *Parser, index: *usize, end_index: usize, end_tag: ?TokenTag) ParseError!*Expr {
        self.skipWhitespace(index, end_index);
        if (index.* >= end_index) return error.UnexpectedEof;

        const tok = self.tokens[index.*];
        index.* += 1;
        const slice = tok.lexeme;

        switch (tok.tag) {
            .number => {
                const val = try std.fmt.parseFloat(f64, slice);
                return self.allocExpr(.{
                    .value = .{ .literal = .{ .scalar = .{ .value = val, .is_char = false } } },
                });
            },
            .char_lit => {
                const ch = slice[1];
                return self.allocExpr(.{
                    .value = .{ .literal = .{ .scalar = .{ .value = @floatFromInt(ch), .is_char = true } } },
                });
            },
            .raw_string => {
                return self.allocExpr(.{
                    .value = .{ .literal = .{ .array = .{ .data = &.{}, .shape = &.{}, .is_char = true } } },
                });
            },
            .ident => {
                const name = tok.lexeme;
                if (try self.maybeParseArrowFunction(index, end_index, end_tag, name)) |arrow| {
                    return arrow;
                }
                if (self.isLocalParam(name)) {
                    return self.allocExpr(.{
                        .value = .{ .literal = .{ .ident = name } },
                    });
                }
                const sym = self.symbols.get(name) orelse return error.UnknownIdentifier;
                return sym.expr;
            },
            .lparen => {
                const body = try self.parseExpr(index, end_index, 0, .rparen);
                self.skipWhitespace(index, end_index);
                if (index.* >= end_index or self.tokens[index.*].tag != .rparen) {
                    return error.MissingRightParen;
                }
                index.* += 1;
                if (body.* != .func) return error.ExpectedFunction;
                return self.allocExpr(.{
                    .func = .{ .arity = .monad, .type = .{ .scope = &body.func } },
                });
            },
            .lbrace => {
                const body = try self.parseExpr(index, end_index, 0, .rbrace);
                self.skipWhitespace(index, end_index);
                if (index.* >= end_index or self.tokens[index.*].tag != .rbrace) {
                    return error.MissingRightBrace;
                }
                index.* += 1;
                if (body.* != .func) return error.ExpectedFunction;
                return self.allocExpr(.{
                    .func = .{ .arity = .dyad, .type = .{ .scope = &body.func } },
                });
            },
            .backslash => {
                const body = try self.parseExpr(index, end_index, 0, end_tag);
                if (body.* != .func) return error.ExpectedFunction;
                return self.allocExpr(.{
                    .func = .{ .arity = .monad, .type = .{ .scope = &body.func } },
                });
            },
            .dbl_backslash => {
                const body = try self.parseExpr(index, end_index, 0, end_tag);
                if (body.* != .func) return error.ExpectedFunction;
                return self.allocExpr(.{
                    .func = .{ .arity = .dyad, .type = .{ .scope = &body.func } },
                });
            },
            .slash => {
                const body = try self.parseExpr(index, end_index, 0, end_tag);
                if (body.* != .func) return error.ExpectedFunction;
                if (body.func.arity != .dyad) return error.ExpectedFunction;
                return self.allocExpr(.{
                    .func = .{ .arity = .monad, .type = .{ .reduce = &body.func } },
                });
            },
            else => return error.UnexpectedToken,
        }
    }

    fn skipWhitespace(self: *const Parser, index: *usize, end_index: usize) void {
        while (index.* < end_index and self.tokens[index.*].tag == .whitespace) : (index.* += 1) {}
    }

    fn maybeParseArrowFunction(
        self: *Parser,
        index: *usize,
        end_index: usize,
        end_tag: ?TokenTag,
        first_name: []const u8,
    ) ParseError!?*Expr {
        var lookahead = index.*;
        self.skipWhitespace(&lookahead, end_index);
        if (lookahead >= end_index) return null;
        if (end_tag) |tag| {
            if (self.tokens[lookahead].tag == tag) return null;
        }

        var second_name: ?[]const u8 = null;
        if (self.tokens[lookahead].tag == .ident) {
            second_name = self.tokens[lookahead].lexeme;
            lookahead += 1;
            self.skipWhitespace(&lookahead, end_index);
            if (lookahead >= end_index) return null;
            if (end_tag) |tag| {
                if (self.tokens[lookahead].tag == tag) return null;
            }
        }

        if (self.tokens[lookahead].tag != .arrow) return null;
        lookahead += 1;

        const param_start = self.local_params.items.len;
        errdefer self.local_params.items.len = param_start;
        try self.local_params.append(self.allocator, first_name);
        if (second_name) |name| {
            try self.local_params.append(self.allocator, name);
        }

        index.* = lookahead;
        const body = try self.parseExpr(index, end_index, 0, end_tag);
        self.local_params.items.len = param_start;

        return self.allocExpr(.{
            .func = .{
                .arity = if (second_name == null) .monad else .dyad,
                .type = .{ .userFn = .{ .left = first_name, .right = second_name, .body = body } },
            },
        });
    }

    fn isLocalParam(self: *const Parser, name: []const u8) bool {
        var i = self.local_params.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.local_params.items[i], name)) return true;
        }
        return false;
    }

    fn nextNonWhitespaceToken(self: *const Parser, index: *usize, end_index: usize) ?Token {
        self.skipWhitespace(index, end_index);
        if (index.* >= end_index) return null;
        const tok = self.tokens[index.*];
        index.* += 1;
        return tok;
    }

    fn buildInfix(self: *Parser, tok: Token, left: *Expr, right: *Expr) ParseError!*Expr {
        switch (tok.tag) {
            .comma => {
                const left_func = switch (left.*) {
                    .func => |f| f,
                    .value => return error.ExpectedFunction,
                };
                if (right.* != .value) return error.ExpectedValue;
                const arity: Arity = switch (left_func.arity) {
                    .dyad => .monad,
                    else => left_func.arity,
                };
                return self.allocExpr(.{
                    .func = .{ .arity = arity, .type = .{ .partial_apply = .{ .left = &left.func, .right = &right.value } } },
                });
            },
            .underscore => {
                return self.allocExpr(.{
                    .value = .{ .strand = .{ .left = left, .right = right } },
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
                const op = parseCombinator(tok) orelse return error.UnknownCombinator;
                return self.allocExpr(.{
                    .func = .{ .arity = arity, .type = .{ .combinator = .{ .op = op, .left = &left.func, .right = &right.func } } },
                });
            },
            .caret => {
                const left_func = switch (left.*) {
                    .func => |f| f,
                    .value => return error.ExpectedFunction,
                };
                if (right.* != .func) return error.ExpectedFunction;
                const arity: Arity = switch (left_func.arity) {
                    .dyad => .monad,
                    else => left_func.arity,
                };
                return self.allocExpr(.{
                    .func = .{ .arity = arity, .type = .{ .right_partial_apply = .{ .left = &left.func, .right = &right.func } } },
                });
            },
            else => return error.UnexpectedToken,
        }
    }

    fn allocExpr(self: *Parser, expr: Expr) ParseError!*Expr {
        const ptr = try self.allocator.create(Expr);
        ptr.* = expr;
        return ptr;
    }
};

const InfixInfo = struct { lbp: u8, rbp: u8 };

fn infixInfo(tag: TokenTag) ?InfixInfo {
    return switch (tag) {
        .comma => .{ .lbp = 90, .rbp = 91 },
        .underscore => .{ .lbp = 80, .rbp = 81 },
        .combinator => .{ .lbp = 60, .rbp = 61 },
        .caret => .{ .lbp = 55, .rbp = 56 },
        else => null,
    };
}

fn tokenStartsExpr(tag: TokenTag) bool {
    return switch (tag) {
        .number,
        .char_lit,
        .raw_string,
        .ident,
        .lparen,
        .lbrace,
        .backslash,
        .dbl_backslash,
        .slash,
        => true,
        else => false,
    };
}

fn parseCombinator(tok: Token) ?Combinator {
    const ident = tok.lexeme;
    const name = if (ident.len > 0 and (ident[0] == '(' or ident[0] == ')')) ident[1..] else ident;
    if (name.len == 0) return null;
    var out: [5]u8 = undefined;
    return std.meta.stringToEnum(Combinator, std.ascii.upperString(&out, name));
}

fn firstNonWhitespaceIndex(line: []const Token) ?usize {
    for (line, 0..) |tok, i| {
        if (tok.tag != .whitespace) return i;
    }
    return null;
}

fn isConstStart(line: []const Token, start_index: usize) bool {
    if (start_index >= line.len or line[start_index].tag != .ident) return false;

    var i = start_index + 1;
    while (i < line.len) : (i += 1) {
        const tok = line[i];
        if (tok.tag == .whitespace) continue;
        return tok.tag == .equal;
    }
    return false;
}

test "parse implicit reverse application with one argument" {
    const allocator = std.testing.allocator;
    const source = "1 sq";

    var lexed = try @import("lex.zig").lex(allocator, source);
    defer lexed.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(), source, lexed.tokens.items, lexed.line_offsets.items);
    defer parser.deinit();
    try parser.populateBuiltins();

    var index: usize = 0;
    const expr = try parser.parseExpr(&index, lexed.tokens.items.len, 0, null);

    try std.testing.expectEqual(@as(usize, lexed.tokens.items.len), index);
    try std.testing.expect(expr.* == .value);
    try std.testing.expect(expr.value == .apply);
    try std.testing.expect(expr.value.apply.arg.* == .value);
    try std.testing.expect(expr.value.apply.func.* == .func);
}

test "parse implicit reverse application with two arguments" {
    const allocator = std.testing.allocator;
    const source = "1 2 add";

    var lexed = try @import("lex.zig").lex(allocator, source);
    defer lexed.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(), source, lexed.tokens.items, lexed.line_offsets.items);
    defer parser.deinit();
    try parser.populateBuiltins();

    var index: usize = 0;
    const expr = try parser.parseExpr(&index, lexed.tokens.items.len, 0, null);

    try std.testing.expectEqual(@as(usize, lexed.tokens.items.len), index);
    try std.testing.expect(expr.* == .value);
    try std.testing.expect(expr.value == .apply);
    try std.testing.expect(expr.value.apply.arg.* == .value);
    try std.testing.expect(expr.value.apply.arg.value == .strand);
    try std.testing.expect(expr.value.apply.func.* == .func);
}

test "parse monadic arrow function with local parameter references" {
    const allocator = std.testing.allocator;
    const source = "x -> x sq";

    var lexed = try @import("lex.zig").lex(allocator, source);
    defer lexed.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(), source, lexed.tokens.items, lexed.line_offsets.items);
    defer parser.deinit();
    try parser.populateBuiltins();

    var index: usize = 0;
    const expr = try parser.parseExpr(&index, lexed.tokens.items.len, 0, null);

    try std.testing.expect(expr.* == .func);
    try std.testing.expectEqual(@as(Arity, .monad), expr.func.arity);
    const user_fn = expr.func.type.userFn;
    try std.testing.expectEqualStrings("x", user_fn.left);
    try std.testing.expect(user_fn.right == null);
}

test "parse slash reduce as monadic function" {
    const allocator = std.testing.allocator;
    const source = "/ add";

    var lexed = try @import("lex.zig").lex(allocator, source);
    defer lexed.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(), source, lexed.tokens.items, lexed.line_offsets.items);
    defer parser.deinit();
    try parser.populateBuiltins();

    var index: usize = 0;
    const expr = try parser.parseExpr(&index, lexed.tokens.items.len, 0, null);

    try std.testing.expect(expr.* == .func);
    try std.testing.expectEqual(@as(Arity, .monad), expr.func.arity);
    try std.testing.expect(expr.func.type == .reduce);
    try std.testing.expectEqual(@as(Arity, .dyad), expr.func.type.reduce.arity);
}
