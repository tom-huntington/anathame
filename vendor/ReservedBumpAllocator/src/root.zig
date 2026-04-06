const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const windows = std.os.windows;

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const mem = std.mem;

pub const ReservedBumpAllocator = struct {
    base: [*]u8,
    reserved_len: usize,
    committed_len: usize,
    sentinel: usize,
    page_size: usize,

    pub const Error = error{
        OutOfMemory,
        UnsupportedPlatform,
    } || windows.VirtualAllocError || posix.MMapError || posix.MProtectError;

    pub fn init(reserved_len: usize) Error!ReservedBumpAllocator {
        if (reserved_len == 0) return error.OutOfMemory;

        const page_size = std.heap.pageSize();
        const reserved_len_aligned = mem.alignForward(usize, reserved_len, page_size);
        const raw_ptr = switch (builtin.os.tag) {
            .windows => try windows.VirtualAlloc(
                null,
                reserved_len_aligned,
                windows.MEM_RESERVE,
                windows.PAGE_NOACCESS,
            ),
            .linux, .macos => blk: {
                const mapped = try posix.mmap(
                    null,
                    reserved_len_aligned,
                    posix.PROT.NONE,
                    .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
                    -1,
                    0,
                );
                break :blk mapped.ptr;
            },
            else => return error.UnsupportedPlatform,
        };

        return .{
            .base = @ptrCast(raw_ptr),
            .reserved_len = reserved_len_aligned,
            .committed_len = 0,
            .sentinel = 0,
            .page_size = page_size,
        };
    }

    pub fn initFixedBuffer(buffer: []u8) Error!ReservedBumpAllocator {
        if (buffer.len == 0) return error.OutOfMemory;

        return .{
            .base = buffer.ptr,
            .reserved_len = buffer.len,
            .committed_len = buffer.len,
            .sentinel = 0,
            .page_size = 0,
        };
    }

    pub fn deinit(self: *ReservedBumpAllocator) void {
        if (self.page_size != 0) {
            switch (builtin.os.tag) {
                .windows => windows.VirtualFree(self.base, 0, windows.MEM_RELEASE),
                .linux, .macos => posix.munmap(@alignCast(self.base[0..self.reserved_len])),
                else => unreachable,
            }
        }
        self.* = undefined;
    }

    pub fn allocator(self: *ReservedBumpAllocator) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    pub fn reset(self: *ReservedBumpAllocator) void {
        self.sentinel = 0;
    }

    pub fn committedBytes(self: *const ReservedBumpAllocator) usize {
        return self.committed_len;
    }

    pub fn reservedBytes(self: *const ReservedBumpAllocator) usize {
        return self.reserved_len;
    }

    pub fn ownsPtr(self: *const ReservedBumpAllocator, ptr: [*]u8) bool {
        return sliceContainsPtr(self.base[0..self.reserved_len], ptr);
    }

    pub fn ownsSlice(self: *const ReservedBumpAllocator, slice: []u8) bool {
        return sliceContainsSlice(self.base[0..self.reserved_len], slice);
    }

    pub fn isLastAllocation(self: *const ReservedBumpAllocator, buf: []u8) bool {
        return @intFromPtr(buf.ptr) + buf.len == @intFromPtr(self.base) + self.sentinel;
    }

    pub fn isNextAllocation(self: *const ReservedBumpAllocator, ptr: [*]u8) bool {
        return @intFromPtr(ptr) == @intFromPtr(self.base) + self.sentinel;
    }

    pub fn reclaim(self: *ReservedBumpAllocator, buf: []u8) []u8 {
        assert(self.ownsSlice(buf));
        assert(self.isNextAllocation(buf.ptr));

        const new_sentinel = self.sentinel + buf.len;
        assert(new_sentinel <= self.reserved_len);

        self.ensureCommitted(new_sentinel) catch @panic("out of memory");
        self.sentinel = new_sentinel;
        return buf;
    }

    pub fn insertBeforeLastAllocation(self: *ReservedBumpAllocator, checkpoint_: usize, last_allocation: []u8, insert_bytes: usize) []u8 {
        const alignment = @alignOf(usize);
        assert(checkpoint_ <= self.sentinel);
        assert(self.ownsSlice(last_allocation));
        assert(@intFromPtr(last_allocation.ptr) == @intFromPtr(self.base + checkpoint_));
        assert(last_allocation.len == self.sentinel - checkpoint_);
        assert(@intFromPtr(last_allocation.ptr) % alignment == 0);
        assert(insert_bytes % alignment == 0);

        const new_sentinel = self.sentinel + insert_bytes;
        assert(new_sentinel <= self.reserved_len);

        self.ensureCommitted(new_sentinel) catch @panic("out of memory");

        const inserted = self.base[checkpoint_ .. checkpoint_ + insert_bytes];
        const moved_last_allocation = self.base[checkpoint_ + insert_bytes .. new_sentinel];
        std.mem.copyBackwards(u8, moved_last_allocation, last_allocation);
        self.sentinel = new_sentinel;
        return inserted;
    }

    fn ensureCommitted(self: *ReservedBumpAllocator, sentinel: usize) Error!void {
        if (self.page_size == 0 or self.committed_len == self.reserved_len) return;

        const needed = mem.alignForward(usize, sentinel, self.page_size);
        if (needed <= self.committed_len) return;
        if (needed > self.reserved_len) return error.OutOfMemory;

        const commit_len = needed - self.committed_len;
        switch (builtin.os.tag) {
            .windows => {
                const commit_ptr: ?*anyopaque = @ptrCast(self.base + self.committed_len);
                _ = try windows.VirtualAlloc(
                    commit_ptr,
                    commit_len,
                    windows.MEM_COMMIT,
                    windows.PAGE_READWRITE,
                );
            },
            .linux, .macos => try posix.mprotect(
                @alignCast(self.base[self.committed_len..needed]),
                posix.PROT.READ | posix.PROT.WRITE,
            ),
            else => return error.UnsupportedPlatform,
        }
        self.committed_len = needed;
    }

    fn alloc(ctx: *anyopaque, n: usize, alignment: mem.Alignment, ra: usize) ?[*]u8 {
        const self: *ReservedBumpAllocator = @ptrCast(@alignCast(ctx));
        _ = ra;

        const ptr_align = alignment.toByteUnits();
        const adjust_off = mem.alignPointerOffset(self.base + self.sentinel, ptr_align) orelse return null;
        const adjusted_index = self.sentinel + adjust_off;
        const new_sentinel = adjusted_index + n;
        if (new_sentinel > self.reserved_len) return null;

        self.ensureCommitted(new_sentinel) catch return null;
        self.sentinel = new_sentinel;
        return self.base + adjusted_index;
    }

    fn resize(
        ctx: *anyopaque,
        buf: []u8,
        alignment: mem.Alignment,
        new_size: usize,
        return_address: usize,
    ) bool {
        const self: *ReservedBumpAllocator = @ptrCast(@alignCast(ctx));
        _ = alignment;
        _ = return_address;
        assert(@inComptime() or self.ownsSlice(buf));

        if (!self.isLastAllocation(buf)) {
            return new_size <= buf.len;
        }

        if (new_size <= buf.len) {
            self.sentinel -= buf.len - new_size;
            return true;
        }

        const new_sentinel = self.sentinel + (new_size - buf.len);
        if (new_sentinel > self.reserved_len) return false;

        self.ensureCommitted(new_sentinel) catch return false;
        self.sentinel = new_sentinel;
        return true;
    }

    fn remap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        return if (resize(ctx, memory, alignment, new_len, return_address)) memory.ptr else null;
    }

    fn free(
        ctx: *anyopaque,
        buf: []u8,
        alignment: mem.Alignment,
        return_address: usize,
    ) void {
        const self: *ReservedBumpAllocator = @ptrCast(@alignCast(ctx));
        _ = alignment;
        _ = return_address;
        assert(@inComptime() or self.ownsSlice(buf));

        if (self.isLastAllocation(buf)) {
            self.sentinel -= buf.len;
        }
    }

    pub fn checkpoint(self: *@This()) usize {
        return self.sentinel;
    }

    pub fn restore(self: *@This(), checkpoint_: usize) void {
        std.debug.assert(checkpoint_ <= self.committed_len);
        std.debug.assert(checkpoint_ <= self.reserved_len);
        self.sentinel = checkpoint_;
    }
};

