const std = @import("std");
const Value = @import("runtime.zig").Value;
const ReservedBumpAllocator = @import("reserved_bump_allocator.zig").ReservedBumpAllocator;

/// Discard a frame, preserving its immutable result in the same memory strip.
pub fn ReturnImpl(memory: *ReservedBumpAllocator, checkpoint: usize, result: Value) !Value {
    var cursor = checkpoint;
    if (packedEnd(memory, checkpoint, result, &cursor)) {
        memory.restore(cursor);
        return result;
    }
    if (result.tuple == null) {
        // Move tail slices in address order so neither move destroys the other
        // source. Slices below the checkpoint already have a caller lifetime.
        const data_tail = inTail(memory, checkpoint, result.data);
        const shape_tail = inTail(memory, checkpoint, result.shape);
        memory.restore(checkpoint);
        var output = result;
        if (data_tail and (!shape_tail or @intFromPtr(result.data.ptr) <= @intFromPtr(result.shape.ptr))) {
            output.data = try preserve(memory, f64, result.data);
            if (shape_tail) output.shape = try preserve(memory, usize, result.shape);
        } else {
            if (shape_tail) output.shape = try preserve(memory, usize, result.shape);
            if (data_tail) output.data = try preserve(memory, f64, result.data);
        }
        // External slices may point to stack temporaries, so copy them too.
        if (!data_tail and !before(memory, checkpoint, result.data)) output.data = try memory.allocator().dupe(f64, result.data);
        if (!shape_tail and !before(memory, checkpoint, result.shape)) output.shape = try memory.allocator().dupe(usize, result.shape);
        return output;
    }

    // Tuples can contain arbitrary aliases and views. Serialize them after the
    // live frame, with pointers already targeting their final compact location,
    // then move the packed bytes down in one overlapping copy.
    const end = memory.checkpoint();
    errdefer memory.restore(end);
    const alignment = @max(@alignOf(Value), @max(@alignOf(f64), @alignOf(usize)));
    const destination = std.mem.alignForward(usize, @intFromPtr(memory.base) + checkpoint, alignment);
    const scratch = memory.allocator().rawAlloc(0, .fromByteUnits(alignment), @returnAddress()) orelse return error.OutOfMemory;
    const start = @intFromPtr(scratch);
    const output = try pack(memory, checkpoint, result, start - destination);
    const length = memory.checkpoint() - (start - @intFromPtr(memory.base));
    std.mem.copyForwards(u8, memory.base[destination - @intFromPtr(memory.base) ..][0..length], memory.base[start - @intFromPtr(memory.base) ..][0..length]);
    memory.restore(destination - @intFromPtr(memory.base) + length);
    return output;
}

fn before(memory: *ReservedBumpAllocator, checkpoint: usize, slice: anytype) bool {
    const bytes = std.mem.sliceAsBytes(slice);
    return bytes.len == 0 or (memory.ownsPtr(@constCast(bytes.ptr)) and @intFromPtr(bytes.ptr) + bytes.len <= @intFromPtr(memory.base) + checkpoint);
}

fn inTail(memory: *ReservedBumpAllocator, checkpoint: usize, slice: anytype) bool {
    return slice.len != 0 and memory.ownsPtr(@constCast(std.mem.sliceAsBytes(slice).ptr)) and @intFromPtr(slice.ptr) >= @intFromPtr(memory.base) + checkpoint;
}

fn preserve(memory: *ReservedBumpAllocator, comptime T: type, slice: []const T) ![]const T {
    // Allocator.alloc poisons undefined memory in Debug, which would destroy
    // an overlapping source (or a result already at its destination).
    const bytes = memory.allocator().rawAlloc(slice.len * @sizeOf(T), .of(T), @returnAddress()) orelse return error.OutOfMemory;
    const pointer: [*]T = @ptrCast(@alignCast(bytes));
    const output = pointer[0..slice.len];
    if (output.ptr != slice.ptr) std.mem.copyForwards(T, output, slice);
    return output;
}

fn pack(memory: *ReservedBumpAllocator, checkpoint: usize, value: Value, displacement: usize) anyerror!Value {
    if (value.tuple) |tuple| {
        // Even a tuple header below the checkpoint can reference tail data.
        const items = try memory.allocator().alloc(Value, tuple.len);
        for (tuple, items) |item, *copy| copy.* = try pack(memory, checkpoint, item, displacement);
        return .{ .tuple = relocated(Value, items, displacement) };
    }
    return .{
        .data = if (before(memory, checkpoint, value.data)) value.data else relocated(f64, try memory.allocator().dupe(f64, value.data), displacement),
        .shape = if (before(memory, checkpoint, value.shape)) value.shape else relocated(usize, try memory.allocator().dupe(usize, value.shape), displacement),
    };
}

fn relocated(comptime T: type, slice: []const T, displacement: usize) []const T {
    if (slice.len == 0) return &.{};
    const pointer: [*]const T = @ptrFromInt(@intFromPtr(slice.ptr) - displacement);
    return pointer[0..slice.len];
}

// Recognize a result reserved at the start of the frame, including nested
// tuples and aliases of slices already retained by this traversal.
fn packedSlice(memory: *ReservedBumpAllocator, checkpoint: usize, slice: anytype, cursor: *usize) bool {
    if (before(memory, checkpoint, slice)) return true;
    const T = @typeInfo(@TypeOf(slice)).pointer.child;
    const start = @intFromPtr(slice.ptr);
    const end = start + slice.len * @sizeOf(T);
    const base = @intFromPtr(memory.base);
    if (start >= base + checkpoint and end <= base + cursor.*) return true;
    if (start != std.mem.alignForward(usize, base + cursor.*, @alignOf(T)) or end > base + memory.checkpoint()) return false;
    cursor.* = end - base;
    return true;
}

fn packedEnd(memory: *ReservedBumpAllocator, checkpoint: usize, value: Value, cursor: *usize) bool {
    if (value.tuple) |tuple| {
        if (!packedSlice(memory, checkpoint, tuple, cursor)) return false;
        for (tuple) |item| if (!packedEnd(memory, checkpoint, item, cursor)) return false;
        return true;
    }
    return packedSlice(memory, checkpoint, value.data, cursor) and packedSlice(memory, checkpoint, value.shape, cursor);
}
