const std = @import("std");
const eval = @import("eval.zig");
const lex = @import("lex.zig");
const parse = @import("parse.zig");
const types = @import("types.zig");
const ReservedBumpAllocator = @import("ReservedBumpAllocator").ReservedBumpAllocator;

fn bytesToArray(allocator: *ReservedBumpAllocator, bytes: []const u8) !types.Array {
    var meta = types.Array.initWithShape(allocator, &.{bytes.len});

    for (bytes, 0..) |byte, i| {
        meta.data[i] = @floatFromInt(byte);
    }

    return meta;
}

fn expectScalarResult(input: []const u8, source: []const u8, expected: f64) !void {
    var ast_alloc = try ReservedBumpAllocator.init(1024 * 1024);
    defer ast_alloc.deinit();
    var runtime_alloc = try ReservedBumpAllocator.init(1024 * 1024);
    defer runtime_alloc.deinit();

    const input_array = try bytesToArray(&runtime_alloc, input);

    var lexed = try lex.lex(&ast_alloc, source);
    defer lexed.deinit(&ast_alloc);

    var parser = parse.Parser.init(&ast_alloc, &runtime_alloc, source, lexed.tokens.items, lexed.line_offsets.items);
    defer parser.deinit();

    const file_ast = try parser.parseFile();
    const text_input: types.Value = .{ .array = input_array };

    var ctx = eval.EvalContext.init(&runtime_alloc);
    defer ctx.deinit();

    const result = switch (file_ast.main.arity) {
        1 => try eval.evalFunc(&ctx, null, file_ast.main, &.{text_input}),
        else => return error.ArityMismatch,
    };

    switch (result) {
        .scalar => |actual| try std.testing.expectEqual(expected, actual),
        else => return error.ExpectedScalar,
    }
}

test "aoc 2025 day 1 part a" {
    const input =
        \\L68
        \\L30
        \\R48
        \\L5
        \\R60
        \\L55
        \\L1
        \\L99
        \\R14
        \\L82
    ;
    const source =
        \\not_eq,@\n )s partition first
    ;
    _ = input;
    _ = source;
    // try expectScalarResult(input, source, 0);
}
