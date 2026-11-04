const std = @import("std");
const Value = @import("runtime.zig").Value;
const ReservedBumpAllocator = @import("reserved_bump_allocator.zig").ReservedBumpAllocator;

/// Preserve an immutable result while discarding allocations after a frame checkpoint.
/// Snapshot before rewinding: data and shape may overlap the destination frame.
/// No ownership flags, alias analysis, or in-place mutation are required.
pub fn ReturnImpl(memory: *ReservedBumpAllocator, checkpoint: usize, result: Value) !Value {
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const snapshot = try clone(scratch.allocator(), result);
    memory.restore(checkpoint);
    return clone(memory.allocator(), snapshot);
}

fn clone(a: std.mem.Allocator, value: Value) anyerror!Value {
    if (value.tuple) |tuple| {
        const items = try a.alloc(Value, tuple.len);
        for (tuple, items) |item, *copy| copy.* = try clone(a, item);
        return .{ .tuple = items };
    }
    return .{ .data = try a.dupe(f64, value.data), .shape = try a.dupe(usize, value.shape) };
}
