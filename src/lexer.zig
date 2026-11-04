const std = @import("std");
pub const Lexer = struct {
    source: []const u8,
    offset: usize = 0,
    pub fn next(self: *Lexer) ?[]const u8 {
        while (self.offset < self.source.len and std.ascii.isWhitespace(self.source[self.offset])) self.offset += 1;
        if (self.offset == self.source.len) return null;
        const start = self.offset;
        const c = self.source[self.offset];
        self.offset += 1;
        if (c == '[' or c == ']') return self.source[start..self.offset];
        while (self.offset < self.source.len) : (self.offset += 1) {
            const b = self.source[self.offset];
            if (std.ascii.isWhitespace(b) or b == '[' or b == ']') break;
        }
        return self.source[start..self.offset];
    }
};
