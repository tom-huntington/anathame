const std = @import("std");
const hofs = @import("hofs.zig");
const types = @import("types.zig");
const ReservedBumpAllocator = @import("ReservedBumpAllocator").ReservedBumpAllocator; // ../vendor/ReservedBumpAllocator/root.zig
const Token = types.Token;
const TokenTag = types.TokenTag;

pub const LexResult = struct {
    tokens: std.ArrayList(Token),
    line_offsets: std.ArrayList(u32),

    pub fn deinit(self: *LexResult, allocator: *ReservedBumpAllocator) void {
        self.tokens.deinit(allocator.allocator());
        self.line_offsets.deinit(allocator.allocator());
    }
};

pub fn lex(allocator: *ReservedBumpAllocator, source: []const u8) !LexResult {
    var tokens: std.ArrayList(Token) = .empty;
    errdefer tokens.deinit(allocator.allocator());

    var line_offsets: std.ArrayList(u32) = .empty;
    errdefer line_offsets.deinit(allocator.allocator());

    try line_offsets.append(allocator.allocator(), 0);

    var it = std.mem.splitScalar(u8, source, '\n');
    var offset: usize = 0;
    while (it.next()) |line| {
        const has_newline = offset + line.len < source.len and source[offset + line.len] == '\n';
        const line_end = offset + line.len + @intFromBool(has_newline);
        const full_line = source[offset..line_end];
        try lexLine(allocator, &tokens, full_line, offset);
        try line_offsets.append(allocator.allocator(), @intCast(tokens.items.len));
        offset = line_end;
    }

    return .{
        .tokens = tokens,
        .line_offsets = line_offsets,
    };
}

fn lexLine(allocator: *ReservedBumpAllocator, tokens: *std.ArrayList(Token), line: []const u8, base: usize) !void {
    const alloc = allocator.allocator();
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        if (std.ascii.isWhitespace(c)) {
            var j = i + 1;
            while (j < line.len and std.ascii.isWhitespace(line[j])) : (j += 1) {}
            try tokens.append(alloc, .{ .tag = .whitespace, .start = base + i, .end = base + j, .lexeme = line[i..j] });
            i = j;
            continue;
        }

        const start = base + i;

        switch (c) {
            ',' => {
                try tokens.append(alloc, .{ .tag = .comma, .start = start, .end = start + 1, .lexeme = line[i .. i + 1] });
                i += 1;
            },
            '-' => {
                if (i + 1 < line.len and line[i + 1] == '>') {
                    try tokens.append(alloc, .{ .tag = .arrow, .start = start, .end = start + 2, .lexeme = line[i .. i + 2] });
                    i += 2;
                } else if (i + 1 < line.len and std.ascii.isDigit(line[i + 1])) {
                    const j = try scanNumber(line, i);
                    try tokens.append(alloc, .{ .tag = .number, .start = start, .end = base + j, .lexeme = line[i..j] });
                    i = j;
                } else {
                    return error.UnexpectedChar;
                }
            },
            '^' => {
                try tokens.append(alloc, .{ .tag = .caret, .start = start, .end = start + 1, .lexeme = line[i .. i + 1] });
                i += 1;
            },
            '_' => {
                try tokens.append(alloc, .{ .tag = .underscore, .start = start, .end = start + 1, .lexeme = line[i .. i + 1] });
                i += 1;
            },
            '(' => {
                try tokens.append(alloc, .{ .tag = .lparen, .start = start, .end = start + 1, .lexeme = line[i .. i + 1] });
                i += 1;
            },
            ')' => {
                try tokens.append(alloc, .{ .tag = .rparen, .start = start, .end = start + 1, .lexeme = line[i .. i + 1] });
                i += 1;
            },
            '|' => {
                if (i + 1 >= line.len or !std.ascii.isAlphabetic(line[i + 1])) return error.UnexpectedChar;
                var j = i + 1;
                while (j < line.len and std.ascii.isAlphanumeric(line[j])) : (j += 1) {}
                if (!isCombinatorLexeme(line[i..j])) return error.UnexpectedChar;
                try tokens.append(alloc, .{ .tag = .combinator, .start = start, .end = base + j, .lexeme = line[i..j] });
                i = j;
            },
            '{' => {
                try tokens.append(alloc, .{ .tag = .lbrace, .start = start, .end = start + 1, .lexeme = line[i .. i + 1] });
                i += 1;
            },
            '}' => {
                try tokens.append(alloc, .{ .tag = .rbrace, .start = start, .end = start + 1, .lexeme = line[i .. i + 1] });
                i += 1;
            },
            '[' => {
                try tokens.append(alloc, .{ .tag = .lbracket, .start = start, .end = start + 1, .lexeme = line[i .. i + 1] });
                i += 1;
            },
            ']' => {
                try tokens.append(alloc, .{ .tag = .rbracket, .start = start, .end = start + 1, .lexeme = line[i .. i + 1] });
                i += 1;
            },
            '\\' => {
                if (i + 1 < line.len and line[i + 1] == '\\') {
                    try tokens.append(alloc, .{ .tag = .dbl_backslash, .start = start, .end = start + 2, .lexeme = line[i .. i + 2] });
                    i += 2;
                } else {
                    try tokens.append(alloc, .{ .tag = .backslash, .start = start, .end = start + 1, .lexeme = line[i .. i + 1] });
                    i += 1;
                }
            },
            '=' => {
                try tokens.append(alloc, .{ .tag = .equal, .start = start, .end = start + 1, .lexeme = line[i .. i + 1] });
                i += 1;
            },
            '$' => {
                // Raw string literal: consume rest of line, excluding the line delimiter.
                const raw_end = if (line.len > i and line[line.len - 1] == '\n') line.len - 1 else line.len;
                try tokens.append(alloc, .{ .tag = .raw_string, .start = start, .end = base + raw_end, .lexeme = line[i..raw_end] });
                break;
            },
            '@' => {
                if (i + 1 >= line.len) return error.UnexpectedChar;
                const literal_len = try scanCharLiteral(line[i..]);
                try tokens.append(alloc, .{
                    .tag = .char_lit,
                    .start = start,
                    .end = start + literal_len,
                    .lexeme = line[i .. i + literal_len],
                });
                i += literal_len;
            },
            else => {
                if (std.ascii.isDigit(c)) {
                    const j = try scanNumber(line, i);
                    try tokens.append(alloc, .{ .tag = .number, .start = start, .end = base + j, .lexeme = line[i..j] });
                    i = j;
                } else if (std.ascii.isAlphabetic(c)) {
                    var j = i;
                    while (j < line.len and (std.ascii.isAlphanumeric(line[j]) or line[j] == '_')) : (j += 1) {}
                    const lexeme = line[i..j];
                    const tag: TokenTag = if (std.mem.eql(u8, lexeme, "Cases"))
                        .cases
                    else if (hofs.isHofName(lexeme))
                        .hof
                    else
                        .ident;
                    try tokens.append(alloc, .{ .tag = tag, .start = start, .end = base + j, .lexeme = lexeme });
                    i = j;
                } else {
                    return error.UnexpectedChar;
                }
            },
        }
    }
}

