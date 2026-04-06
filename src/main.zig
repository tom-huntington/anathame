const std = @import("std");
const builtin = @import("builtin");
const anathame = @import("anathame");
const stringprint = @import("stringprint.zig");
const parse = @import("parse.zig");
const lex = @import("lex.zig");
const eval = @import("eval.zig");
const types = @import("types.zig");
const format = @import("format.zig");
const ReservedBumpAllocator = @import("ReservedBumpAllocator").ReservedBumpAllocator;

fn bytesToArray(allocator: *ReservedBumpAllocator, bytes: []const u8) !*types.Array {
    const data = try allocator.allocator().alloc(f64, bytes.len);
    const meta = types.Array.initWithShape(allocator, .Exclusive, &.{bytes.len});

    for (bytes, 0..) |byte, i| {
        data[i] = @floatFromInt(byte);
    }

    meta.data = data;
    return meta;
}

pub const std_options: std.Options = .{
    .fmt_max_depth = 64, // Default is usually 16
};

pub fn main() !void {
    if (builtin.os.tag == .windows) {
        _ = std.os.windows.kernel32.SetConsoleOutputCP(65001);
    }

    var ast_alloc = try ReservedBumpAllocator.init(1024 * 1024);
    defer ast_alloc.deinit();
    var runtime_alloc = try ReservedBumpAllocator.init(1024 * 1024);
    defer runtime_alloc.deinit();

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
    const input_array = try bytesToArray(&runtime_alloc, input);
    std.debug.print("input_array: {}\n", .{input_array});

    //std.debug.print("{f}", .{std.zig.fmtString(input)});
    const source =
        \\  not_eq,@\n )s partition first
    ;
    std.debug.print("soure: {s}\n", .{source});

    var lexed = try lex.lex(&ast_alloc, source);
    stringprint.printfmt("tokens: {}\n", .{lexed.tokens});
    stringprint.printfmt("line_offsets: {}\n", .{lexed.line_offsets});

    defer lexed.deinit(&ast_alloc);

    var parser = parse.Parser.init(&ast_alloc, &runtime_alloc, source, lexed.tokens.items, lexed.line_offsets.items);
    defer parser.deinit();
    const file_ast: parse.FileAst = try parser.parseFile();
    stringprint.printfmt("main: {}\n", .{file_ast.main});

    var arg0_data = [_]f64{ 1, 2 };
    var arg1_data = [_]f64{ 4, 5 };
    const arg_meta = types.Array.initWithShape(&runtime_alloc, .Exclusive, &.{8});
    arg_meta.data = arg0_data[0..];
    const args = [_]types.Value{
        .{ .array = arg_meta },
        .{ .array = blk: {
            const meta = types.Array.initWithShape(&runtime_alloc, .Exclusive, &.{8});
            meta.data = arg1_data[0..];
            break :blk meta;
        } },
        .{ .array = input_array },
    };
    const result = switch (file_ast.main.arity) {
        2 => return error.ArityMismatch, //try eval.evalFunc(&runtime_alloc, file_ast.main, args[0..2]),
        1 => try eval.evalFunc(&runtime_alloc, file_ast.main, args[2..3]),
        else => return error.ArityMismatch,
    };
    const rendered = try format.valueString(ast_alloc.allocator(), result, true);
    std.debug.print("{s}\n", .{rendered});
    std.debug.print("{}\n", .{result});
}
