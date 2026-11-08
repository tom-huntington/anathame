const std = @import("std");
const language = @import("anathame");

pub fn expected_result(input: anytype, code: []const u8, expected: ?[]const u8, source: std.builtin.SourceLocation) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var memory = try language.ReservedBumpAllocator.init(64 * 1024 * 1024);
    defer memory.deinit();
    const source_input: []const u8 = if (comptime @typeInfo(@TypeOf(input)) == .@"struct") blk: {
        var arguments: [input.len][]const u8 = undefined;
        inline for (input, 0..) |argument, i| arguments[i] = argument;
        break :blk try std.mem.join(a, "\n; ", &arguments);
    } else input;
    const actual = try language.runtime.evaluate(&memory, code, source_input);
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
        language.console.init();
        var buffer: [4096]u8 = undefined;
        var stdout = std.Io.File.Writer.init(.stdout(), std.Io.Threaded.global_single_threaded.io(), &buffer);
        try stdout.interface.print("file {s}, test {s}\noutput:\n", .{ std.fs.path.basename(source.file), test_name });
        try language.console.write(&stdout.interface, output.written());
        try stdout.interface.writeByte('\n');
        try stdout.interface.flush();
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

/// Compare every alias with the first fully bound instruction tree.
pub fn test_aliases(aliases: []const []const u8) !void {
    for (aliases[1..]) |alias| {
        try test_alias(alias, aliases[0]);
    }
}
