const std = @import("std");
const Value = @import("runtime.zig").Value;

/// Convolve trailing axes, preserving the input shape. Even kernels crop the
/// full result starting at floor((kernel size - 1) / 2) on each axis.
pub fn same(a: std.mem.Allocator, x: Value, kernel: Value) !Value {
    return convolve(a, x, kernel, .same);
}

/// Convolve trailing axes using only complete overlaps.
pub fn valid(a: std.mem.Allocator, x: Value, kernel: Value) !Value {
    return convolve(a, x, kernel, .valid);
}

/// Convolve trailing axes including all partial overlaps, with zero padding.
pub fn full(a: std.mem.Allocator, x: Value, kernel: Value) !Value {
    return convolve(a, x, kernel, .full);
}

const Mode = enum { same, valid, full };

fn convolve(a: std.mem.Allocator, x: Value, kernel: Value, mode: Mode) !Value {
    if (x.tuple != null or kernel.tuple != null) return error.ExpectedArray;
    const rank = kernel.shape.len;
    if (rank < 1 or rank > 2 or x.shape.len < rank) return error.InvalidInput;
    for (kernel.shape) |size| if (size == 0) return error.InvalidInput;

    const shape = try a.dupe(usize, x.shape);
    errdefer a.free(shape);
    const start = shape.len - rank;
    var offsets: [2]usize = .{ 0, 0 };
    for (kernel.shape, 0..) |size, axis| {
        const n = x.shape[start + axis];
        shape[start + axis] = switch (mode) {
            .same => n,
            .valid => if (n >= size) n - size + 1 else 0,
            .full => if (n == 0) 0 else try std.math.add(usize, n, size - 1),
        };
        offsets[axis] = switch (mode) {
            .same => (size - 1) / 2,
            .valid => size - 1,
            .full => 0,
        };
        if (shape[start + axis] != 0)
            _ = try std.math.add(usize, shape[start + axis] - 1, offsets[axis]);
    }
    var count: usize = 1;
    for (shape) |size| count = try std.math.mul(usize, count, size);
    const data = try a.alloc(f64, count);
    errdefer a.free(data);
    @memset(data, 0);
    if (count == 0) return .{ .data = data, .shape = shape };

    const input_width = x.shape[x.shape.len - 1];
    const input_height = if (rank == 2) x.shape[start] else 1;
    const output_width = shape[shape.len - 1];
    const output_height = if (rank == 2) shape[start] else 1;
    const kernel_width = kernel.shape[rank - 1];
    const input_cells = try std.math.mul(usize, input_height, input_width);
    const output_cells = try std.math.mul(usize, output_height, output_width);
    for (data, 0..) |*result, index| {
        const batch = index / output_cells;
        const cell = index % output_cells;
        const row = cell / output_width + (if (rank == 2) offsets[0] else 0);
        const col = cell % output_width + offsets[rank - 1];
        for (kernel.data, 0..) |weight, k| {
            const kr = k / kernel_width;
            const kc = k % kernel_width;
            if (row < kr or col < kc) continue;
            const r = row - kr;
            const c = col - kc;
            if (r >= input_height or c >= input_width) continue;
            result.* += x.data[batch * input_cells + r * input_width + c] * weight;
        }
    }
    return .{ .data = data, .shape = shape };
}
