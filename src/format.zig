const std = @import("std");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Value = types.Value;
const Managed = std.array_list.Managed;

const GridFmtParams = struct {
    depth: usize = 0,
    parent_rank: usize = 0,
};

const ElemAlign = enum {
    none,
    left,
    right,
    decimal,
};

const Row = Managed(u8);
const Grid = Managed(Row);
const MetaRow = Managed(Grid);
const MetaGrid = Managed(MetaRow);

pub fn valueString(allocator: Allocator, value: Value, is_char: bool) anyerror![]u8 {
    var grid = try fmtValue(allocator, value, is_char, .{});
    defer deinitGrid(&grid);
    return try gridToString(allocator, &grid);
}

pub fn writeValue(writer: *std.Io.Writer, allocator: Allocator, value: Value) anyerror!void {
    const rendered = try valueString(allocator, value, false);
    defer allocator.free(rendered);
    try writer.writeAll(rendered);
}

fn fmtValue(allocator: Allocator, value: Value, is_char: bool, params: GridFmtParams) anyerror!Grid {
    if (params.depth > 100) return gridFromText(allocator, "...");
    return switch (value) {
        .scalar => |scalar| {
            if (is_char) {
                return gridFromCharScalar(allocator, scalar);
            }
            return gridFromOwnedRow(allocator, try formatNumber(allocator, scalar));
        },
        .array => |array| try fmtArrayValue(allocator, array.data, array.shape(), is_char, params),
    };
}

fn fmtArrayValue(
    allocator: Allocator,
    data: []const f64,
    shape: []const usize,
    is_char: bool,
    params: GridFmtParams,
) anyerror!Grid {
    const logical_len = logicalElemCount(shape);
    const bounded_data = data[0..@min(data.len, logical_len)];

    if (shape.len == 0) {
        if (bounded_data.len == 0) return gridFromText(allocator, if (is_char) "\"\"" else "[]");
        const scalar: Value = .{ .scalar = bounded_data[0] };
        return fmtValue(allocator, scalar, is_char, params);
    }

    if (requiresSummary(shape, bounded_data.len)) {
        return gridFromOwnedRow(allocator, try summaryRow(allocator, bounded_data, shape, is_char));
    }

    var metagrid = MetaGrid.init(allocator);
    defer deinitMetaGrid(&metagrid);

    try fmtArray(allocator, bounded_data, shape, is_char, .{
        .depth = params.depth,
        .parent_rank = shape.len,
    }, &metagrid);

    var grid = try synthesizeGrid(allocator, &metagrid, if (is_char) .left else .decimal);
    try outlineGrid(allocator, &grid, shape.len, is_char);
    return grid;
}

fn fmtArray(
    allocator: Allocator,
    data: []const f64,
    shape: []const usize,
    is_char: bool,
    params: GridFmtParams,
    metagrid: *MetaGrid,
) anyerror!void {
    if (shape.len == 0) {
        const scalar: Value = .{ .scalar = data[0] };
        var meta_row = MetaRow.init(allocator);
        try meta_row.append(try fmtValue(allocator, scalar, is_char, params));
        try metagrid.append(meta_row);
        return;
    }

    if (shape[0] == 0) {
        var meta_row = MetaRow.init(allocator);
        try meta_row.append(try gridFromText(allocator, " "));
        try metagrid.append(meta_row);
        return;
    }

    if (shape.len == 1) {
        var meta_row = MetaRow.init(allocator);
        if (is_char) {
            try meta_row.append(try gridFromOwnedRow(allocator, try formatCharVector(allocator, data)));
        } else {
            for (data) |elem| {
                const scalar: Value = .{ .scalar = elem };
                try meta_row.append(try fmtValue(allocator, scalar, is_char, params));
            }
        }
        try metagrid.append(meta_row);
        return;
    }

    const cell_count: usize = shape[0];
    const child_shape = shape[1..];
    const cell_size = if (child_shape.len == 0) 1 else logicalElemCount(child_shape);

    const start_len = metagrid.items.len;
    for (0..cell_count) |i| {
        if (i > 0 and shape.len > 2 and shape.len % 2 == 0) {
            const width = if (metagrid.items.len > 0) metagrid.items[metagrid.items.len - 1].items.len else 1;
            for (0..(shape.len - 2) / 2) |_| {
                var spacer = MetaRow.init(allocator);
                for (0..width) |_| {
                    try spacer.append(try gridFromText(allocator, " "));
                }
                try metagrid.append(spacer);
            }
        }

        const before = metagrid.items.len;
        const start = i * cell_size;
        try fmtArray(allocator, data[start .. start + cell_size], child_shape, is_char, params, metagrid);

        if (i > 0 and shape.len % 2 == 1) {
            var split_rows = Managed(MetaRow).init(allocator);
            defer split_rows.deinit();
            while (metagrid.items.len > before) {
                try split_rows.insert(0, metagrid.pop().?);
            }
            var row_index: usize = 0;
            while (row_index < split_rows.items.len) : (row_index += 1) {
                const target_index = start_len + row_index;
                if (target_index >= metagrid.items.len) break;
                try metagrid.items[target_index].append(try gridFromText(allocator, " "));
                for (split_rows.items[row_index].items) |grid| {
                    try metagrid.items[target_index].append(grid);
                }
                split_rows.items[row_index].items.len = 0;
                split_rows.items[row_index].deinit();
            }
        }
    }
}

