const std = @import("std");
const builtin = @import("builtin");
const quiver = @import("quiver");
const stringprint = @import("stringprint.zig");
const parse = @import("parse.zig");
const lex = @import("lex.zig");
const eval = @import("eval.zig");
const types = @import("types.zig");
const format = @import("format.zig");

pub const std_options: std.Options = .{
    .fmt_max_depth = 64, // Default is usually 16
};

pub fn main() !void {
    if (builtin.os.tag == .windows) {
        _ = std.os.windows.kernel32.SetConsoleOutputCP(65001);
    }

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
        \\ table [1_2 3_4]
    ;
    std.debug.print("soure: {s}\n", .{source});

    var lexed = try lex.lex(allocator, source);
    stringprint.printfmt("tokens: {}\n", .{lexed.tokens});
    stringprint.printfmt("line_offsets: {}\n", .{lexed.line_offsets});

    defer lexed.deinit(allocator);

    var parser = parse.Parser.init(ast_alloc, source, lexed.tokens.items, lexed.line_offsets.items);
    defer parser.deinit();
    const file_ast: parse.FileAst = try parser.parseFile(ast_alloc);
    stringprint.printfmt("main: {}\n", .{file_ast.main});

    var arg0_data = [_]f64{ 1, 2 };
    var arg1_data = [_]f64{ 4, 5 };
    var arg_shape = [_]u32{8};
    const args = [_]types.Value{
        .{ .array = .{ .data = arg0_data[0..], .shape = arg_shape[0..], .is_char = false } },
        .{ .array = .{ .data = arg1_data[0..], .shape = arg_shape[0..], .is_char = false } },
    };
    const result = switch (file_ast.main.arity) {
        2 => try eval.evalFunc(ast_alloc, file_ast.main, args[0..2]),
        1 => try eval.evalFunc(ast_alloc, file_ast.main, args[0..1]),
        else => return error.ArityMismatch,
    };
    const rendered = try format.valueString(ast_alloc, result);
    std.debug.print("{s}\n", .{rendered});
}
