const std = @import("std");
const types = @import("types.zig");
const Token = types.Token;
const TokenTag = types.TokenTag;

pub const LexResult = struct {
    tokens: std.ArrayList(Token),
    line_offsets: std.ArrayList(u32),

    pub fn deinit(self: *LexResult, allocator: std.mem.Allocator) void {
        self.tokens.deinit(allocator);
        self.line_offsets.deinit(allocator);
    }
};

pub fn lex(allocator: std.mem.Allocator, source: []const u8) !LexResult {
    var tokens: std.ArrayList(Token) = .empty;
    errdefer tokens.deinit(allocator);

    var line_offsets: std.ArrayList(u32) = .empty;
    errdefer line_offsets.deinit(allocator);

    try line_offsets.append(allocator, 0);

    var it = std.mem.splitScalar(u8, source, '\n');
    var offset: usize = 0;
    while (it.next()) |line| {
        try lexLine(allocator, &tokens, line, offset);
        try line_offsets.append(allocator, @intCast(tokens.items.len));
        offset += line.len + 1;
    }

    return .{
        .tokens = tokens,
        .line_offsets = line_offsets,
    };
}

fn lexLine(allocator: std.mem.Allocator, tokens: *std.ArrayList(Token), line: []const u8, base: usize) !void {
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        if (std.ascii.isWhitespace(c)) {
            var j = i + 1;
            while (j < line.len and std.ascii.isWhitespace(line[j])) : (j += 1) {}
            try tokens.append(allocator, .{ .tag = .whitespace, .start = base + i, .end = base + j, .lexeme = line[i..j] });
            i = j;
            continue;
        }

        const start = base + i;

        switch (c) {
            ',' => {
                try tokens.append(allocator, .{ .tag = .comma, .start = start, .end = start + 1, .lexeme = line[i .. i + 1] });
                i += 1;
            },
            '-' => {
                if (i + 1 < line.len and line[i + 1] == '>') {
                    try tokens.append(allocator, .{ .tag = .arrow, .start = start, .end = start + 2, .lexeme = line[i .. i + 2] });
                    i += 2;
                } else {
                    return error.UnexpectedChar;
                }
            },
            '^' => {
                try tokens.append(allocator, .{ .tag = .caret, .start = start, .end = start + 1, .lexeme = line[i .. i + 1] });
                i += 1;
            },
            '_' => {
                try tokens.append(allocator, .{ .tag = .underscore, .start = start, .end = start + 1, .lexeme = line[i .. i + 1] });
                i += 1;
            },
            '(' => {
                if (i + 1 < line.len and std.ascii.isAlphabetic(line[i + 1])) {
                    var j = i + 1;
                    while (j < line.len and std.ascii.isAlphanumeric(line[j])) : (j += 1) {}
                    try tokens.append(allocator, .{ .tag = .combinator, .start = start, .end = base + j, .lexeme = line[i..j] });
                    i = j;
                } else {
                    try tokens.append(allocator, .{ .tag = .lparen, .start = start, .end = start + 1, .lexeme = line[i .. i + 1] });
                    i += 1;
                }
            },
            ')' => {
                // `)name` is a combinator token, not a closing-scope token followed by a combinator.
                if (i + 1 < line.len and std.ascii.isAlphabetic(line[i + 1])) {
                    var j = i + 1;
                    while (j < line.len and std.ascii.isAlphanumeric(line[j])) : (j += 1) {}
                    try tokens.append(allocator, .{ .tag = .combinator, .start = start, .end = base + j, .lexeme = line[i..j] });
                    i = j;
                } else {
                    try tokens.append(allocator, .{ .tag = .rparen, .start = start, .end = start + 1, .lexeme = line[i .. i + 1] });
                    i += 1;
                }
            },
            '{' => {
                try tokens.append(allocator, .{ .tag = .lbrace, .start = start, .end = start + 1, .lexeme = line[i .. i + 1] });
                i += 1;
            },
            '}' => {
                try tokens.append(allocator, .{ .tag = .rbrace, .start = start, .end = start + 1, .lexeme = line[i .. i + 1] });
                i += 1;
            },
            '\\' => {
                if (i + 1 < line.len and line[i + 1] == '\\') {
                    try tokens.append(allocator, .{ .tag = .dbl_backslash, .start = start, .end = start + 2, .lexeme = line[i .. i + 2] });
                    i += 2;
                } else {
                    try tokens.append(allocator, .{ .tag = .backslash, .start = start, .end = start + 1, .lexeme = line[i .. i + 1] });
                    i += 1;
                }
            },
            '/' => {
                try tokens.append(allocator, .{ .tag = .slash, .start = start, .end = start + 1, .lexeme = line[i .. i + 1] });
                i += 1;
            },
            '=' => {
                try tokens.append(allocator, .{ .tag = .equal, .start = start, .end = start + 1, .lexeme = line[i .. i + 1] });
                i += 1;
            },
            '$' => {
                // Raw string literal: consume rest of line.
                try tokens.append(allocator, .{ .tag = .raw_string, .start = start, .end = base + line.len, .lexeme = line[i..] });
                break;
            },
            '@' => {
                if (i + 1 >= line.len) return error.UnexpectedChar;
                try tokens.append(allocator, .{ .tag = .char_lit, .start = start, .end = start + 2, .lexeme = line[i .. i + 2] });
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
                    }
                    try tokens.append(allocator, .{ .tag = .number, .start = start, .end = base + j, .lexeme = line[i..j] });
                    i = j;
                } else if (std.ascii.isAlphabetic(c)) {
                    var j = i;
                    while (j < line.len and std.ascii.isAlphabetic(line[j])) : (j += 1) {}
                    try tokens.append(allocator, .{ .tag = .ident, .start = start, .end = base + j, .lexeme = line[i..j] });
                    i = j;
                } else {
                    return error.UnexpectedChar;
                }
            },
        }
    }
}

test "lex accepts integer and decimal numbers" {
    const allocator = std.testing.allocator;
    const source =
        \\a = 2
        \\b = 3.5
    ;

    var result = try lex(allocator, source);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 10), result.tokens.items.len);
    try std.testing.expectEqual(TokenTag.number, result.tokens.items[4].tag);
    try std.testing.expectEqualStrings("2", result.tokens.items[4].lexeme);
    try std.testing.expectEqual(TokenTag.number, result.tokens.items[9].tag);
    try std.testing.expectEqualStrings("3.5", result.tokens.items[9].lexeme);
}

test "lex recognizes arrow functions" {
    const allocator = std.testing.allocator;
    const source = "x -> x";

    var result = try lex(allocator, source);
    defer result.deinit(allocator);

    try std.testing.expectEqual(TokenTag.ident, result.tokens.items[0].tag);
    try std.testing.expectEqual(TokenTag.arrow, result.tokens.items[2].tag);
    try std.testing.expectEqual(TokenTag.ident, result.tokens.items[4].tag);
}

test "lex recognizes slash operator" {
    const allocator = std.testing.allocator;
    const source = "/ add";

    var result = try lex(allocator, source);
    defer result.deinit(allocator);

    try std.testing.expectEqual(TokenTag.slash, result.tokens.items[0].tag);
    try std.testing.expectEqualStrings("/", result.tokens.items[0].lexeme);
}
