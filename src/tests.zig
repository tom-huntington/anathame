const std = @import("std");
const runtime = @import("runtime.zig");

test "mul couple: 2 3 -> [6,2]" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const values = try runtime.evaluate(arena.allocator(), "mul couple", "2 3");
    try std.testing.expectEqual(@as(usize, 1), values.len);
    try std.testing.expectEqualSlices(usize, &.{2}, values[0].shape);
    try std.testing.expectEqualSlices(f64, &.{ 6, 2 }, values[0].data);
}
