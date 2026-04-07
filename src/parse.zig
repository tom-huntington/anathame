const std = @import("std");
const builtins = @import("builtins.zig");
const hofs = @import("hofs.zig");
const types = @import("types.zig");
const ReservedBumpAllocator = @import("ReservedBumpAllocator").ReservedBumpAllocator; // ../vendor/ReservedBumpAllocator/root.zig
const Token = types.Token;
const Value = types.Value;
const Expr = types.Expr;
const TokenTag = types.TokenTag;
const Combinator = types.Combinator;
const Builtin = types.Builtin;
const Hof = types.Hof;

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

const HofSymbol = struct {
    arity: u32,
    pointer: *const fn (*ReservedBumpAllocator, ?[]f64, []const Value, Expr.FuncExpr) Value,
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
    MissingRightBracket,
    UnexpectedToken,
    ExpectedFunction,
    ExpectedValue,
    UnknownCombinator,
    MissingMain,
    MainMustBeFunction,
    InvalidConst,
    InvalidCharacterLiteral,
    OutOfMemory,
} || std.fmt.ParseFloatError || std.fmt.ParseIntError;

pub const Parser = struct {
    allocator: *ReservedBumpAllocator,
    value_allocator: *ReservedBumpAllocator,
    source: []const u8,
    tokens: []const Token,
    line_offsets: []const u32,
    symbols: std.StringHashMap(Symbol),
    hofs: std.StringHashMap(HofSymbol),
    local_params: std.ArrayList([]const u8),

    pub fn init(
        allocator: *ReservedBumpAllocator,
        value_allocator: *ReservedBumpAllocator,
        source: []const u8,
        tokens: []const Token,
        line_offsets: []const u32,
    ) Parser {
        const alloc = allocator.allocator();
        const symbols = std.StringHashMap(Symbol).init(alloc);
        const registered_hofs = std.StringHashMap(HofSymbol).init(alloc);
        return .{
            .allocator = allocator,
            .value_allocator = value_allocator,
            .source = source,
            .tokens = tokens,
            .line_offsets = line_offsets,
            .symbols = symbols,
            .hofs = registered_hofs,
            .local_params = .empty,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.symbols.deinit();
        self.hofs.deinit();
        self.local_params.deinit(self.allocator.allocator());
    }

    pub fn parseFile(self: *Parser) ParseError!FileAst {
        try self.populateBuiltins();
        try self.populateHofs();

        var consts: std.ArrayList(ConstDef) = .empty;
        errdefer consts.deinit(self.allocator.allocator());

        var statements = try self.collectStatements(self.allocator);
        defer statements.deinit(self.allocator.allocator());

        if (statements.items.len == 0) return error.MissingMain;

        const main_stmt = statements.items[statements.items.len - 1];
        if (main_stmt.kind != .expr) return error.MissingMain;

        for (statements.items[0 .. statements.items.len - 1]) |stmt| {
            if (stmt.kind != .const_def) return error.InvalidConst;
            const const_def = try self.parseConst(stmt);
            try consts.append(self.allocator.allocator(), const_def);
        }

        var main_index = main_stmt.start;
        const main_expr = try self.parseExpr(&main_index, main_stmt.end, 0, null);
        self.skipWhitespace(&main_index, main_stmt.end);
        if (main_index != main_stmt.end) return error.UnexpectedToken;
        if (main_expr.* != .func) return error.MainMustBeFunction;

        return .{
            .consts = try consts.toOwnedSlice(self.allocator.allocator()),
            .main = &main_expr.func,
        };
    }

    pub fn populateHofs(self: *Parser) ParseError!void {
        inline for (@typeInfo(hofs).@"struct".decls) |decl| {
            const member = @field(hofs, decl.name);
            const member_info = @typeInfo(@TypeOf(member));

            switch (member_info) {
                .@"fn" => {
                    const params = member_info.@"fn".params;
                    if (hofFromParams(params, member)) |hof| {
                        try self.hofs.put(decl.name, hof);
                    }
                },
                else => {},
            }
        }
    }

    pub fn populateBuiltins(self: *Parser) ParseError!void {
        inline for (@typeInfo(builtins).@"struct".decls) |decl| {
            const member = @field(builtins, decl.name);
            const member_info = @typeInfo(@TypeOf(member));

            switch (member_info) {
                .@"fn" => {
                    const params = member_info.@"fn".params;
                    if (builtinFromParams(params, member)) |builtin| {
                        const expr = try self.allocExpr(.{
                            .func = .{ .arity = builtin.arity, .type = .{ .builtin = builtin } },
                        });
                        try self.symbols.put(decl.name, .{ .expr = expr });
                    }
                },
                else => {},
            }
        }
    }

    fn collectStatements(self: *Parser, allocator: *ReservedBumpAllocator) ParseError!std.ArrayList(Statement) {
        var statements: std.ArrayList(Statement) = .empty;
        errdefer statements.deinit(allocator.allocator());

        var pending_expr_start: ?usize = null;

        for (0..self.lineCount()) |line_index| {
            const line = self.lineTokens(line_index);
            const line_start = firstNonWhitespaceIndex(line) orelse continue;
            const global_start = @as(usize, self.line_offsets[line_index]) + line_start;
            const kind = if (isConstStart(line, line_start)) StatementKind.const_def else StatementKind.expr;

            switch (kind) {
                .const_def => {
                    if (pending_expr_start) |_| return error.InvalidConst;
                    try statements.append(allocator.allocator(), .{
                        .kind = .const_def,
                        .start = global_start,
                        .end = self.tokens.len,
                    });
                },
                .expr => {
                    if (pending_expr_start == null) {
                        pending_expr_start = global_start;
                        try statements.append(allocator.allocator(), .{
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

            if (tok.tag == .combinator) {
                left = try self.parseCombinatorInfix(tok, left, index, end_index, end_tag);
                continue;
            }

            const right = try self.parseExpr(index, end_index, op_info.rbp, end_tag);
            left = try self.buildInfix(tok, left, right);
        }

        left = try self.maybeParseImplicitApply(index, end_index, end_tag, left);
        return left;
    }

    fn parseCombinatorInfix(
        self: *Parser,
        tok: Token,
        left: *Expr,
        index: *usize,
        end_index: usize,
        end_tag: ?TokenTag,
    ) ParseError!*Expr {
        if (left.* != .func) return error.ExpectedFunction;

        const op = parseCombinator(tok) orelse return error.UnknownCombinator;
        var remaining_args: std.ArrayList(*Expr.FuncExpr) = .empty;
        errdefer remaining_args.deinit(self.allocator.allocator());

        const first_remaining = try self.parseExpr(index, end_index, infixInfo(.combinator).?.rbp, end_tag);
        if (first_remaining.* != .func) return error.ExpectedFunction;
        try remaining_args.append(self.allocator.allocator(), &first_remaining.func);

        while (true) {
            self.skipWhitespace(index, end_index);
            if (index.* >= end_index) break;

            const next = self.tokens[index.*];
            if (end_tag) |tag| {
                if (next.tag == tag) break;
            }
            if (next.tag == .combinator) break;
            if (!tokenStartsExpr(next.tag)) break;

            const arg = try self.parseExpr(index, end_index, infixInfo(.combinator).?.rbp, end_tag);
            if (arg.* != .func) return error.ExpectedFunction;
            try remaining_args.append(self.allocator.allocator(), &arg.func);
        }

        return self.allocCombinatorExpr(op, &left.func, try remaining_args.toOwnedSlice(self.allocator.allocator()));
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

        switch (tok.tag) {
            .number,
            .char_lit,
            .raw_string,
            .lbracket,
            => return self.parseLiteralExpr(tok, index, end_index),
            .table => return self.parseTableExpr(index, end_index),
            .ident => {
                const name = tok.lexeme;
                if (try self.maybeParseArrowFunction(index, end_index, end_tag, name)) |arrow| {
                    return arrow;
                }
                if (self.isLocalParam(name)) {
                    return self.allocExpr(.{
                        .value = .{ .ident = name },
                    });
                }
                const sym = self.symbols.get(name) orelse return error.UnknownIdentifier;
                return try self.maybeParseIdentifierSuffixes(index, end_index, sym.expr);
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
                    .func = .{ .arity = 1, .type = .{ .scope = &body.func } },
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
                    .func = .{ .arity = 2, .type = .{ .scope = &body.func } },
                });
            },
            .backslash => {
                const body = try self.parseExpr(index, end_index, 0, end_tag);
                if (body.* != .func) return error.ExpectedFunction;
                return self.allocExpr(.{
                    .func = .{ .arity = 1, .type = .{ .scope = &body.func } },
                });
            },
            .dbl_backslash => {
                const body = try self.parseExpr(index, end_index, 0, end_tag);
                if (body.* != .func) return error.ExpectedFunction;
                return self.allocExpr(.{
                    .func = .{ .arity = 2, .type = .{ .scope = &body.func } },
                });
            },
            .hof => {
                const hof = self.hofs.get(tok.lexeme) orelse return error.UnexpectedToken;
                const body = try self.parseExpr(index, end_index, 0, end_tag);
                if (body.* != .func) return error.ExpectedFunction;
                //if (body.func.arity != 2) return error.ExpectedFunction;
                return self.allocExpr(.{
                    .func = .{ .arity = hof.arity, .type = .{ .hof = .{
                        .arity = hof.arity,
                        .funcArg = &body.func,
                        .pointer = hof.pointer,
                    } } },
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
        try self.local_params.append(self.allocator.allocator(), first_name);
        if (second_name) |name| {
            try self.local_params.append(self.allocator.allocator(), name);
        }

        index.* = lookahead;
        const body = try self.parseExpr(index, end_index, 0, end_tag);
        self.local_params.items.len = param_start;

        return self.allocExpr(.{
            .func = .{
                .arity = if (second_name == null) 1 else 2,
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

    fn maybeParseIdentifierSuffixes(
        self: *Parser,
        index: *usize,
        end_index: usize,
        expr: *Expr,
    ) ParseError!*Expr {
        var suffix_index = index.*;
        var values: std.ArrayList(Expr.ValueExpr) = .empty;
        defer values.deinit(self.allocator.allocator());
        var permutation_index: u32 = 0;
        var saw_suffix = false;

        while (true) {
            self.skipWhitespace(&suffix_index, end_index);
            if (suffix_index >= end_index) break;

            switch (self.tokens[suffix_index].tag) {
                .comma => {
                    suffix_index += 1;
                    try values.append(self.allocator.allocator(), try self.parseIdentifierSuffixValue(&suffix_index, end_index));
                    saw_suffix = true;
                },
                .caret => {
                    suffix_index += 1;
                    permutation_index = try self.parsePermutationIndex(&suffix_index, end_index);
                    saw_suffix = true;
                },
                else => break,
            }
        }

        if (!saw_suffix) return expr;
        if (expr.* != .func) return error.ExpectedFunction;

        index.* = suffix_index;
        const arguments = try values.toOwnedSlice(self.allocator.allocator());
        const arity = if (expr.func.arity > arguments.len) expr.func.arity - @as(u32, @intCast(arguments.len)) else expr.func.arity;
        return self.allocExpr(.{
            .func = .{ .arity = arity, .type = .{ .partial_apply_permute = .{
                .func = &expr.func,
                .arguments = arguments,
                .permutation_index = permutation_index,
            } } },
        });
    }

    fn parseIdentifierSuffixValue(self: *Parser, index: *usize, end_index: usize) ParseError!Expr.ValueExpr {
        self.skipWhitespace(index, end_index);
        if (index.* >= end_index) return error.UnexpectedEof;

        const tok = self.tokens[index.*];
        index.* += 1;

        return switch (tok.tag) {
            .number,
            .char_lit,
            .raw_string,
            .lbracket,
            => .{ .literal = try self.parseLiteralValue(tok, index, end_index) },
            .ident => blk: {
                if (self.isLocalParam(tok.lexeme)) {
                    break :blk .{ .ident = tok.lexeme };
                }

                const sym = self.symbols.get(tok.lexeme) orelse return error.UnknownIdentifier;
                if (sym.expr.* != .value) return error.ExpectedValue;
                break :blk sym.expr.value;
            },
            else => error.ExpectedValue,
        };
    }

    fn parsePermutationIndex(self: *const Parser, index: *usize, end_index: usize) ParseError!u32 {
        self.skipWhitespace(index, end_index);
        if (index.* >= end_index) return error.UnexpectedEof;

        const tok = self.tokens[index.*];
        if (tok.tag != .number) return error.ExpectedValue;
        if (std.mem.indexOfScalar(u8, tok.lexeme, '.')) |_| return error.ExpectedValue;

        index.* += 1;
        return try std.fmt.parseInt(u32, tok.lexeme, 10);
    }

    fn nextNonWhitespaceToken(self: *const Parser, index: *usize, end_index: usize) ?Token {
        self.skipWhitespace(index, end_index);
        if (index.* >= end_index) return null;
        const tok = self.tokens[index.*];
        index.* += 1;
        return tok;
    }

    fn parseLiteralExpr(self: *Parser, first_tok: Token, index: *usize, end_index: usize) ParseError!*Expr {
        return self.allocExpr(.{
            .value = .{ .literal = try self.parseLiteralValue(first_tok, index, end_index) },
        });
    }

    fn parseTableExpr(self: *Parser, index: *usize, end_index: usize) ParseError!*Expr {
        const lookup_tok = self.nextNonWhitespaceToken(index, end_index) orelse return error.UnexpectedEof;
        if (lookup_tok.tag != .lbracket) return error.UnexpectedToken;

        const lookup_value = try self.parseLiteralValue(lookup_tok, index, end_index);
        const lookup = switch (lookup_value) {
            .array => |array| array,
            .scalar => return error.UnexpectedToken,
        };

        return self.allocExpr(.{
            .func = .{
                .arity = 1,
                .type = .{ .table = .{
                    .lookup = lookup,
                    .unmatched = .Error,
                } },
            },
        });
    }

    fn parseLiteralValue(self: *Parser, first_tok: Token, index: *usize, end_index: usize) ParseError!Value {
        var items: std.ArrayList(Value) = .empty;
        defer items.deinit(self.allocator.allocator());

        try items.append(self.allocator.allocator(), try self.parseLiteralAtomValue(first_tok, index, end_index));

        while (true) {
            var lookahead = index.*;
            self.skipWhitespace(&lookahead, end_index);
            if (lookahead >= end_index or self.tokens[lookahead].tag != .underscore) break;

            lookahead += 1;
            self.skipWhitespace(&lookahead, end_index);
            if (lookahead >= end_index) return error.UnexpectedEof;
            if (!tokenStartsLiteral(self.tokens[lookahead].tag)) return error.UnexpectedToken;

            const next_tok = self.tokens[lookahead];
            lookahead += 1;
            try items.append(self.allocator.allocator(), try self.parseLiteralAtomValue(next_tok, &lookahead, end_index));
            index.* = lookahead;
        }

        if (items.items.len == 1) return items.items[0];
        return try self.materializeLiteralArray(items.items);
    }

    fn parseLiteralAtomValue(self: *Parser, tok: Token, index: *usize, end_index: usize) ParseError!Value {
        return switch (tok.tag) {
            .number => .{ .scalar = try std.fmt.parseFloat(f64, tok.lexeme) },
            .char_lit => .{ .scalar = @floatFromInt(try parseCharToken(tok.lexeme)) },
            .raw_string => try self.parseRawStringValue(tok.lexeme),
            .lbracket => try self.parseBracketLiteralValue(index, end_index),
            else => error.ExpectedValue,
        };
    }

    fn parseBracketLiteralValue(self: *Parser, index: *usize, end_index: usize) ParseError!Value {
        var rows: std.ArrayList(Value) = .empty;
        defer rows.deinit(self.allocator.allocator());

        while (true) {
            self.skipWhitespace(index, end_index);
            if (index.* >= end_index) return error.MissingRightBracket;
            if (self.tokens[index.*].tag == .rbracket) {
                index.* += 1;
                break;
            }

            const row_tok = self.tokens[index.*];
            if (!tokenStartsLiteral(row_tok.tag) or row_tok.tag == .lbracket) return error.UnexpectedToken;

            index.* += 1;
            try rows.append(self.allocator.allocator(), try self.parseLiteralValue(row_tok, index, end_index));
        }

        if (rows.items.len == 0) {
            const data = try self.value_allocator.allocator().alloc(f64, 0);
            const meta = types.Array.initWithShape(self.value_allocator, &.{ 0, 0 });
            meta.data = data;
            return .{ .array = meta };
        }

        return try self.materializeLiteralArray(rows.items);
    }

    fn materializeLiteralArray(self: *Parser, items: []const Value) ParseError!Value {
        if (items.len == 0) return error.ExpectedValue;

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
                    if (first_shape.len != 0) return error.UnexpectedToken;
                },
                .array => |array| {
                    if (!std.mem.eql(usize, first_shape, array.shape)) return error.UnexpectedToken;
                    if (array.data.len != elem_len) return error.UnexpectedToken;
                },
            }
        }

        const data = try self.value_allocator.allocator().alloc(f64, items.len * elem_len);
        const shape = try self.value_allocator.allocator().alloc(usize, first_shape.len + 1);
        shape[0] = items.len;
        @memcpy(shape[1..], first_shape);
        const meta = types.Array.initWithShape(self.value_allocator, shape);

        var data_index: usize = 0;
        for (items) |item| {
            switch (item) {
                .scalar => |scalar| {
                    data[data_index] = scalar;
                    data_index += 1;
                },
                .array => |array| {
                    @memcpy(data[data_index .. data_index + array.data.len], array.data);
                    data_index += array.data.len;
                },
            }
        }

        meta.data = data;
        return .{ .array = meta };
    }

    fn parseRawStringValue(self: *Parser, lexeme: []const u8) ParseError!Value {
        const bytes = if (lexeme.len > 0) lexeme[1..] else lexeme;
        const data = try self.value_allocator.allocator().alloc(f64, bytes.len);
        const meta = types.Array.initWithShape(self.value_allocator, &.{bytes.len});
        for (bytes, 0..) |byte, i| {
            data[i] = @floatFromInt(byte);
        }
        meta.data = data;
        return .{ .array = meta };
    }

    fn buildInfix(self: *Parser, tok: Token, left: *Expr, right: *Expr) ParseError!*Expr {
        _ = self;
        _ = left;
        _ = right;
        switch (tok.tag) {
            .comma => {
                return error.UnexpectedToken;
            },
            .combinator => return error.UnexpectedToken,
            .caret => return error.UnexpectedToken,
            else => return error.UnexpectedToken,
        }
    }

    fn parseCharToken(tok: []const u8) ParseError!u21 {
        if (tok.len < 2 or tok[0] != '@') return error.InvalidCharacterLiteral;

        var buf: [16]u8 = undefined;
        if (tok.len + 1 > buf.len) return error.InvalidCharacterLiteral;

        buf[0] = '\'';
        @memcpy(buf[1 .. 1 + tok.len - 1], tok[1..]);
        buf[tok.len] = '\'';

        return switch (std.zig.parseCharLiteral(buf[0 .. tok.len + 1])) {
            .success => |codepoint| codepoint,
            .failure => error.InvalidCharacterLiteral,
        };
    }

    fn allocCombinatorExpr(self: *Parser, op: Combinator, first_arg: *Expr.FuncExpr, remaining_args: []*Expr.FuncExpr) ParseError!*Expr {
        return self.allocExpr(.{
            .func = .{ .arity = op.arity(), .type = .{ .combinator = .{
                .op = op,
                .first_arg = first_arg,
                .remaining_args = remaining_args,
            } } },
        });
    }

    fn allocExpr(self: *Parser, expr: Expr) ParseError!*Expr {
        const ptr = try self.allocator.allocator().create(Expr);
        ptr.* = expr;
        return ptr;
    }
};

const InfixInfo = struct { lbp: u8, rbp: u8 };

fn infixInfo(tag: TokenTag) ?InfixInfo {
    return switch (tag) {
        .combinator => .{ .lbp = 60, .rbp = 61 },
        else => null,
    };
}

fn builtinFromParams(comptime params: anytype, comptime member: anytype) ?Builtin {
    if (params.len != 3) return null;
    if ((params[1].type orelse return null) != ?[]f64) return null;

    const args_type = params[2].type orelse return null;
    const args_info = @typeInfo(args_type);
    if (args_info != .pointer) return null;
    if (args_info.pointer.size != .one) return null;
    const child_info = @typeInfo(args_info.pointer.child);
    if (child_info != .array) return null;
    if (child_info.array.child != Value) return null;

    const arity: u32 = @intCast(child_info.array.len);
    return .{
        .arity = arity,
        .pointer = makeBuiltinWrapper(arity, member),
    };
}

fn makeBuiltinWrapper(comptime arity: u32, comptime member: anytype) *const fn (*ReservedBumpAllocator, ?[]f64, []const Value) Value {
    return &struct {
        fn call(allocator: *ReservedBumpAllocator, result_dest: ?[]f64, args: []const Value) Value {
            std.debug.assert(args.len == arity);
            const typed_args: *const [arity]Value = @ptrCast(args.ptr);
            return member(allocator, result_dest, @constCast(typed_args));
        }
    }.call;
}

fn hofFromParams(comptime params: anytype, comptime member: anytype) ?HofSymbol {
    if (params.len != 4) return null;
    if ((params[1].type orelse return null) != ?[]f64) return null;
    if ((params[3].type orelse return null) != Expr.FuncExpr) return null;

    const args_type = params[2].type orelse return null;
    const args_info = @typeInfo(args_type);
    if (args_info != .pointer) return null;
    if (args_info.pointer.size != .one) return null;

    const child_info = @typeInfo(args_info.pointer.child);
    if (child_info != .array) return null;
    if (child_info.array.child != Value) return null;

    const arity: u32 = @intCast(child_info.array.len);
    return .{
        .arity = arity,
        .pointer = makeHofWrapper(arity, member),
    };
}

fn makeHofWrapper(comptime arity: u32, comptime member: anytype) *const fn (*ReservedBumpAllocator, ?[]f64, []const Value, Expr.FuncExpr) Value {
    return &struct {
        fn call(allocator: *ReservedBumpAllocator, result_dest: ?[]f64, args: []const Value, fn_arg: Expr.FuncExpr) Value {
            std.debug.assert(args.len == arity);
            const typed_args: *const [arity]Value = @ptrCast(args.ptr);
            return member(allocator, result_dest, @constCast(typed_args), fn_arg);
        }
    }.call;
}

fn tokenStartsExpr(tag: TokenTag) bool {
    return switch (tag) {
        .number,
        .char_lit,
        .raw_string,
        .ident,
        .table,
        .lparen,
        .lbrace,
        .lbracket,
        .backslash,
        .dbl_backslash,
        .hof,
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

fn tokenStartsLiteral(tag: TokenTag) bool {
    return switch (tag) {
        .number,
        .char_lit,
        .raw_string,
        .lbracket,
        => true,
        else => false,
    };
}
