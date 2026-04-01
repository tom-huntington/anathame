const std = @import("std");
const builtins = @import("builtins.zig");
const hofs = @import("hofs.zig");
const types = @import("types.zig");
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
    pointer: *const fn (std.mem.Allocator, []const Value, Expr.FuncExpr) Value,
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
} || std.fmt.ParseFloatError || std.fmt.ParseIntError || std.mem.Allocator.Error;

pub const Parser = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const Token,
    line_offsets: []const u32,
    symbols: std.StringHashMap(Symbol),
    hofs: std.StringHashMap(HofSymbol),
    local_params: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator, source: []const u8, tokens: []const Token, line_offsets: []const u32) Parser {
        const symbols = std.StringHashMap(Symbol).init(allocator);
        const registered_hofs = std.StringHashMap(HofSymbol).init(allocator);
        return .{
            .allocator = allocator,
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
        self.local_params.deinit(self.allocator);
    }

    pub fn parseFile(self: *Parser, allocator: std.mem.Allocator) ParseError!FileAst {
        try self.populateBuiltins();
        try self.populateHofs();

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

    pub fn populateHofs(self: *Parser) ParseError!void {
        inline for (hofs.symbols) |symbol| {
            const member = @field(hofs, symbol.name);
            const member_info = @typeInfo(@TypeOf(member));

            switch (member_info) {
                .@"fn" => {
                    const params = member_info.@"fn".params;
                    if (hofFromParams(params, member)) |hof| {
                        try self.hofs.put(symbol.lexeme, hof);
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
                if (body.func.arity != 2) return error.ExpectedFunction;
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
        try self.local_params.append(self.allocator, first_name);
        if (second_name) |name| {
            try self.local_params.append(self.allocator, name);
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
        defer values.deinit(self.allocator);
        var permutation_index: u32 = 0;
        var saw_suffix = false;

        while (true) {
            self.skipWhitespace(&suffix_index, end_index);
            if (suffix_index >= end_index) break;

            switch (self.tokens[suffix_index].tag) {
                .comma => {
                    suffix_index += 1;
                    try values.append(self.allocator, try self.parseIdentifierSuffixValue(&suffix_index, end_index));
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
        const arguments = try values.toOwnedSlice(self.allocator);
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
            .number => .{
                .literal = .{ .scalar = .{
                    .value = try std.fmt.parseFloat(f64, tok.lexeme),
                    .is_char = false,
                } },
            },
            .char_lit => .{
                .literal = .{ .scalar = .{
                    .value = @floatFromInt(tok.lexeme[1]),
                    .is_char = true,
                } },
            },
            .raw_string => .{
                .literal = .{ .array = .{
                    .data = &.{},
                    .shape = &.{},
                    .is_char = true,
                } },
            },
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

    fn buildInfix(self: *Parser, tok: Token, left: *Expr, right: *Expr) ParseError!*Expr {
        switch (tok.tag) {
            .comma => {
                return error.UnexpectedToken;
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
                const arity = if (left_func.arity == right_func.arity) left_func.arity else 2;
                const op = parseCombinator(tok) orelse return error.UnknownCombinator;
                return self.allocExpr(.{
                    .func = .{ .arity = arity, .type = .{ .combinator = .{ .op = op, .left = &left.func, .right = &right.func } } },
                });
            },
            .caret => return error.UnexpectedToken,
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
        .underscore => .{ .lbp = 80, .rbp = 81 },
        .combinator => .{ .lbp = 60, .rbp = 61 },
        else => null,
    };
}

fn builtinFromParams(comptime params: anytype, comptime member: anytype) ?Builtin {
    if (params.len != 2) return null;
    const args_type = params[1].type orelse return null;
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

fn makeBuiltinWrapper(comptime arity: u32, comptime member: anytype) *const fn (std.mem.Allocator, []const Value) Value {
    return &struct {
        fn call(allocator: std.mem.Allocator, args: []const Value) Value {
            std.debug.assert(args.len == arity);
            const typed_args: *const [arity]Value = @ptrCast(args.ptr);
            return member(allocator, @constCast(typed_args));
        }
    }.call;
}

fn hofFromParams(comptime params: anytype, comptime member: anytype) ?HofSymbol {
    if (params.len != 3) return null;
    if ((params[2].type orelse return null) != Expr.FuncExpr) return null;

    const args_type = params[1].type orelse return null;
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

fn makeHofWrapper(comptime arity: u32, comptime member: anytype) *const fn (std.mem.Allocator, []const Value, Expr.FuncExpr) Value {
    return &struct {
        fn call(allocator: std.mem.Allocator, args: []const Value, fn_arg: Expr.FuncExpr) Value {
            std.debug.assert(args.len == arity);
            const typed_args: *const [arity]Value = @ptrCast(args.ptr);
            return member(allocator, @constCast(typed_args), fn_arg);
        }
    }.call;
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
