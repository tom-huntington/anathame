const std = @import("std");
const builtin = @import("builtin");
const anathame = @import("anathame");
const stringprint = @import("stringprint.zig");
const parse = @import("parse.zig");
const lex = @import("lex.zig");
const eval = @import("eval.zig");
const types = @import("types.zig");
const ReservedBumpAllocator = @import("ReservedBumpAllocator").ReservedBumpAllocator; // ../vendor/ReservedBumpAllocator/root.zig

fn bytesToArray(allocator: *ReservedBumpAllocator, bytes: []const u8) !types.Array {
    var meta = types.Array.initWithShape(allocator, &.{bytes.len});

    for (bytes, 0..) |byte, i| {
        meta.data[i] = @floatFromInt(byte);
    }

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
        \\  not_eq,@\n |s partition (split_at,1 |phi Cases [@L_-1 @R_1] parse mul) prepend,50 Scan add
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

    // var arg0_data = [_]f64{ 1, 2 };
    // var arg1_data = [_]f64{ 4, 5 };
    //var shape2 = [_]u64{2};
    //const array0 = types.Array{ .data = arg0_data[0..], .ownership = .Shared, .shape = shape2[0..] };
    //const array1 = types.Array{ .data = arg1_data[0..], .ownership = .Shared, .shape = shape2[0..] };
    // var arg_meta = types.Array.initWithShape(&runtime_alloc, &.{8});
    // arg_meta.data = arg0_data[0..];
    // const args = [_]types.Value{
    //     //.{ .array = array0 },
    //     //.{ .array = array1 },
    //     .{ .array = arg_meta },
    //     .{ .array = blk: {
    //         var meta = types.Array.initWithShape(&runtime_alloc, &.{8});
    //         meta.data = arg1_data[0..];
    //         break :blk meta;
    //     } },
    // };
    const textInput: types.Value = .{ .array = input_array };
    var ctx = eval.EvalContext.init(&runtime_alloc);
    defer ctx.deinit();
    const result = switch (file_ast.main.arity) {
        //2 => try eval.evalFunc(&ctx, null, file_ast.main, args[0..2]),
        1 => try eval.evalFunc(&ctx, null, file_ast.main, &.{textInput}),
        else => return error.ArityMismatch,
    };
    std.debug.print("{}\n", .{result});
}
