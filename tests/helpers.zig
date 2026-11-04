const std = @import("std");
const language = @import("anathame");

pub fn expect_output(code: []const u8, input: anytype, expected: anytype) !void {
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

pub fn literal_eval(code: []const u8, expected: anytype) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const instructions = try language.parser.parse(a, code);
    if (instructions.len != 1 or instructions[0] != .literal) return error.ExpectedLiteral;
    const value = instructions[0].literal;
    try language.runtime.expectOutput(a, value.tuple orelse &.{value}, expected);
}
