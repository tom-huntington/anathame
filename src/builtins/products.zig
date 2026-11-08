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
                        const term = try combine(a, .{ .data = x.data[i * width + k ..][0..1] }, .{ .data = y.data[k * cols + j ..][0..1] });
                        defer a.free(term.data);
                        defer a.free(term.shape);
                        if (k == 0) {
                            acc = term.data[0];
                        } else {
                            const next = try reduce(a, .{ .data = (&acc)[0..1] }, term);
                            defer a.free(next.data);
                            defer a.free(next.shape);
                            acc = next.data[0];
                        }
                    }
                    data[i * cols + j] = acc;
                }
            }
            return .{ .data = data, .shape = shape };
        }
    }.call;
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
