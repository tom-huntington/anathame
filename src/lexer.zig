const std = @import("std");
pub const Lexer = struct {
    source: []const u8,
    offset: usize = 0,
    pub fn next(self: *Lexer) !?[]const u8 {
        while (self.offset < self.source.len and (std.ascii.isWhitespace(self.source[self.offset]) or self.source[self.offset] == ';')) self.offset += 1;
        if (self.offset == self.source.len) return null;
        const start = self.offset;
        const c = self.source[self.offset];
        self.offset += 1;
        if (c == '"' or c == '@') {
            while (self.offset < self.source.len) {
                const b = self.source[self.offset];
                self.offset += 1;
                if (c == '"' and b == '"') return self.source[start..self.offset];
                if (b == '\\') {
                    if (self.offset == self.source.len) return error.InvalidEscape;
                    const escaped = self.source[self.offset];
                    self.offset += 1;
                    if (escaped == 'u' and self.offset < self.source.len and self.source[self.offset] == '{') {
                        while (self.offset < self.source.len and self.source[self.offset] != '}') self.offset += 1;
                        if (self.offset == self.source.len) return error.InvalidEscape;
                        self.offset += 1;
                    }
                } else if (c == '@') {
                    const len = try std.unicode.utf8ByteSequenceLength(b);
                    if (self.offset - 1 + len > self.source.len) return error.InvalidCharacterLiteral;
                    self.offset += len - 1;
                }
                if (c == '@') return self.source[start..self.offset];
            }
            return error.UnclosedLiteral;
        }
        if (c == '[' or c == ']') return self.source[start..self.offset];
        while (self.offset < self.source.len) : (self.offset += 1) {
            const b = self.source[self.offset];
            if (std.ascii.isWhitespace(b) or b == ';' or b == '[' or b == ']' or b == '"' or b == '@') break;
        }
        return self.source[start..self.offset];
    }
};