fn synthesizeGrid(allocator: Allocator, metagrid: *MetaGrid, alignment: ElemAlign) !Grid {
    var result = Grid.init(allocator);
    if (metagrid.items.len == 0) return result;

    var width: usize = 0;
    for (metagrid.items) |meta_row| {
        width = @max(width, meta_row.items.len);
    }

    const row_heights = try allocator.alloc(usize, metagrid.items.len);
    defer allocator.free(row_heights);
    const col_widths = try allocator.alloc(usize, width);
    defer allocator.free(col_widths);
    @memset(col_widths, 0);

    for (metagrid.items, 0..) |meta_row, row_index| {
        var row_height: usize = 1;
        for (meta_row.items) |*cell| {
            row_height = @max(row_height, cell.items.len);
        }
        row_heights[row_index] = row_height;
    }

    for (0..width) |col| {
        var col_width: usize = 0;
        for (metagrid.items) |meta_row| {
            if (col >= meta_row.items.len) continue;
            for (meta_row.items[col].items) |cell_row| {
                col_width = @max(col_width, rowVisualWidth(cell_row.items));
            }
        }
        col_widths[col] = col_width;
    }

    for (metagrid.items, 0..) |*meta_row, row_index| {
        const row_height = row_heights[row_index];
        const subrows = try allocator.alloc(Row, row_height);
        var moved_rows = false;
        defer {
            if (!moved_rows) {
                for (subrows) |*row| row.deinit();
            }
            allocator.free(subrows);
        }
        for (subrows) |*row| row.* = Row.init(allocator);

        for (0..width) |col| {
            var cell = if (col < meta_row.items.len) meta_row.items[col] else try gridFromText(allocator, "");
            defer if (col >= meta_row.items.len) deinitGrid(&cell);
            try padGridCenter(allocator, &cell, col_widths[col], row_height, alignment);

            for (subrows, cell.items) |*subrow, cell_row| {
                if (col > 0) try subrow.append(' ');
                try subrow.appendSlice(cell_row.items);
            }
        }

        for (subrows) |subrow| try result.append(subrow);
        moved_rows = true;
    }

    return result;
}

fn outlineGrid(allocator: Allocator, grid: *Grid, rank: usize, is_char: bool) !void {
    if (grid.items.len == 0) return;

    if (rank == 1 and grid.items.len == 1) {
        const left: u8 = if (is_char) '"' else '[';
        const right: u8 = if (is_char) '"' else ']';
        try grid.items[0].insert(0, left);
        try grid.items[0].append(right);
        return;
    }

    const inner_width = maxGridWidth(grid.*);
    var top = Row.init(allocator);
    var bottom = Row.init(allocator);
    try top.appendSlice("╭");
    for (0..inner_width + 2) |_| try top.appendSlice("─");
    try top.appendSlice("╮");
    try bottom.appendSlice("╰");
    for (0..inner_width + 2) |_| try bottom.appendSlice("─");
    try bottom.appendSlice("╯");

    for (grid.items) |*row| {
        const rendered_width = rowVisualWidth(row.items);
        var padded = Row.init(allocator);
        try padded.appendSlice("│ ");
        try padded.appendSlice(row.items);
        for (0..inner_width - rendered_width + 1) |_| try padded.append(' ');
        try padded.appendSlice("│");
        row.deinit();
        row.* = padded;
    }

    try grid.insert(0, top);
    try grid.append(bottom);
}

fn requiresSummary(shape: []const usize, elem_count: usize) bool {
    return elem_count > 3600 or shape.len > 8;
}

fn logicalElemCount(shape: []const usize) usize {
    var len: usize = 1;
    for (shape) |dim| {
        len *= dim;
    }
    return len;
}