fn sliceContainsPtr(container: []const u8, ptr: [*]u8) bool {
    return @intFromPtr(ptr) >= @intFromPtr(container.ptr) and
        @intFromPtr(ptr) < (@intFromPtr(container.ptr) + container.len);
}

fn sliceContainsSlice(container: []const u8, slice: []const u8) bool {
    return @intFromPtr(slice.ptr) >= @intFromPtr(container.ptr) and
        (@intFromPtr(slice.ptr) + slice.len) <= (@intFromPtr(container.ptr) + container.len);
}

test "reserved bump allocator commits pages on demand" {
    switch (builtin.os.tag) {
        .windows, .linux, .macos => {},
        else => return error.SkipZigTest,
    }

    var allocator_impl = try ReservedBumpAllocator.init(64 * 1024);
    defer allocator_impl.deinit();

    const allocator = allocator_impl.allocator();
    const page_size = std.heap.pageSize();

    try std.testing.expectEqual(@as(usize, 0), allocator_impl.committedBytes());

    const a = try allocator.alloc(u8, page_size / 2);
    try std.testing.expectEqual(page_size, allocator_impl.committedBytes());

    const b = try allocator.alloc(u8, page_size);
    try std.testing.expect(allocator_impl.committedBytes() >= page_size * 2);

    allocator.free(b);
    allocator.free(a);
}

