const lib = @import("ReservedBumpAllocator");

var buffer: [256]u8 = undefined;

pub export fn runSmokeTest() u32 {
    var allocator_impl = lib.ReservedBumpAllocator.initFixedBuffer(&buffer) catch return 1;
    defer allocator_impl.deinit();

    const allocator = allocator_impl.allocator();

    if (allocator_impl.reservedBytes() != buffer.len) return 2;
    if (allocator_impl.committedBytes() != buffer.len) return 3;

    const first = allocator.alloc(u8, 32) catch return 4;
    const second = allocator.alloc(u8, 16) catch return 5;
    allocator.free(second);

    const third = allocator.alloc(u8, 16) catch return 6;
    if (@intFromPtr(second.ptr) != @intFromPtr(third.ptr)) return 7;
    if (@intFromPtr(first.ptr) + first.len != @intFromPtr(third.ptr)) return 8;

    return 0;
}
