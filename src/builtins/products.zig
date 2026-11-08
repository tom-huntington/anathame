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
            for (0..rows) |i| {
                for (0..cols) |j| {
                    var acc: f64 = if (reduce == &scalar.add or reduce == &scalar.@"or") 0 else if (reduce == &scalar.mul or reduce == &scalar.@"and") 1 else if (reduce == &scalar.min) std.math.inf(f64) else if (reduce == &scalar.max) -std.math.inf(f64) else return error.InvalidInput;
                    for (0..width) |k| {
                        const term = apply(combine, x.data[i * width + k], y.data[k * cols + j]);
                        acc = if (k == 0) term else apply(reduce, acc, term);
                        // Boolean OR cannot change after the first true term.
                        if (reduce == &scalar.@"or" and combine == &scalar.@"and" and acc != 0) break;
                    }
                    data[i * cols + j] = acc;
                }
            }
            return .{ .data = data, .shape = shape };
        }
    }.call;
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