fn summaryRow(allocator: Allocator, data: []const f64, shape: []const usize, is_char: bool) ![]u8 {
    var out = Row.init(allocator);
    errdefer out.deinit();
    try appendShape(&out, shape, is_char);
    try out.appendSlice(": ");
    if (is_char) {
        try out.appendSlice("string");
    } else {
        var min = data[0];
        var max = data[0];
        var mean: f64 = 0;
        for (data, 0..) |elem, i| {
            min = @min(min, elem);
            max = @max(max, elem);
            mean += (elem - mean) / @as(f64, @floatFromInt(i + 1));
        }
        const min_s = try formatNumber(allocator, min);
        defer allocator.free(min_s);
        const max_s = try formatNumber(allocator, max);
        defer allocator.free(max_s);
        const mean_s = try formatNumber(allocator, mean);
        defer allocator.free(mean_s);
        try out.appendSlice(min_s);
        try out.append('-');
        try out.appendSlice(max_s);
        try out.appendSlice(" u");
        try out.appendSlice(mean_s);
    }
    return out.toOwnedSlice();
}

fn appendShape(out: *Row, shape: []const usize, is_char: bool) !void {
    for (shape, 0..) |dim, i| {
        if (i > 0) try out.appendSlice("x");
        try out.writer().print("{}", .{dim});
    }
    if (shape.len > 0) try out.append(' ');
    try out.appendSlice(if (is_char) "char" else "num");
}

fn gridFromText(allocator: Allocator, text: []const u8) !Grid {
    return gridFromOwnedRow(allocator, try allocator.dupe(u8, text));
}

fn gridFromOwnedRow(allocator: Allocator, row_bytes: []u8) !Grid {
    var row = Row.init(allocator);
    errdefer row.deinit();
    try row.appendSlice(row_bytes);
    allocator.free(row_bytes);

    var grid = Grid.init(allocator);
    try grid.append(row);
    return grid;
}

fn gridFromCharScalar(allocator: Allocator, value: f64) !Grid {
    const inner = try formatCharInner(allocator, value);
    defer allocator.free(inner);
    var row = Row.init(allocator);
    errdefer row.deinit();
    try row.append('@');
    try row.appendSlice(inner);
    var grid = Grid.init(allocator);
    try grid.append(row);
    return grid;
}

fn formatCharVector(allocator: Allocator, data: []const f64) ![]u8 {
    var out = Row.init(allocator);
    errdefer out.deinit();
    for (data) |elem| {
        const inner = try formatCharInner(allocator, elem);
        defer allocator.free(inner);
        try out.appendSlice(inner);
    }
    return out.toOwnedSlice();
}

fn formatCharInner(allocator: Allocator, value: f64) ![]u8 {
    if (!std.math.isFinite(value) or value < 0 or value > 255) {
        return allocator.dupe(u8, "?");
    }
    const ch: u8 = @intFromFloat(value);
    return switch (ch) {
        ' ' => allocator.dupe(u8, "\\s"),
        '\n' => allocator.dupe(u8, "\\n"),
        '\r' => allocator.dupe(u8, "\\r"),
        '\t' => allocator.dupe(u8, "\\t"),
        '\\' => allocator.dupe(u8, "\\\\"),
        '"' => allocator.dupe(u8, "\\\""),
        '\'' => allocator.dupe(u8, "'"),
        else => if (std.ascii.isPrint(ch))
            allocator.dupe(u8, &.{ch})
        else
            std.fmt.allocPrint(allocator, "\\x{x:0>2}", .{ch}),
    };
}

