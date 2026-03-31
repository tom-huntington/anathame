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

    // main function can't have new lines ATM
    const source =
        \\a = 2 sq
        \\add,3 )b1 sq
    ;
    std.debug.print("soure:\n{s}\n", .{source});

    var lexed = try lex.lex(allocator, source);
    stringprint.printfmt("tokens: {}\n", .{lexed.tokens});
    stringprint.printfmt("line_offsets: {}\n", .{lexed.line_offsets});

    defer lexed.deinit(allocator);

    var parser = parse.Parser.init(ast_alloc, source, lexed.tokens.items, lexed.line_offsets.items);
    defer parser.deinit();
    const file_ast: parse.FileAst = try parser.parseFile(ast_alloc);

    stringprint.printfmt("main: {}\n", .{file_ast.main});

    const args = [_]types.Value{
        .{ .scalar = .{ .value = 2, .is_char = false } },
        .{ .scalar = .{ .value = 3, .is_char = false } },
    };
    const result = switch (file_ast.main.arity) {
        .dyad => try eval.evalFunc(ast_alloc, file_ast.main, .{ .dyad = args }),
        .monad => try eval.evalFunc(ast_alloc, file_ast.main, .{ .monad = .{args[0]} }),
        .value => return error.ArityMismatch,
    };
    stringprint.printfmt("result: {}\n", .{result});
}
