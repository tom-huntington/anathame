const std = @import("std");
const language = @import("anathame");

pub fn run_test(code: []const u8, input: []const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const actual = try language.runtime.evaluate(a, code, input);
    const normalized = try std.mem.replaceOwned(u8, a, expected, ",", " ");
    const instructions = try language.parser.parse(a, normalized);
    try std.testing.expectEqual(instructions.len, actual.len);
    for (instructions, actual) |instruction, value| {
        const want = switch (instruction) {
            .literal => |literal| literal,
            else => return error.ExpectedLiteral,
        };
        try std.testing.expectEqualSlices(usize, want.shape, value.shape);
        try std.testing.expectEqualSlices(f64, want.data, value.data);
    }
}
