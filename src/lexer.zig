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
        if (c == '$') {
            while (true) {
                while (self.offset < self.source.len and self.source[self.offset] != '\n' and self.source[self.offset] != '\r') self.offset += 1;
                const end = self.offset;
                var next_line = end;
                if (next_line < self.source.len and self.source[next_line] == '\r') next_line += 1;
                if (next_line == self.source.len or self.source[next_line] != '\n') return self.source[start..end];
                next_line += 1;
                while (next_line < self.source.len and (self.source[next_line] == ' ' or self.source[next_line] == '\t')) next_line += 1;
                if (next_line == self.source.len or self.source[next_line] != '$') return self.source[start..end];
                self.offset = next_line + 1;
            }
        }
        if (c == '|' and self.offset < self.source.len) {
            if (self.source[self.offset] == '>') {
                self.offset += 1;
            } else {
                while (self.offset < self.source.len and std.ascii.isAlphabetic(self.source[self.offset])) self.offset += 1;
            }
            return self.source[start..self.offset];
        }
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
        if (c == '\\') {
            if (self.offset < self.source.len and self.source[self.offset] == '\\') self.offset += 1;
            return self.source[start..self.offset];
        }
        if (std.mem.indexOfScalar(u8, "[],(){}_*", c) != null) return self.source[start..self.offset];
        while (self.offset < self.source.len) : (self.offset += 1) {
            const b = self.source[self.offset];
            if (b == '_' and (std.ascii.isAlphabetic(c) or c == '&')) continue;
            if (std.ascii.isWhitespace(b) or b == ';' or std.mem.indexOfScalar(u8, "[],(){}_*\\\"@$", b) != null or
                b == '|') break;
        }
        return self.source[start..self.offset];
    }
};
