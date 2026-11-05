const std = @import("std");
const language = @import("anathame");

pub fn expected_unary(input: []const u8, code: []const u8, expected: ?[]const u8, source: std.builtin.SourceLocation) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var memory = try language.ReservedBumpAllocator.init(64 * 1024 * 1024);
    defer memory.deinit();
    const actual = try language.runtime.evaluate(&memory, code, input);
    if (expected) |output| {
        try language.runtime.expectOutput(a, actual, output);
    } else {
        var output = std.Io.Writer.Allocating.init(a);
        for (actual, 0..) |value, i| {
            if (i > 0) try output.writer.writeAll("\n; ");
            try language.runtime.writeValue(&output.writer, value);
        }
        const test_name = if (std.mem.indexOf(u8, source.fn_name, "test.")) |index|
            source.fn_name[index + "test.".len ..]
        else
            source.fn_name;
        std.debug.print("file {s}, test {s}\noutput:\n{s}\n", .{ std.fs.path.basename(source.file), test_name, output.written() });
    }
}

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

/// Compare fully bound instruction trees, including pointed-to HOF operands.
pub fn test_alias(alias: []const u8, expansion: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const actual = try language.parser.parse(a, alias);
    const expected = try language.parser.parse(a, expansion);
    try std.testing.expectEqualDeep(expected, actual);
}

pub fn test_hof_alias(alias: []const u8, expansion: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Exercise both primitive and compound operands, including nested HOFs.
    for ([_][]const u8{ "add", "sub", "id", "{ sub abs }", "Reduce add" }) |operand| {
        try test_alias(try std.mem.concat(a, u8, &.{ alias, " ", operand }), try std.mem.concat(a, u8, &.{ expansion, " ", operand }));
    }
}
