const std = @import("std");
const language = @import("anathame");

pub fn run_test(code: []const u8, input: []const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try language.runtime.run_test(a, code, input, expected);
}
