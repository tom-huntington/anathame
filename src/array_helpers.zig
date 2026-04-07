const ReservedBumpAllocator = @import("ReservedBumpAllocator").ReservedBumpAllocator;
const Array = @import("types.zig").Array;
const CowStatus = @import("types.zig").CowStatus;
const Value = @import("types.zig").Value;
const std = @import("std");

pub const array_header_alignment = std.mem.Alignment.of(Array);
pub const array_data_alignment = std.mem.Alignment.of(f64);
pub const array_allocation_alignment = std.mem.Alignment.fromByteUnits(@max(@alignOf(Array), @alignOf(f64)));
const array_shape_alignment = std.mem.Alignment.of(usize);

pub fn initArrayWithDepth(
    allocator: *ReservedBumpAllocator,
    status: CowStatus,
    depth: usize,
) *Array {
    const shape_offset = shapeOffset();
    const total_bytes = headerByteLen(depth);
    const bytes = allocator.allocator().alignedAlloc(u8, array_header_alignment, total_bytes) catch @panic("out of memory");
    const header: *Array = @ptrCast(@alignCast(bytes.ptr));
    const shape_ptr: [*]usize = @ptrCast(@alignCast(bytes.ptr + shape_offset));
    header.* = .{
        .data = &.{},
        .status = status,
        .shape = shape_ptr[0..depth],
    };
    return header;
}

pub fn offsetTailArrayPointerByBytes(array_ptr: **Array, tail: []const u8, byte_offset: usize) void {
    var array = array_ptr.*;
    array = if (sliceContainsPtr(tail, @ptrCast(array)))
        @ptrFromInt(@intFromPtr(array) + byte_offset)
    else
        array;

    const data_bytes = std.mem.sliceAsBytes(array.data);
    const data_ptr: [*]f64 = if (sliceContainsSlice(tail, data_bytes))
        @ptrFromInt(@intFromPtr(array.data.ptr) + byte_offset)
    else
        array.data.ptr;
    const shape_ptr: [*]usize = if (sliceContainsSlice(tail, std.mem.sliceAsBytes(array.shape)))
        @ptrFromInt(@intFromPtr(array.shape.ptr) + byte_offset)
    else
        array.shape.ptr;

    array.data = data_ptr[0..array.data.len];
    array.shape = shape_ptr[0..array.shape.len];
    array_ptr.* = array;
}

fn debugCopyArray(allocator: std.mem.Allocator, array: *Array) *Array {
    const data = allocator.dupe(f64, array.data) catch @panic("out of memory");
    errdefer allocator.free(data);

    const shape = allocator.dupe(usize, array.shape) catch @panic("out of memory");
    errdefer allocator.free(shape);

    const meta = allocator.create(Array) catch @panic("out of memory");
    meta.* = .{
        .data = data,
        .status = array.status,
        .shape = shape,
    };

    return meta;
}

fn destroyDebugCopy(allocator: std.mem.Allocator, array: *Array) void {
    const shape = array.shape;
    const data = array.data;
    allocator.destroy(array);
    allocator.free(shape);
    allocator.free(data);
}

fn assertReturnedArrayUnchanged(input: *Array, output: *Array) void {
    if (arraysEqualByValue(input, output)) return;

    std.debug.print("Array.Return changed array value\n", .{});
    debugPrintArray("input", input);
    debugPrintArray("output", output);
    @panic("Array.Return changed array value");
}

fn assertReturnedArrayInvariants(all: *ReservedBumpAllocator, array: *Array) void {
    const expected_data_len = num_elements(array);
    if (array.data.len != expected_data_len) {
        std.debug.print(
            "Array.Return returned data length that does not match shape: expected {d}, got {d}\n",
            .{ expected_data_len, array.data.len },
        );
        debugPrintArray("output", array);
        @panic("Array.Return returned invalid array shape/data length");
    }

    if (!all.isLastAllocation(std.mem.sliceAsBytes(array.data))) {
        std.debug.print("Array.Return returned data that is not the final bump allocation\n", .{});
        debugPrintArray("output", array);
        @panic("Array.Return returned non-final array data");
    }
}

