const std = @import("std");
const language = @import("anathame");

pub fn expect_output(code: []const u8, input: []const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try language.runtime.expect_output(a, code, input, expected);
}

pub fn invalid_syntax(code: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = language.parser.parseProgram(arena.allocator(), code) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    return error.ExpectedInvalidSyntax;
}