fn formatNumber(allocator: Allocator, value: f64) ![]u8 {
    const positive = @abs(value);
    const is_neg = std.math.signbit(value);
    const minus = if (is_neg) "¯" else "";

    if (std.math.isNan(value)) return std.fmt.allocPrint(allocator, "{s}NaN", .{minus});
    if (positive == std.math.inf(f64)) return std.fmt.allocPrint(allocator, "{s}∞", .{minus});
    if (approxEq(positive, std.math.pi)) return std.fmt.allocPrint(allocator, "{s}π", .{minus});
    if (approxEq(positive, std.math.tau)) return std.fmt.allocPrint(allocator, "{s}τ", .{minus});
    if (approxEq(positive, std.math.pi / 2.0)) return std.fmt.allocPrint(allocator, "{s}η", .{minus});
    if (approxEq(positive, std.math.e)) return std.fmt.allocPrint(allocator, "{s}e", .{minus});

    if (positive == @floor(positive)) {
        return std.fmt.allocPrint(allocator, "{s}{d:.0}", .{ minus, positive });
    }

    inline for (.{ 1, 2, 3, 4, 5, 6, 8, 9, 12 }) |denom| {
        const num = (positive * @as(f64, @floatFromInt(denom))) / std.math.tau;
        const rounded = @round(num);
        if (rounded != 0 and rounded <= 100 and approxEq(num, rounded)) {
            if (denom == 1) return std.fmt.allocPrint(allocator, "{s}{d:.0}τ", .{ minus, rounded });
            if (denom == 2) {
                if (rounded == 1) return std.fmt.allocPrint(allocator, "{s}π", .{minus});
                return std.fmt.allocPrint(allocator, "{s}{d:.0}π", .{ minus, rounded });
            }
            if (denom == 4) {
                if (rounded == 1) return std.fmt.allocPrint(allocator, "{s}η", .{minus});
                return std.fmt.allocPrint(allocator, "{s}{d:.0}η", .{ minus, rounded });
            }
            if (rounded == 1) return std.fmt.allocPrint(allocator, "{s}τ/{}", .{ minus, denom });
            return std.fmt.allocPrint(allocator, "{s}{d:.0}τ/{}", .{ minus, rounded, denom });
        }
    }

    const rendered = try std.fmt.allocPrint(allocator, "{d}", .{positive});
    if (rendered.len >= 17) compressRepeatingDigits(rendered);
    if (is_neg) {
        defer allocator.free(rendered);
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ minus, rendered });
    }
    return rendered;
}

fn compressRepeatingDigits(text: []u8) void {
    var best_start: usize = 0;
    var best_len: usize = 0;
    var saw_decimal = false;
    for (text, 0..) |c, i| {
        if (c == '.') {
            saw_decimal = true;
            continue;
        }
        if (!saw_decimal) continue;
        var run_len: usize = 0;
        var j = i + 1;
        while (j < text.len and text[j] == c) : (j += 1) {
            run_len += 1;
        }
        if (run_len > best_len) {
            best_start = i;
            best_len = run_len;
        }
    }
    if (best_len >= 5 and best_start + 3 < text.len) {
        text[best_start + 2] = '.';
        for (best_start + 3..text.len) |k| {
            _ = k;
        }
        text[best_start + 3] = '.';
        if (best_start + 4 < text.len) text[best_start + 4] = '.';
    }
}

fn approxEq(a: f64, b: f64) bool {
    return @abs(a - b) <= 8.0 * std.math.floatEps(f64);
}

fn padGridCenter(allocator: Allocator, grid: *Grid, width: usize, height: usize, alignment: ElemAlign) !void {
    while (grid.items.len < height) {
        try grid.insert(0, Row.init(allocator));
    }
    if (grid.items.len > height) {
        while (grid.items.len > height) {
            var removed = grid.pop().?;
            removed.deinit();
        }
    }
    for (grid.items) |*row| {
        const rendered_width = rowVisualWidth(row.items);
        if (rendered_width >= width) continue;
        const diff = width - rendered_width;
        const pre = switch (alignment) {
            .left => 0,
            .right => diff,
            .none => diff / 2,
            .decimal => diff,
        };
        const post = diff - pre;

        var padded = Row.init(allocator);
        try padded.ensureTotalCapacity(pre + row.items.len + post);
        for (0..pre) |_| try padded.append(' ');
        try padded.appendSlice(row.items);
        for (0..post) |_| try padded.append(' ');
        row.deinit();
        row.* = padded;
    }
}

fn rowVisualWidth(row: []const u8) usize {
    var i: usize = 0;
    var width: usize = 0;
    while (i < row.len) {
        i += std.unicode.utf8ByteSequenceLength(row[i]) catch 1;
        width += 1;
    }
    return width;
}

fn maxGridWidth(grid: Grid) usize {
    var width: usize = 0;
    for (grid.items) |row| width = @max(width, rowVisualWidth(row.items));
    return width;
}

fn gridToString(allocator: Allocator, grid: *Grid) ![]u8 {
    var out = Row.init(allocator);
    errdefer out.deinit();
    for (grid.items, 0..) |row, i| {
        if (i > 0) try out.append('\n');
        try out.appendSlice(row.items);
    }
    return out.toOwnedSlice();
}

fn deinitGrid(grid: *Grid) void {
    for (grid.items) |*row| row.deinit();
    grid.deinit();
}

fn deinitMetaGrid(metagrid: *MetaGrid) void {
    for (metagrid.items) |*meta_row| {
        for (meta_row.items) |*grid| deinitGrid(grid);
        meta_row.deinit();
    }
    metagrid.deinit();
}