fn arraysEqualByValue(lhs: *Array, rhs: *Array) bool {
    const lhs_data_len = num_elements(lhs);
    const rhs_data_len = num_elements(rhs);
    if (lhs.data.len < lhs_data_len or rhs.data.len < rhs_data_len) return false;

    return std.mem.eql(usize, lhs.shape, rhs.shape) and
        std.mem.eql(f64, lhs.data[0..lhs_data_len], rhs.data[0..rhs_data_len]);
}

fn debugPrintArray(label: []const u8, array: *Array) void {
    std.debug.print(
        "{s}: shape={any} data={any}\n",
        .{ label, array.shape, array.data },
    );
}

fn sliceContainsPtr(container: []const u8, ptr: [*]const u8) bool {
    return @intFromPtr(ptr) >= @intFromPtr(container.ptr) and
        @intFromPtr(ptr) < (@intFromPtr(container.ptr) + container.len);
}

fn sliceContainsSlice(container: []const u8, slice: []const u8) bool {
    return @intFromPtr(slice.ptr) >= @intFromPtr(container.ptr) and
        (@intFromPtr(slice.ptr) + slice.len) <= (@intFromPtr(container.ptr) + container.len);
}

pub fn ArrayReturn(all: *ReservedBumpAllocator, checkpoint: usize, result_before: *Array) Value {
    //if (comptime debug_array_return_snapshot) {
    if (comptime @import("builtin").mode == .Debug) {
        var debug_gpa = std.heap.GeneralPurposeAllocator(.{}).init;
        defer std.debug.assert(debug_gpa.deinit() == .ok);

        const debug_allocator = debug_gpa.allocator();
        const deep_copy = debugCopyArray(debug_allocator, result_before);
        defer destroyDebugCopy(debug_allocator, deep_copy);

        const result_after = ReturnImpl(all, checkpoint, result_before);
        assertReturnedArrayUnchanged(deep_copy, result_after.array);
        assertReturnedArrayInvariants(all, result_after.array);
        return result_after;
    } else return ReturnImpl(all, checkpoint, result_before);
}

pub fn ReturnImpl(all: *ReservedBumpAllocator, checkpoint: usize, result: *Array) Value {
    const depth = result.shape.len;
    const size = num_elements(result);
    if (result.data.len < size) {
        @panic("Array.Return result data is shorter than its shape");
    }
    const meta_bytes = allocationBytes(result);
    const compact_bytes = compactAllocationBytes(result);
    const result_data = result.data[0..size];
    const compact_size = totalByteLen(depth, size);

    all.restore(checkpoint);

    if (compact_bytes) |bytes| {
        const compact_prefix = bytes[0..compact_size];
        if (all.isNextAllocation(bytes.ptr)) {
            _ = all.reclaim(compact_prefix);
            result.status = .Exclusive;
            result.data = result_data;
            return .{ .array = result };
        }

        if (all.ownsSlice(bytes) and @intFromPtr(bytes.ptr) >= @intFromPtr(all.base + all.sentinel)) {
            // Reclaim the gap too; allocating first can debug-fill and clobber the source.
            const reclaim_start = all.base + all.sentinel;
            const align_offset = std.mem.alignPointerOffset(reclaim_start, allocationAlignment().toByteUnits()) orelse unreachable;
            const reclaimed_len = align_offset + compact_size;
            const reclaimed = all.reclaim(reclaim_start[0..reclaimed_len]);
            const final_bytes = reclaimed[align_offset..][0..compact_size];
            std.mem.copyForwards(u8, final_bytes, compact_prefix);
            return .{ .array = fromCompactAllocation(final_bytes, depth, size) };
        }

        const final_bytes = all.allocator().alignedAlloc(u8, allocationAlignment(), compact_size) catch @panic("out of memory");
        std.mem.copyForwards(u8, final_bytes, compact_prefix);
        return .{ .array = fromCompactAllocation(final_bytes, depth, size) };
    }

    const final_data = if (all.isNextAllocation(@ptrCast(result.data.ptr))) blk: {
        const bytes = std.mem.sliceAsBytes(result_data);
        _ = all.reclaim(bytes);
        const ptr: [*]f64 = @ptrCast(@alignCast(bytes.ptr));
        break :blk ptr[0..size];
    } else blk: {
        const data = all.allocator().alloc(f64, size) catch @panic("out of memory");
        std.mem.copyForwards(f64, data, result_data);
        break :blk data;
    };

    const final_meta = if (all.isNextAllocation(meta_bytes.ptr)) blk: {
        _ = all.reclaim(meta_bytes);
        result.status = .Exclusive;
        break :blk result;
    } else Array.initWithShape(all, .Exclusive, result.shape);

    final_meta.data = final_data;
    return .{ .array = final_meta };
}

