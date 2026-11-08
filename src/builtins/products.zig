const std = @import("std");
const Value = @import("../runtime.zig").Value;
const Function = @import("../primitives.zig").Function;
const scalar = @import("pervasives.zig");

// Contract the last left axis with the first right axis. Remaining axes
// form the result shape, so vectors, matrices and higher ranks compose alike.
fn product(comptime reduce: Function, comptime combine: Function) Function {
    return struct {
        fn call(a: std.mem.Allocator, x: Value, y: Value) !Value {
            if (x.tuple != null or y.tuple != null) return error.InvalidInput;
            if (x.shape.len == 0 or y.shape.len == 0) return error.ShapeMismatch;
            const width = x.shape[x.shape.len - 1];
            if (width != y.shape[0]) return error.ShapeMismatch;
            var rows: usize = 1;
            for (x.shape[0 .. x.shape.len - 1]) |dim| rows = try std.math.mul(usize, rows, dim);
            var cols: usize = 1;
            for (y.shape[1..]) |dim| cols = try std.math.mul(usize, cols, dim);
            const shape = try std.mem.concat(a, usize, &.{ x.shape[0 .. x.shape.len - 1], y.shape[1..] });
            const data = try a.alloc(f64, try std.math.mul(usize, rows, cols));
            multiply(reduce, combine, x.data, y.data, data, rows, cols, width);
            return .{ .data = data, .shape = shape };
        }
    }.call;
}

// Each operator pair instantiates its own kernel. No runtime operator dispatch
// or scalar Value allocations occur in the hot loop. As in Simon Boehm's
// Fast MMM on CPU, visit columns contiguously and tile the contraction axis.
// Blocking columns too bounds the working set for wide rectangular matrices.
fn multiply(comptime reduce: Function, comptime combine: Function, left: []const f64, right: []const f64, out: []f64, rows: usize, cols: usize, width: usize) void {
    if (out.len == 0) return;
    if (width == 0) {
        const identity: f64 = if (reduce == &scalar.add or reduce == &scalar.@"or") 0 else if (reduce == &scalar.mul or reduce == &scalar.@"and") 1 else if (reduce == &scalar.min) std.math.inf(f64) else -std.math.inf(f64);
        @memset(out, identity);
        return;
    }
    // Seed from the first term to retain signed-zero and NaN behavior, and
    // keep each output's reduction in ascending contraction-axis order.
    for (0..rows) |i| {
        const dst = out[i * cols ..][0..cols];
        for (dst, right[0..cols]) |*c, b| c.* = apply(combine, left[i * width], b);
    }
    const column_tile = 128;
    const inner_tile = 16;
    var jj: usize = 0;
    while (jj < cols) : (jj += @min(column_tile, cols - jj)) {
        const end = jj + @min(column_tile, cols - jj);
        var kk: usize = 1;
        while (kk < width) : (kk += @min(inner_tile, width - kk)) {
            const inner_end = kk + @min(inner_tile, width - kk);
            for (0..rows) |i| {
                const dst = out[i * cols + jj .. i * cols + end];
                for (kk..inner_end) |k| {
                    const a = left[i * width + k];
                    const rhs = right[k * cols + jj .. k * cols + end];
                    // Independent contiguous elements allow SIMD without
                    // reassociating floating-point reductions or fast-math.
                    for (dst, rhs) |*c, b| c.* = apply(reduce, c.*, apply(combine, a, b));
                }
            }
        }
    }
}

// Inner products already validate shapes; avoid allocating scalar Values for
// every combine and reduction in the cubic loop.
inline fn apply(comptime op: Function, x: f64, y: f64) f64 {
    if (op == &scalar.add) return x + y;
    if (op == &scalar.mul) return x * y;
    if (op == &scalar.min) return @min(x, y);
    if (op == &scalar.max) return @max(x, y);
    if (op == &scalar.@"and") return @floatFromInt(@intFromBool(x != 0 and y != 0));
    if (op == &scalar.@"or") return @floatFromInt(@intFromBool(x != 0 or y != 0));
    unreachable;
}

pub fn lookup(name: []const u8) ?Function {
    if (std.mem.eql(u8, name, "mul.c")) return complex;
    const suffix = if (std.mem.eql(u8, name, "mul.mat") or std.mem.eql(u8, name, "innerproduct")) return product(&scalar.add, &scalar.mul) else if (std.mem.startsWith(u8, name, "mul.mat.")) name[8..] else if (std.mem.startsWith(u8, name, "innerproduct.")) name[13..] else return null;
    const dot = std.mem.indexOfScalar(u8, suffix, '.') orelse return null;
    if (std.mem.startsWith(u8, name, "mul.mat.")) {
        inline for (.{ .{ "add", "mul" }, .{ "or", "and" }, .{ "min", "add" }, .{ "max", "add" }, .{ "min", "max" }, .{ "max", "min" } }) |ops| {
            if (std.mem.eql(u8, suffix[0..dot], ops[0]) and std.mem.eql(u8, suffix[dot + 1 ..], ops[1])) return product(&@field(scalar, ops[0]), &@field(scalar, ops[1]));
        }
        return null;
    }
    inline for (.{ "add", "mul", "min", "max", "and", "or" }) |op1| {
        inline for (.{ "add", "mul", "min", "max", "and", "or" }) |op2| {
            if (std.mem.eql(u8, suffix[0..dot], op1) and std.mem.eql(u8, suffix[dot + 1 ..], op2)) return product(&@field(scalar, op1), &@field(scalar, op2));
        }
    }
    return null;
}

fn complex(a: std.mem.Allocator, x: Value, y: Value) !Value {
    if (x.tuple != null or y.tuple != null) return error.InvalidInput;
    if (x.shape.len == 0 or y.shape.len == 0 or x.shape[x.shape.len - 1] != 2 or y.shape[y.shape.len - 1] != 2) return error.ShapeMismatch;
    const xs = x.shape[0 .. x.shape.len - 1];
    const ys = y.shape[0 .. y.shape.len - 1];
    const n = @min(xs.len, ys.len);
    if (!std.mem.eql(usize, xs[0..n], ys[0..n])) return error.ShapeMismatch;
    const big = if (xs.len >= ys.len) x else y;
    const data = try a.alloc(f64, big.data.len);
    for (0..data.len / 2) |i| {
        const xi = if (xs.len >= ys.len) i * 2 else i / (big.data.len / x.data.len) * 2;
        const yi = if (ys.len >= xs.len) i * 2 else i / (big.data.len / y.data.len) * 2;
        data[i * 2] = x.data[xi] * y.data[yi] - x.data[xi + 1] * y.data[yi + 1];
        data[i * 2 + 1] = x.data[xi] * y.data[yi + 1] + x.data[xi + 1] * y.data[yi];
    }
    return .{ .data = data, .shape = try a.dupe(usize, big.shape) };
}
