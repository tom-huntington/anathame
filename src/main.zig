const std = @import("std");
const builtin = @import("builtin");
const quiver = @import("quiver");
const stringprint = @import("stringprint.zig");
const parse = @import("parse.zig");
const lex = @import("lex.zig");
const eval = @import("eval.zig");
const types = @import("types.zig");
const format = @import("format.zig");

fn bytesToArray(allocator: std.mem.Allocator, bytes: []const u8) !types.Array {
    const data = try allocator.alloc(f64, bytes.len);
    errdefer allocator.free(data);

    const shape = try allocator.alloc(u32, 1);
    errdefer allocator.free(shape);

    shape[0] = @intCast(bytes.len);
    for (bytes, 0..) |byte, i| {
        data[i] = @floatFromInt(byte);
    }

    return .{
        .data = data,
        .shape = shape,
        .is_char = true,
    };
}

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
    const input_array = try bytesToArray(ast_alloc, input);
    std.debug.print("input_array: {}\n", .{input_array});

    //std.debug.print("{f}", .{std.zig.fmtString(input)});
    const source =
        \\ strided,3,2
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
        .{ .array = input_array },
    };
    const result = switch (file_ast.main.arity) {
        2 => return error.ArityMismatch, //try eval.evalFunc(ast_alloc, file_ast.main, args[0..2]),
        1 => try eval.evalFunc(ast_alloc, file_ast.main, args[2..3]),
        else => return error.ArityMismatch,
    };
    const rendered = try format.valueString(ast_alloc, result);
    std.debug.print("{s}\n", .{rendered});
}