fn scanNumber(line: []const u8, start: usize) !usize {
    var j = start;
    if (line[j] == '-') j += 1;

    while (j < line.len and std.ascii.isDigit(line[j])) : (j += 1) {}
    if (j < line.len and line[j] == '.') {
        j += 1;
        if (j >= line.len or !std.ascii.isDigit(line[j])) return error.InvalidNumber;
        while (j < line.len and std.ascii.isDigit(line[j])) : (j += 1) {}
    }

    return j;
}

fn scanCharLiteral(text: []const u8) !usize {
    std.debug.assert(text.len > 0 and text[0] == '@');
    if (text.len < 2) return error.UnexpectedChar;

    if (text[1] == '\\') {
        if (text.len < 3) return error.UnexpectedChar;
        if (text[2] == 'x') {
            if (text.len < 5 or !std.ascii.isHex(text[3]) or !std.ascii.isHex(text[4])) {
                return error.UnexpectedChar;
            }
            return 5;
        }
        if (text[2] == 'u') {
            if (text.len < 5 or text[3] != '{') return error.UnexpectedChar;
            var j: usize = 4;
            while (j < text.len and text[j] != '}') : (j += 1) {
                if (!std.ascii.isHex(text[j])) return error.UnexpectedChar;
            }
            if (j >= text.len or j == 4) return error.UnexpectedChar;
            return j + 1;
        }
        return 3;
    }

    const scalar_len = try std.unicode.utf8ByteSequenceLength(text[1]);
    if (1 + scalar_len > text.len) return error.UnexpectedChar;
    return 1 + scalar_len;
}

fn isCombinatorLexeme(lexeme: []const u8) bool {
    const name = if (lexeme.len > 0 and lexeme[0] == '|') lexeme[1..] else lexeme;
    return types.Combinator.fromName(name) != null;
}
