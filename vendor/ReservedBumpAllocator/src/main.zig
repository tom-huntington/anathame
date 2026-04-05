const std = @import("std");
const lib = @import("ReservedBumpAllocator");

const TiB: usize = 1024 * 1024 * 1024 * 1024;
const GiB: usize = 1024 * 1024 * 1024;

pub fn main() !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stdin_buffer: [1024]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);

    var allocator_impl = try lib.ReservedBumpAllocator.init(TiB);
    defer allocator_impl.deinit();

    const allocator = allocator_impl.allocator();
    const memory = try allocator.alloc(u8, GiB);

    @memset(memory, 0xA5);

    try stdout.print(
        "Reserved {d} bytes, committed {d} bytes, touched {d} bytes.\nPress Enter to exit.\n",
        .{
            allocator_impl.reservedBytes(),
            allocator_impl.committedBytes(),
            memory.len,
        },
    );
    try stdout.flush();

    _ = try stdin_reader.interface.takeDelimiter('\n');
}
