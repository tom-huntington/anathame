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
