const std = @import("std");
const Value = @import("runtime.zig").Value;
const ReservedBumpAllocator = @import("reserved_bump_allocator.zig").ReservedBumpAllocator;

/// Preserve an immutable result while discarding allocations after a frame checkpoint.
/// Snapshot before rewinding: data and shape may overlap the destination frame.
/// No ownership flags, alias analysis, or in-place mutation are required.
pub fn ReturnImpl(memory: *ReservedBumpAllocator, checkpoint: usize, result: Value) !Value {
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const data = try scratch.allocator().dupe(f64, result.data);
    const shape = try scratch.allocator().dupe(usize, result.shape);
    memory.restore(checkpoint);
    return .{ .data = try memory.allocator().dupe(f64, data), .shape = try memory.allocator().dupe(usize, shape) };
}

test "return compacts a frame and survives subsequent allocations" {
    var memory = try ReservedBumpAllocator.init(65536);
    defer memory.deinit();
    const prefix = try memory.allocator().dupe(u8, "saved");
    const checkpoint = memory.checkpoint();
    _ = try memory.allocator().alloc(u8, 1024);
    const data = try memory.allocator().dupe(f64, &.{ 6, 2 });
    const shape = try memory.allocator().dupe(usize, &.{2});
    const result = try ReturnImpl(&memory, checkpoint, .{ .data = data, .shape = shape });
    try std.testing.expect(memory.checkpoint() < checkpoint + 1024);
    @memset(try memory.allocator().alloc(u8, 2048), 0);
    try std.testing.expectEqualStrings("saved", prefix);
    try std.testing.expectEqualSlices(f64, &.{ 6, 2 }, result.data);
    try std.testing.expectEqualSlices(usize, &.{2}, result.shape);
}
