const ReservedBumpAllocator = @import("ReservedBumpAllocator").ReservedBumpAllocator; // ../vendor/ReservedBumpAllocator/root.zig
const Array = @import("types.zig").Array;
const Value = @import("types.zig").Value;
const std = @import("std");

const build_options = @import("build_options");
const debug_array_return_snapshot = build_options.debug_array_return_snapshot;

pub const array_data_alignment = std.mem.Alignment.of(f64);
pub const array_shape_alignment = std.mem.Alignment.of(usize);

fn debugCopyArray(allocator: std.mem.Allocator, array: *const Array) *Array {
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

fn assertReturnedArrayUnchanged(input: *const Array, output: *const Array) void {
    if (arraysEqualByValue(input, output)) return;

    std.debug.print("Array.Return changed array value\n", .{});
    debugPrintArray("input", input);
    debugPrintArray("output", output);
    @panic("Array.Return changed array value");
}

fn assertReturnedArrayInvariants(all: *ReservedBumpAllocator, array: *const Array) void {
    const expected_data_len = num_elements(array);
    if (array.data.len != expected_data_len) {
        std.debug.print(
            "Array.Return returned data length that does not match shape: expected {d}, got {d}\n",
            .{ expected_data_len, array.data.len },
        );
        debugPrintArray("output", array);
        @panic("Array.Return returned invalid array shape/data length");
    }

    if (!all.ownsSlice(std.mem.sliceAsBytes(array.data)) or !all.ownsSlice(std.mem.sliceAsBytes(array.shape))) {
        std.debug.print("Array.Return returned slices outside the bump allocator\n", .{});
        debugPrintArray("output", array);
        @panic("Array.Return returned non-bump array slices");
    }
}

fn arraysEqualByValue(lhs: *const Array, rhs: *const Array) bool {
    const lhs_data_len = num_elements(lhs);
    const rhs_data_len = num_elements(rhs);
    if (lhs.data.len < lhs_data_len or rhs.data.len < rhs_data_len) return false;

    return std.mem.eql(usize, lhs.shape, rhs.shape) and
        std.mem.eql(f64, lhs.data[0..lhs_data_len], rhs.data[0..rhs_data_len]);
}

fn debugPrintArray(label: []const u8, array: *const Array) void {
    std.debug.print(
        "{s}: shape={any} data={any}\n",
        .{ label, array.shape, array.data },
    );
}

fn sliceContainsSlice(container: []const u8, slice: []const u8) bool {
    return @intFromPtr(slice.ptr) >= @intFromPtr(container.ptr) and
        (@intFromPtr(slice.ptr) + slice.len) <= (@intFromPtr(container.ptr) + container.len);
}

fn sliceInTail(all: *ReservedBumpAllocator, checkpoint: usize, slice: anytype) bool {
    const bytes = std.mem.sliceAsBytes(slice);
    return all.ownsSlice(bytes) and @intFromPtr(bytes.ptr) >= @intFromPtr(all.base + checkpoint);
}

fn preserveTailSlice(all: *ReservedBumpAllocator, comptime T: type, slice: []T) []T {
    const bytes = std.mem.sliceAsBytes(slice);
    std.debug.assert(all.ownsSlice(bytes));
    std.debug.assert(@intFromPtr(bytes.ptr) >= @intFromPtr(all.base + all.sentinel));

    const reclaim_start = all.base + all.sentinel;
    const offset = @intFromPtr(bytes.ptr) - @intFromPtr(reclaim_start);
    const reclaimed = all.reclaim(reclaim_start[0 .. offset + bytes.len]);
    const final_bytes = reclaimed[offset..][0..bytes.len];
    const ptr: [*]T = @ptrCast(@alignCast(final_bytes.ptr));
    return ptr[0..slice.len];
}

pub fn Return(all: *ReservedBumpAllocator, checkpoint: usize, result_before: *const Array) Value {
    //if (comptime debug_array_return_snapshot) {
    if (comptime @import("builtin").mode == .Debug) {
        var debug_gpa = std.heap.GeneralPurposeAllocator(.{}).init;
        defer std.debug.assert(debug_gpa.deinit() == .ok);

        const debug_allocator = debug_gpa.allocator();
        const deep_copy = debugCopyArray(debug_allocator, result_before);
        defer destroyDebugCopy(debug_allocator, deep_copy);

        const result_after = ReturnImpl(all, checkpoint, result_before);
        assertReturnedArrayUnchanged(deep_copy, &result_after.array);
        assertReturnedArrayInvariants(all, &result_after.array);
        return result_after;
    } else return ReturnImpl(all, checkpoint, result_before);
}

pub fn ReturnImpl(all: *ReservedBumpAllocator, checkpoint: usize, result: *const Array) Value {
    const depth = result.shape.len;
    const size = num_elements(result);
    if (result.data.len < size) {
        @panic("Array.Return result data is shorter than its shape");
    }
    const result_data = result.data[0..size];
    const result_shape = result.shape;

    all.restore(checkpoint);

    var final_data: ?[]f64 = null;
    var final_shape: ?[]usize = null;

    const data_in_tail = sliceInTail(all, checkpoint, result_data);
    const shape_in_tail = sliceInTail(all, checkpoint, result_shape);
    if (data_in_tail and (!shape_in_tail or @intFromPtr(result_data.ptr) <= @intFromPtr(result_shape.ptr))) {
        final_data = preserveTailSlice(all, f64, result_data);
    }
    if (shape_in_tail) {
        final_shape = preserveTailSlice(all, usize, result_shape);
    }
    if (data_in_tail and final_data == null) {
        final_data = preserveTailSlice(all, f64, result_data);
    }

    if (final_data == null) {
        const data = all.allocator().alloc(f64, size) catch @panic("out of memory");
        std.mem.copyForwards(f64, data, result_data);
        final_data = data;
    }
    if (final_shape == null) {
        const shape = all.allocator().alloc(usize, depth) catch @panic("out of memory");
        std.mem.copyForwards(usize, shape, result_shape);
        final_shape = shape;
    }

    return .{ .array = .{
        .data = final_data.?,
        .status = .Exclusive,
        .shape = final_shape.?,
    } };
}

pub fn prod(slice: []const usize) usize {
    var result: usize = 1;
    for (slice) |el| {
        result = result * el;
    }
    return result;
}

pub fn initWithDepth(
    allocator: *ReservedBumpAllocator,
    depth: usize,
    size: usize,
) Array {
    return .{
        .data = allocator.allocator().alloc(f64, size) catch @panic("out of memory"),
        .status = .Exclusive,
        .shape = allocator.allocator().alloc(usize, depth) catch @panic("out of memory"),
    };
}

pub fn initWithDepthBefore(
    allocator: *ReservedBumpAllocator,
    checkpoint: usize,
    last_allocation: []u8,
    depth: usize,
    size: usize,
    moved_array: ?*Array,
) Array {
    const data_bytes = size * @sizeOf(f64);
    const shape_offset = array_shape_alignment.forward(data_bytes);
    const shape_bytes = depth * @sizeOf(usize);
    const insert_bytes = shape_offset + shape_bytes;
    const bytes = allocator.insertBeforeLastAllocation(checkpoint, last_allocation, insert_bytes);
    if (moved_array) |array| {
        offsetTailArraySlicesByBytes(array, last_allocation, insert_bytes);
    }

    const data_ptr: [*]f64 = @ptrCast(@alignCast(bytes.ptr));
    const shape_ptr: [*]usize = @ptrCast(@alignCast(bytes.ptr + shape_offset));
    return .{
        .data = data_ptr[0..size],
        .status = .Exclusive,
        .shape = shape_ptr[0..depth],
    };
}

pub fn num_elements(self: *const Array) usize {
    return @import("array_helpers.zig").prod(self.shape);
}

fn offsetTailArraySlicesByBytes(array: *Array, tail: []const u8, byte_offset: usize) void {
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
}

pub inline fn topmost_shape(a: Array, b: Array) Array {
    return if (@intFromPtr(a.data.ptr) < @intFromPtr(b.data.ptr)) b else a;
}

pub inline fn InitialiteOutofplaceResult(all: *ReservedBumpAllocator, result_dest: ?[]f64, arg: Array) Array {
    return if (result_dest) |dest|
        Array{ .data = dest[0..arg.data.len], .status = .Shared, .shape = arg.shape }
    else
        Array.initWithShape(all, arg.shape);
}