test "reserved bump allocator reuses last allocation space" {
    switch (builtin.os.tag) {
        .windows, .linux, .macos => {},
        else => return error.SkipZigTest,
    }

    var allocator_impl = try ReservedBumpAllocator.init(64 * 1024);
    defer allocator_impl.deinit();

    const allocator = allocator_impl.allocator();

    const first = try allocator.alloc(u8, 16);
    const second = try allocator.alloc(u8, 16);

    allocator.free(second);
    const third = try allocator.alloc(u8, 16);

    try std.testing.expectEqual(@intFromPtr(second.ptr), @intFromPtr(third.ptr));
    try std.testing.expectEqual(@intFromPtr(first.ptr) + 16, @intFromPtr(third.ptr));
}

test "fixed buffer allocator starts fully committed" {
    var buffer: [256]u8 = undefined;
    var allocator_impl = try ReservedBumpAllocator.initFixedBuffer(&buffer);
    defer allocator_impl.deinit();

    try std.testing.expectEqual(buffer.len, allocator_impl.reservedBytes());
    try std.testing.expectEqual(buffer.len, allocator_impl.committedBytes());
    try std.testing.expect(allocator_impl.ownsPtr(buffer[0..].ptr));
}

test "fixed buffer allocator reuses last allocation space" {
    var buffer: [64]u8 = undefined;
    var allocator_impl = try ReservedBumpAllocator.initFixedBuffer(&buffer);
    defer allocator_impl.deinit();

    const allocator = allocator_impl.allocator();

    const first = try allocator.alloc(u8, 16);
    const second = try allocator.alloc(u8, 16);

    allocator.free(second);
    const third = try allocator.alloc(u8, 16);

    try std.testing.expectEqual(@intFromPtr(second.ptr), @intFromPtr(third.ptr));
    try std.testing.expectEqual(@intFromPtr(first.ptr) + 16, @intFromPtr(third.ptr));
    try std.testing.expectEqual(buffer.len, allocator_impl.committedBytes());
}

test "fixed buffer allocator inserts before checkpoint tail" {
    var buffer: [64]u8 = undefined;
    var allocator_impl = try ReservedBumpAllocator.initFixedBuffer(&buffer);
    defer allocator_impl.deinit();

    const allocator = allocator_impl.allocator();

    const prefix = try allocator.alloc(u8, 8);
    @memcpy(prefix, "prefix!!");
    const checkpoint_ = allocator_impl.checkpoint();

    const tail = try allocator.alloc(u8, 16);
    @memcpy(tail, "tail allocation!");

    const last_allocation = allocator_impl.base[checkpoint_..allocator_impl.checkpoint()];
    const inserted = allocator_impl.insertBeforeLastAllocation(checkpoint_, last_allocation, 8);
    @memcpy(inserted, "insert!!");

    try std.testing.expectEqualSlices(u8, "prefix!!", buffer[0..8]);
    try std.testing.expectEqualSlices(u8, "insert!!", buffer[8..16]);
    try std.testing.expectEqualSlices(u8, "tail allocation!", buffer[16..32]);
    try std.testing.expectEqual(@as(usize, 32), allocator_impl.checkpoint());
}
