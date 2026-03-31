const std = @import("std");
const quiver = @import("quiver");
const stringprint = @import("stringprint.zig");
const parse = @import("parse.zig");
const lex = @import("lex.zig");
const eval = @import("eval.zig");
const types = @import("types.zig");

pub const std_options: std.Options = .{
    .fmt_max_depth = 64, // Default is usually 16
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const ast_alloc = arena.allocator();

    const wrap = struct {
        v: []const u8,
    };
    const a = wrap{ .v = "hello" };
    stringprint.printfmt("a: {}\n", .{a});

    const source =
        \\a = 1_1
        \\c -> / add
    ;
    std.debug.print("soure:\n{s}\n", .{source});

    var lexed = try lex.lex(allocator, source);
    stringprint.printfmt("tokens: {}\n", .{lexed.tokens});
    stringprint.printfmt("line_offsets: {}\n", .{lexed.line_offsets});

    defer lexed.deinit(allocator);

    var parser = parse.Parser.init(ast_alloc, source, lexed.tokens.items, lexed.line_offsets.items);
    defer parser.deinit();
    var file_ast: parse.FileAst = try parser.parseFile(ast_alloc);
    try eval.foldFileConstants(ast_alloc, &file_ast);

    stringprint.printfmt("main: {}\n", .{file_ast.main});

    var arg0_data = [_]f64{ 2, 3 };
    var arg1_data = [_]f64{ 4, 5 };
    var arg_shape = [_]u32{2};
    const args = [_]types.Value{
        .{ .array = .{ .data = arg0_data[0..], .shape = arg_shape[0..], .is_char = false } },
        .{ .array = .{ .data = arg1_data[0..], .shape = arg_shape[0..], .is_char = false } },
    };
    const result = switch (file_ast.main.arity) {
        .dyad => try eval.evalFunc(ast_alloc, file_ast.main, .{ .dyad = args }),
        .monad => try eval.evalFunc(ast_alloc, file_ast.main, .{ .monad = .{args[0]} }),
        .value => return error.ArityMismatch,
    };
    stringprint.printfmt("result: {}\n", .{result});
}