pub fn prod(slice: []const usize) usize {
    var result: usize = 1;
    for (slice) |el| {
        result = result * el;
    }
    return result;
}

pub fn compactAllocationBytes(self: *Array) ?[]u8 {
    const meta_bytes = allocationBytes(self);
    const expected_data_ptr = meta_bytes.ptr + dataOffset(self.shape.len);
    if (@intFromPtr(self.data.ptr) != @intFromPtr(expected_data_ptr)) return null;

    return meta_bytes.ptr[0..totalByteLen(self.shape.len, self.data.len)];
}

pub fn fromCompactAllocation(bytes: []u8, depth: usize, size: usize) *Array {
    std.debug.assert(bytes.len >= totalByteLen(depth, size));

    const meta: *Array = @ptrCast(@alignCast(bytes.ptr));
    const shape_ptr: [*]usize = @ptrCast(@alignCast(bytes.ptr + shapeOffset()));
    meta.* = .{
        .data = &.{},
        .status = CowStatus.Exclusive,
        .shape = shape_ptr[0..depth],
    };

    const data_ptr: [*]f64 = @ptrCast(@alignCast(bytes.ptr + dataOffset(depth)));
    meta.data = data_ptr[0..size];
    return meta;
}

pub fn allocationAlignment() std.mem.Alignment {
    return @import("array_helpers.zig").array_allocation_alignment;
}

pub fn dataOffset(depth: usize) usize {
    return @import("array_helpers.zig").array_data_alignment.forward(headerByteLen(depth));
}

pub fn totalByteLen(depth: usize, size: usize) usize {
    return dataOffset(depth) + size * @sizeOf(f64);
}

pub fn shapeOffset() usize {
    return array_shape_alignment.forward(@sizeOf(@This()));
}

pub fn headerByteLen(depth: usize) usize {
    return shapeOffset() + depth * @sizeOf(usize);
}

pub fn allocationBytes(self: *Array) []u8 {
    const ptr: [*]u8 = @ptrCast(self);
    return ptr[0..headerByteLen(self.shape.len)];
}

pub fn initWithDepth(
    allocator: *ReservedBumpAllocator,
    depth: usize,
    size: usize,
) *Array {
    const shape_offset = shapeOffset();
    const data_offset = dataOffset(depth);
    const total_bytes = totalByteLen(depth, size);
    const bytes = allocator.allocator().alignedAlloc(u8, array_allocation_alignment, total_bytes) catch @panic("out of memory");

    _ = shape_offset;
    _ = data_offset;
    return @import("array_helpers.zig").fromCompactAllocation(bytes, depth, size);
}

pub fn initWithDepthBefore(
    allocator: *ReservedBumpAllocator,
    checkpoint: usize,
    last_allocation: []u8,
    depth: usize,
    size: usize,
    moved_array: ?**Array,
) *Array {
    const total_bytes = totalByteLen(depth, size);
    const bytes = allocator.insertBeforeLastAllocation(checkpoint, last_allocation, total_bytes);
    if (moved_array) |array| {
        offsetTailArrayPointerByBytes(array, last_allocation, total_bytes);
    }
    return fromCompactAllocation(bytes, depth, size);
}

pub fn num_elements(self: *Array) usize {
    return @import("array_helpers.zig").prod(self.shape);
}
