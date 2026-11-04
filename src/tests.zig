const std = @import("std");
const runtime = @import("runtime.zig");
test "errors are recoverable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.StackUnderflow, runtime.evaluate(a, "mul", "2"));
    try std.testing.expectError(error.UnimplementedPrimitive, runtime.evaluate(a, "add", "2; 3"));
    try std.testing.expectError(error.UnknownPrimitive, runtime.evaluate(a, "nonsense", ""));
    try std.testing.expectError(error.ArrayArgumentsNotSupported, runtime.evaluate(a, "couple", "[1 2]; 3"));
    try std.testing.expectError(error.InvalidInput, runtime.evaluate(a, "mul", "2; 3; 4"));
    try std.testing.expectError(error.InvalidInput, runtime.evaluate(a, "mul", "2 3; 4"));
    try std.testing.expectError(error.InvalidInput, runtime.evaluate(a, "mul", "nan; 4"));
}
test "multiply does not mutate its inputs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const x: runtime.Value = .{ .data = &.{ 2, 3 }, .shape = &.{2} };
    const y = try @import("builtins.zig").mul(a, x, x);
    try std.testing.expectEqualSlices(f64, &.{ 4, 9 }, y.data);
    try std.testing.expectEqualSlices(f64, &.{ 2, 3 }, x.data);
}
