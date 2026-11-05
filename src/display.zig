// MIT License
//
// Copyright (c) 2023 Kaikalii
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

//! Numeric grid layout ported from ../uiua/src/grid_fmt.rs (fmt_array and
//! pad_grid_center). Uiua alternates vertical and horizontal axes, aligns
//! decimal points, and outlines arrays with corners and rank markers.
const std = @import("std");
const Value = @import("runtime.zig").Value;
const Row = std.ArrayList([]const u8);
const Grid = std.ArrayList(Row);

pub fn write(w: *std.Io.Writer, value: Value) (std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    if (value.tuple) |tuple| {
        try w.writeAll("tup( ");
        for (tuple, 0..) |item, i| {
            if (i > 0) try w.writeAll(", ");
            try write(w, item);
        }
        return w.writeAll(" )");
    }
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    if (value.shape.len == 0) return w.writeAll(try number(a, value.data[0]));
    if (value.shape.len == 1 and value.data.len == 0) return w.writeAll("[]");
    var grid: Grid = .empty;
    try cells(a, value.shape, value.data, &grid);
    const columns = grid.items[0].items.len;
    const widths = try a.alloc(usize, columns);
    const lefts = try a.alloc(usize, columns);
    @memset(widths, 0);
    @memset(lefts, 0);
    for (0..columns) |col| {
        var right: ?usize = null;
        for (grid.items) |row| {
            const text = row.items[col];
            const dot = std.mem.indexOfScalar(u8, text, '.');
            lefts[col] = @max(lefts[col], length(if (dot) |d| text[0..d] else text));
            if (dot) |d| right = @max(right orelse 0, length(text[d + 1 ..]));
        }
        widths[col] = lefts[col] + if (right) |r| r + 1 else @as(usize, 0);
    }
    var width: usize = 0;
    for (widths) |n| width += n;
    const vector = value.shape.len == 1;
    const height = if (vector) 1 else @max(grid.items.len + 2, value.shape.len + 1);
    const top = (height - grid.items.len + 1) / 2;
    for (0..height) |line| {
        if (line > 0) try w.writeByte('\n');
        if (vector) {
            try w.writeByte('[');
        } else {
            try w.writeAll(if (line == 0) "╭─" else if (line < value.shape.len) "╷ " else "  ");
        }
        if (vector or (line >= top and line < top + grid.items.len)) {
            const row = grid.items[if (vector) 0 else line - top];
            for (row.items, 0..) |text, col| {
                const dot = std.mem.indexOfScalar(u8, text, '.') orelse text.len;
                const pre = lefts[col] - length(text[0..dot]);
                try w.splatByteAll(' ', pre);
                try w.writeAll(text);
                try w.splatByteAll(' ', widths[col] - pre - length(text));
            }
        } else try w.splatByteAll(' ', width);
        if (vector) try w.writeByte(']') else try w.writeAll(if (line + 1 == height) " ╯" else "  ");
    }
}

fn length(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch unreachable;
}

fn number(a: std.mem.Allocator, n: f64) ![]const u8 {
    const positive = @abs(n);
    const sign: []const u8 = if (std.math.signbit(n)) "¯" else "";
    const special: ?[]const u8 = if (std.math.isNan(n)) "NaN" else if (std.math.isInf(n)) "∞" else if (positive == std.math.pi) "π" else if (positive == 2 * std.math.pi) "τ" else if (positive == std.math.pi / 2.0) "η" else if (positive == std.math.e) "e" else null;
    if (special) |s| return std.fmt.allocPrint(a, "{s}{s}", .{ sign, s });
    return std.fmt.allocPrint(a, "{s}{d}", .{ sign, positive });
}

fn cells(a: std.mem.Allocator, shape: []const usize, data: []const f64, grid: *Grid) !void {
    if (data.len == 0) {
        var text: std.Io.Writer.Allocating = .init(a);
        for (shape, 0..) |dim, i| {
            if (i > 0) try text.writer.writeAll("×");
            try text.writer.print("{d}", .{dim});
        }
        try text.writer.writeAll(" ℝ");
        var row: Row = .empty;
        try row.append(a, text.written());
        try grid.append(a, row);
        return;
    }
    if (shape.len == 1) {
        var row: Row = .empty;
        for (data, 0..) |n, i| {
            const text = try number(a, n);
            try row.append(a, if (i == 0) text else try std.fmt.allocPrint(a, " {s}", .{text}));
        }
        try grid.append(a, row);
        return;
    }
    const start = grid.items.len;
    const stride = data.len / shape[0];
    for (0..shape[0]) |i| {
        if (i > 0 and shape.len > 2 and shape.len % 2 == 0) {
            for (0..(shape.len - 2) / 2) |_| {
                var row: Row = .empty;
                try row.appendNTimes(a, " ", grid.items[grid.items.len - 1].items.len);
                try grid.append(a, row);
            }
        }
        const before = grid.items.len;
        try cells(a, shape[1..], data[i * stride ..][0..stride], grid);
        if (i > 0 and shape.len > 2 and shape.len % 2 == 1) {
            var max_width: usize = 0;
            for (grid.items) |row| for (row.items) |text| {
                max_width = @max(max_width, length(text));
            };
            const divisor: usize = if (max_width > 10) 1 else 2;
            const gap = try a.alloc(u8, (shape.len + divisor - 1) / divisor);
            @memset(gap, ' ');
            // Appending cells may move a row's storage, but not the grid itself.
            for (before..grid.items.len, start..) |source, target| {
                const row = grid.items[source];
                try grid.items[target].append(a, gap);
                try grid.items[target].appendSlice(a, row.items);
            }
            grid.shrinkRetainingCapacity(before);
        }
    }
}
