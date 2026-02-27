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
        try self.populateBuiltins();

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
                    .main = &main_expr.func,
                };
            }
        }
        return error.MissingMain;
    }

    pub fn populateBuiltins(self: *Parser) !void {
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
        const slice = tok.lexeme(self.parser.source);

        switch (tok.tag) {
            .number => {
                const val = try std.fmt.parseFloat(f64, slice);
                return self.parser.allocExpr(.{
                    .value = .{ .literal = .{ .scalar = .{ .value = val, .is_char = false } } },
                });
            },
            .char_lit => {
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
                    .func = .{ .arity = .monad, .type = .{ .scope = &body.func } },
                });
            },
            .lbrace => {
                const body = try self.parseExpr(0, .rbrace);
                if (self.index >= self.line.items.len or self.line.items[self.index].tag != .rbrace) {
                    return error.MissingRightBrace;
                }
                self.index += 1;
                return self.parser.allocExpr(.{
                    .func = .{ .arity = .dyad, .type = .{ .scope = &body.func } },
                });
            },
            .backslash => {
                const body = try self.parseExpr(0, end_tag);
                return self.parser.allocExpr(.{
                    .func = .{ .arity = .monad, .type = .{ .scope = &body.func } },
                });
            },
            .dbl_backslash => {
                const body = try self.parseExpr(0, end_tag);
                return self.parser.allocExpr(.{
                    .func = .{ .arity = .dyad, .type = .{ .scope = &body.func } },
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
                    .func = .{ .arity = left_func.arity, .type = .{ .partial_apply = .{ .op = .comma, .left = &left.func, .right = &right.func } } },
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
                    .func = .{ .arity = arity, .type = .{ .combinator = .{ .op = op, .left = &left.func, .right = &right.func } } },
                });
            },
            .caret => {
                const left_func = switch (left.*) {
                    .func => |f| f,
                    .value => return error.ExpectedFunction,
                };
                return self.parser.allocExpr(.{
                    .func = .{ .arity = left_func.arity, .type = .{ .partial_apply = .{ .op = .caret, .left = &left.func, .right = &right.func } } },
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
    const name = if (ident.len > 0 and (ident[0] == '(' or ident[0] == ')')) ident[1..] else ident;
    if (name.len == 0) return null;
    var out: [5]u8 = undefined;
    return std.meta.stringToEnum(Combinator, std.ascii.upperString(&out, name));
}
