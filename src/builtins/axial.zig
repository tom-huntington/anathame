//! Operations whose behavior depends on an axis or component.
//! Existing conventions are preserved here pending the general axis-selector implementation.

const std = @import("std");
const Value = @import("../runtime.zig").Value;

/// Keep first occurrences independently in each trailing-axis vector.
pub fn deduplicate(a: std.mem.Allocator, x: Value, _: Value) !Value {
    if (x.tuple != null) return error.ExpectedArray;
    if (x.shape.len == 0) return x;
    return deduplicateComponents(a, x, 0);
}

/// Deduplicate cells along the axis preceding the selected component dimensions.
pub fn deduplicateComponents(a: std.mem.Allocator, x: Value, dimensions: usize) !Value {
    if (x.tuple != null) return error.ExpectedArray;
    if (dimensions >= x.shape.len) return error.InvalidAxis;
    const axis = x.shape.len - dimensions - 1;
    const width = x.shape[axis];
    var cell_size: usize = 1;
    for (x.shape[axis + 1 ..]) |dim| cell_size = try std.math.mul(usize, cell_size, dim);
    var groups: usize = 1;
    for (x.shape[0..axis]) |dim| groups = try std.math.mul(usize, groups, dim);
    const Context = struct {
        fn key(item: f64) u64 {
            // Uiua considers all NaNs equal, as well as signed zeros.
            return if (std.math.isNan(item)) 0x7ff8000000000000 else if (item == 0) 0 else @bitCast(item);
        }
        pub fn hash(_: @This(), items: []const f64) u64 {
            var hasher = std.hash.Wyhash.init(0);
            for (items) |item| {
                const bits = key(item);
                hasher.update(std.mem.asBytes(&bits));
            }
            return hasher.final();
        }
        pub fn eql(_: @This(), lhs: []const f64, rhs: []const f64) bool {
            if (lhs.len != rhs.len) return false;
            for (lhs, rhs) |l, r| if (key(l) != key(r)) return false;
            return true;
        }
    };
    var seen: std.HashMap([]const f64, void, Context, std.hash_map.default_max_load_percentage) = .init(a);
    defer seen.deinit();
    var data: std.ArrayList(f64) = .empty;
    defer data.deinit(a);
    var result_width: ?usize = null;
    for (0..groups) |group| {
        seen.clearRetainingCapacity();
        var unique_count: usize = 0;
        for (0..width) |i| {
            const start = (group * width + i) * cell_size;
            const cell = x.data[start..][0..cell_size];
            const entry = try seen.getOrPut(cell);
            if (!entry.found_existing) {
                try data.appendSlice(a, cell);
                unique_count += 1;
            }
        }
        if (result_width) |expected| {
            if (unique_count != expected) return error.ShapeMismatch;
        } else result_width = unique_count;
    }
    const shape = try a.dupe(usize, x.shape);
    errdefer a.free(shape);
    shape[axis] = result_width orelse width;
    return .{ .data = try data.toOwnedSlice(a), .shape = shape };
}

/// Euclidean distance, reducing the trailing axis after pervasive subtraction.
/// Scalars return their absolute difference; empty vectors have distance zero.
pub fn distance(a: std.mem.Allocator, x: Value, y: Value) !Value {
    const result = try quadrance(a, x, y);
    for (@constCast(result.data)) |*item| item.* = @sqrt(item.*);
    return result;
}

/// Squared Euclidean distance, reducing the trailing axis after pervasive subtraction.
/// Scalars return their squared difference; empty vectors have quadrance zero.
pub fn quadrance(a: std.mem.Allocator, x: Value, y: Value) !Value {
    const difference = try @import("pervasives.zig").sub(a, x, y);
    defer a.free(difference.data);
    defer a.free(difference.shape);
    const rank = difference.shape.len;
    const shape = difference.shape[0 .. rank - @intFromBool(rank != 0)];
    var cells: usize = 1;
    for (shape) |dim| cells = try std.math.mul(usize, cells, dim);
    const width = if (rank == 0) 1 else difference.shape[rank - 1];
    const data = try a.alloc(f64, cells);
    errdefer a.free(data);
    for (data, 0..) |*result, cell| {
        var sum: f64 = 0;
        for (difference.data[cell * width ..][0..width]) |delta| sum += delta * delta;
        result.* = sum;
    }
    return .{ .data = data, .shape = try a.dupe(usize, shape) };
}

/// Keep every nth element along the trailing axis, starting with the first.
pub fn stride(a: std.mem.Allocator, x: Value, step: Value) !Value {
    return strideAxis(a, x, step, 1);
}

/// Keep every nth row along axis -2 in each outer cell.
pub fn @"stride.rows"(a: std.mem.Allocator, x: Value, step: Value) !Value {
    return strideAxis(a, x, step, 2);
}

fn strideAxis(a: std.mem.Allocator, x: Value, step: Value, depth: usize) !Value {
    if (x.tuple != null) return error.ExpectedArray;
    if (step.tuple != null or step.shape.len != 0 or step.data.len != 1)
        return error.InvalidInput;
    const n = step.data[0];
    if (!std.math.isFinite(n) or n <= 0 or @trunc(n) != n or
        n >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return error.InvalidInput;
    const amount: usize = @intFromFloat(n);
    if (x.shape.len < depth) return x;
    const axis = x.shape.len - depth;
    const size = x.shape[axis];
    const selected = size / amount + @intFromBool(size % amount != 0);
    const shape = try a.dupe(usize, x.shape);
    errdefer a.free(shape);
    shape[axis] = selected;
    var width: usize = 1;
    for (x.shape[axis + 1 ..]) |dim| width = try std.math.mul(usize, width, dim);
    var cells: usize = 1;
    for (x.shape[0..axis]) |dim| cells = try std.math.mul(usize, cells, dim);
    const data = try a.alloc(f64, try std.math.mul(usize, cells, try std.math.mul(usize, selected, width)));
    for (0..cells) |cell| {
        for (0..selected) |i| {
            const source = (cell * size + i * amount) * width;
            const dest = (cell * selected + i) * width;
            @memcpy(data[dest..][0..width], x.data[source..][0..width]);
        }
    }
    return .{ .data = data, .shape = shape };
}

/// Select the last row along axis -2 in each outer cell, removing that axis.
/// Scalars and vectors have no row axis and are returned unchanged.
pub fn @"last.row"(a: std.mem.Allocator, x: Value, _: Value) !Value {
    if (x.tuple != null) return error.ExpectedArray;
    if (x.shape.len < 2) return x;
    const axis = x.shape.len - 2;
    const rows = x.shape[axis];
    if (rows == 0) return error.InvalidInput;
    const width = x.shape[axis + 1];
    var cells: usize = 1;
    for (x.shape[0..axis]) |dim| cells = try std.math.mul(usize, cells, dim);
    const shape = try a.alloc(usize, x.shape.len - 1);
    errdefer a.free(shape);
    @memcpy(shape[0..axis], x.shape[0..axis]);
    shape[axis] = width;
    const data = try a.alloc(f64, try std.math.mul(usize, cells, width));
    for (0..cells) |cell| {
        const start = (cell * rows + rows - 1) * width;
        @memcpy(data[cell * width ..][0..width], x.data[start..][0..width]);
    }
    return .{ .data = data, .shape = shape };
}

/// Reverse the trailing axis, preserving the order of all outer axes.
pub fn reverse(a: std.mem.Allocator, x: Value, _: Value) !Value {
    if (x.tuple != null) return error.ExpectedArray;
    const data = try a.dupe(f64, x.data);
    const width = if (x.shape.len == 0) 1 else x.shape[x.shape.len - 1];
    if (width > 1) {
        var offset: usize = 0;
        while (offset < data.len) : (offset += width) {
            std.mem.reverse(f64, data[offset..][0..width]);
        }
    }
    return .{ .data = data, .shape = x.shape };
}

/// Number of leading-axis rows; scalars have one row.
pub fn length(a: std.mem.Allocator, x: Value, _: Value) !Value {
    if (x.tuple != null) return error.ExpectedArray;
    const data = try a.alloc(f64, 1);
    data[0] = @floatFromInt(if (x.shape.len == 0) @as(usize, 1) else x.shape[0]);
    return .{ .data = data };
}

/// Count occurrences of scalar y among the elements of array x.
pub fn count(a: std.mem.Allocator, x: Value, y: Value) !Value {
    if (x.tuple != null or y.tuple != null or y.shape.len != 0 or y.data.len != 1)
        return error.InvalidInput;
    var occurrences: usize = 0;
    for (x.data) |item| {
        if (item == y.data[0]) occurrences += 1;
    }
    return .{ .data = try a.dupe(f64, &.{@floatFromInt(occurrences)}) };
}

/// Parse a scalar character or character vector as a number.
pub fn parse(a: std.mem.Allocator, x: Value, _: Value) !Value {
    if (x.tuple != null or x.shape.len > 1) return error.InvalidInput;
    const bytes = try a.alloc(u8, try std.math.mul(usize, x.data.len, 4));
    defer a.free(bytes);
    var len: usize = 0;
    for (x.data) |value| {
        if (!std.math.isFinite(value) or value < 0 or value > 0x10ffff or
            @trunc(value) != value) return error.InvalidInput;
        const codepoint: u21 = @intFromFloat(value);
        len += std.unicode.utf8Encode(codepoint, bytes[len..]) catch return error.InvalidInput;
    }
    const number = std.fmt.parseFloat(f64, bytes[0..len]) catch return error.InvalidInput;
    return .{ .data = try a.dupe(f64, &.{number}) };
}

/// Extract contiguous runs of ASCII digits along the trailing axis, skipping empty rows.
pub fn ints(a: std.mem.Allocator, x: Value, _: Value) !Value {
    if (x.tuple != null) return error.InvalidInput;
    if (x.shape.len <= 1) return @import("axis_agnostic.zig").extractNumbers(a, x, false, true);
    const cell_width = x.shape[x.shape.len - 1];
    var cells: usize = 1;
    for (x.shape[0 .. x.shape.len - 1]) |dim| cells = try std.math.mul(usize, cells, dim);
    var numbers: std.ArrayList(f64) = .empty;
    defer numbers.deinit(a);
    var width: ?usize = null;
    var rows: usize = 0;
    var first_row: usize = 0;
    for (0..cells) |i| {
        const row = try @import("axis_agnostic.zig").extractNumbers(a, .{
            .data = x.data[i * cell_width ..][0..cell_width],
            .shape = &.{cell_width},
        }, false, true);
        defer a.free(row.data);
        defer a.free(row.shape);
        if (row.data.len == 0) continue;
        if (width) |expected| {
            if (row.data.len != expected) return @import("../runtime.zig").shapeMismatchIndexed(@src().fn_name, &.{
                .{ .data = numbers.items[0..expected], .shape = &.{expected} }, row,
            }, &.{ first_row, i });
        } else {
            width = row.data.len;
            first_row = i;
        }
        try numbers.appendSlice(a, row.data);
        rows += 1;
    }
    const shape = if (rows == cells)
        try a.dupe(usize, x.shape)
    else
        try a.dupe(usize, &.{ rows, width orelse 0 });
    errdefer a.free(shape);
    shape[shape.len - 1] = width orelse 0;
    return .{ .data = try numbers.toOwnedSlice(a), .shape = shape };
}

/// Split array rows or tuple elements at an integer index; negative indices count from the end.
fn splitRowsAt(a: std.mem.Allocator, x: Value, index: Value) !Value {
    if ((x.tuple == null and x.shape.len == 0) or index.tuple != null or
        index.shape.len != 0 or index.data.len != 1) return error.InvalidInput;
    const row_count = index.data[0];
    if (!std.math.isFinite(row_count) or @trunc(row_count) != row_count) return error.InvalidInput;
    const item_count = if (x.tuple) |items| items.len else x.shape[0];
    if (@abs(row_count) > @as(f64, @floatFromInt(item_count))) return @import("../runtime.zig").shapeMismatch(@src().fn_name, &.{ x, index });
    const amount: usize = @intFromFloat(@abs(row_count));
    const split_index = if (row_count < 0) item_count - amount else amount;
    if (x.tuple) |items| {
        return .{ .tuple = try a.dupe(Value, &.{
            .{ .tuple = items[0..split_index] },
            .{ .tuple = items[split_index..] },
        }) };
    }
    var row_size: usize = 1;
    for (x.shape[1..]) |dim| row_size = try std.math.mul(usize, row_size, dim);
    const left_shape = try a.dupe(usize, x.shape);
    const right_shape = try a.dupe(usize, x.shape);
    left_shape[0] = split_index;
    right_shape[0] -= split_index;
    const values = try a.alloc(Value, 2);
    values[0] = .{ .data = x.data[0 .. split_index * row_size], .shape = left_shape };
    values[1] = .{ .data = x.data[split_index * row_size ..], .shape = right_shape };
    return .{ .tuple = values };
}

/// Split off the first element of each trailing vector.
pub fn uncons(a: std.mem.Allocator, x: Value, _: Value) !Value {
    return unconsComponents(a, x, 0);
}

pub fn unconsComponents(a: std.mem.Allocator, x: Value, dimensions: usize) !Value {
    if (x.tuple != null) return error.ExpectedArray;
    if (dimensions >= x.shape.len) return error.InvalidAxis;
    const axis = x.shape.len - dimensions - 1;
    const width = x.shape[axis];
    if (width == 0) return error.EmptyArray;
    const cell_shape = x.shape[axis + 1 ..];
    var cell_size: usize = 1;
    for (cell_shape) |dim| cell_size *= dim;
    var frames: usize = 1;
    for (x.shape[0..axis]) |dim| frames *= dim;
    const shape = try std.mem.concat(a, usize, &.{ x.shape[0..axis], cell_shape });
    const data = try a.alloc(f64, frames * cell_size);
    const rest = try a.alloc(f64, frames * (width - 1) * cell_size);
    for (0..frames) |i| {
        const start = i * width * cell_size;
        @memcpy(data[i * cell_size ..][0..cell_size], x.data[start..][0..cell_size]);
        @memcpy(rest[i * (width - 1) * cell_size ..][0 .. (width - 1) * cell_size], x.data[start + cell_size ..][0 .. (width - 1) * cell_size]);
    }
    const rest_shape = try a.dupe(usize, x.shape);
    rest_shape[axis] -= 1;
    return .{ .tuple = try a.dupe(Value, &.{ .{ .data = data, .shape = shape }, .{ .data = rest, .shape = rest_shape } }) };
}

/// Take array rows or tuple elements from the front, or from the back for a negative count.
pub fn take(a: std.mem.Allocator, x: Value, row_count: Value) !Value {
    const parts = try splitRowsAt(a, x, row_count);
    return parts.tuple.?[if (row_count.data[0] < 0) @as(usize, 1) else 0];
}

/// Drop array rows or tuple elements from the front, or from the back for a negative count.
pub fn drop(a: std.mem.Allocator, x: Value, row_count: Value) !Value {
    const parts = try splitRowsAt(a, x, row_count);
    return parts.tuple.?[if (row_count.data[0] < 0) @as(usize, 0) else 1];
}

/// Prepend a row y to the leading axis of array x.
pub fn prepend(a: std.mem.Allocator, x: Value, y: Value) !Value {
    if (x.tuple != null or y.tuple != null) return error.ExpectedArray;
    if (x.shape.len == 0 or !std.mem.eql(usize, x.shape[1..], y.shape)) return @import("../runtime.zig").shapeMismatch(@src().fn_name, &.{ x, y });
    const shape = try a.dupe(usize, x.shape);
    shape[0] = try std.math.add(usize, shape[0], 1);
    const data = try a.alloc(f64, try std.math.add(usize, x.data.len, y.data.len));
    @memcpy(data[0..y.data.len], y.data);
    @memcpy(data[y.data.len..], x.data);
    return .{ .data = data, .shape = shape };
}

/// Search each trailing vector by default.
pub fn indexin(a: std.mem.Allocator, haystack: Value, needle: Value) !Value {
    return indexinComponents(a, haystack, needle, 1);
}

/// Search selected components; matrix coordinates list the innermost axis first.
pub fn indexinComponents(a: std.mem.Allocator, haystack: Value, needle: Value, dimensions: usize) !Value {
    if (haystack.tuple != null or needle.tuple != null) return error.InvalidInput;
    if (dimensions == 0) return error.InvalidAxis;
    if (haystack.shape.len <= dimensions) return indexinCell(a, haystack, needle);
    const frame = haystack.shape[0 .. haystack.shape.len - dimensions];
    const cell_shape = haystack.shape[frame.len..];
    var cells: usize = 1;
    for (frame) |dim| cells = try std.math.mul(usize, cells, dim);
    var size: usize = 1;
    for (cell_shape) |dim| size = try std.math.mul(usize, size, dim);
    // A prototype preserves the result shape even when the outer frame is empty.
    const prototype = if (cells == 0) blk: {
        const buffer = try a.alloc(f64, size);
        @memset(buffer, 0);
        break :blk buffer;
    } else haystack.data[0..size];
    defer if (cells == 0) a.free(prototype);
    const first = try indexinCell(a, .{ .data = prototype, .shape = cell_shape }, needle);
    defer a.free(first.data);
    defer a.free(first.shape);
    const shape = try std.mem.concat(a, usize, &.{ frame, first.shape });
    const data = try a.alloc(f64, try std.math.mul(usize, cells, first.data.len));
    if (cells > 0) @memcpy(data[0..first.data.len], first.data);
    for (1..@max(1, cells)) |i| {
        const result = try indexinCell(a, .{ .data = haystack.data[i * size ..][0..size], .shape = cell_shape }, needle);
        defer a.free(result.data);
        defer a.free(result.shape);
        @memcpy(data[i * first.data.len ..][0..first.data.len], result.data);
    }
    return .{ .data = data, .shape = shape };
}

fn indexinCell(a: std.mem.Allocator, haystack: Value, needle: Value) !Value {
    const rank = haystack.shape.len;
    if (rank <= 1) return indexinRows(a, haystack, needle);
    const shape = try std.mem.concat(a, usize, &.{ needle.shape, &.{rank} });
    const data = try a.alloc(f64, try std.math.mul(usize, needle.data.len, rank));
    for (needle.data, 0..) |wanted, i| {
        const coordinates = data[i * rank ..][0..rank];
        var found: ?usize = null;
        for (haystack.data, 0..) |candidate, j| {
            if (candidate == wanted or (std.math.isNan(candidate) and std.math.isNan(wanted))) {
                found = j;
                break;
            }
        }
        if (found) |index| {
            var remaining = index;
            for (coordinates, 0..) |*coordinate, axis| {
                const width = haystack.shape[rank - axis - 1];
                coordinate.* = @floatFromInt(remaining % width);
                remaining /= width;
            }
        } else {
            for (coordinates, 0..) |*coordinate, axis|
                coordinate.* = @floatFromInt(haystack.shape[rank - axis - 1]);
        }
    }
    return .{ .data = data, .shape = shape };
}

/// Uiua indexin: find each needle row in the haystack (the first argument).
/// Missing rows return the haystack's row count; duplicate rows use the first index.
fn indexinRows(a: std.mem.Allocator, haystack: Value, needle: Value) !Value {
    if (haystack.tuple != null or needle.tuple != null) return error.InvalidInput;
    const hay_rows = if (haystack.shape.len == 0) 1 else haystack.shape[0];
    const needle_rows = if (needle.shape.len == 0) 1 else needle.shape[0];
    if (needle.shape.len == haystack.shape.len or needle.shape.len + 1 == haystack.shape.len) {
        const same_rank = needle.shape.len == haystack.shape.len;
        const shape = if (same_rank) needle.shape[0..@min(1, needle.shape.len)] else &.{};
        const data = try a.alloc(f64, if (same_rank) needle_rows else 1);
        const hay_width = rowWidth(haystack);
        const needle_width = if (same_rank) rowWidth(needle) else needle.data.len;
        for (data, 0..) |*result, i| {
            result.* = @floatFromInt(hay_rows);
            if (!same_rank and !std.mem.endsWith(usize, haystack.shape, needle.shape)) continue;
            const wanted = needle.data[i * needle_width ..][0..needle_width];
            for (0..hay_rows) |j| {
                const candidate = haystack.data[j * hay_width ..][0..hay_width];
                if (candidate.len != wanted.len) continue;
                for (candidate, wanted) |x, y| {
                    if (x != y and !(std.math.isNan(x) and std.math.isNan(y))) break;
                } else {
                    result.* = @floatFromInt(j);
                    break;
                }
            }
        }
        return .{ .data = data, .shape = try a.dupe(usize, shape) };
    }
    const recurse_needle = needle.shape.len > haystack.shape.len;
    if (recurse_needle and needle_rows == 0) return .{ .data = try a.dupe(f64, needle.data), .shape = try a.dupe(usize, needle.shape) };
    if (!recurse_needle and !std.mem.endsWith(usize, haystack.shape, needle.shape)) {
        const shape = haystack.shape[0 .. haystack.shape.len - needle.shape.len - 1];
        var item_count: usize = 1;
        for (shape) |dim| item_count = try std.math.mul(usize, item_count, dim);
        const data = try a.alloc(f64, item_count);
        @memset(data, @as(f64, @floatFromInt(hay_rows)));
        return .{ .data = data, .shape = try a.dupe(usize, shape) };
    }
    const source = if (recurse_needle) needle else haystack;
    const rows = source.shape[0];
    const width = rowWidth(source);
    var data: std.ArrayList(f64) = .empty;
    errdefer data.deinit(a);
    var shape: []const usize = &.{0};
    for (0..rows) |i| {
        const row: Value = .{ .data = source.data[i * width ..][0..width], .shape = source.shape[1..] };
        const result = if (recurse_needle) try indexinRows(a, haystack, row) else try indexinRows(a, row, needle);
        defer a.free(result.data);
        defer a.free(result.shape);
        if (i == 0) {
            const dimensions = try a.alloc(usize, result.shape.len + 1);
            dimensions[0] = rows;
            @memcpy(dimensions[1..], result.shape);
            shape = dimensions;
        }
        try data.appendSlice(a, result.data);
    }
    return .{ .data = try data.toOwnedSlice(a), .shape = if (rows == 0) try a.dupe(usize, shape) else shape };
}

fn rowWidth(value: Value) usize {
    var width: usize = 1;
    for (value.shape[@min(1, value.shape.len)..]) |dim| width *= dim;
    return width;
}

/// Select array rows or tuple elements. Negative indices count from the end.
/// Scalar indices remove the selected array axis or unwrap a tuple element.
pub fn select(a: std.mem.Allocator, source: Value, indices: Value) !Value {
    if (indices.tuple != null) return error.InvalidInput;
    if (source.tuple) |items| {
        if (indices.shape.len == 0) {
            if (indices.data.len != 1) return error.InvalidInput;
            return items[try selectionIndex(indices.data[0], items.len)];
        }
        if (indices.shape.len != 1) return error.InvalidInput;
        const selected = try a.alloc(Value, indices.data.len);
        errdefer a.free(selected);
        for (indices.data, selected) |index, *item| item.* = items[try selectionIndex(index, items.len)];
        return .{ .tuple = selected };
    }
    const rows = if (source.shape.len == 0) 1 else source.shape[0];
    const width = rowWidth(source);
    const trailing = source.shape[@min(1, source.shape.len)..];
    const shape = try a.alloc(usize, indices.shape.len + trailing.len);
    errdefer a.free(shape);
    @memcpy(shape[0..indices.shape.len], indices.shape);
    @memcpy(shape[indices.shape.len..], trailing);
    const data = try a.alloc(f64, try std.math.mul(usize, indices.data.len, width));
    errdefer a.free(data);
    for (indices.data, 0..) |index, dest| {
        const row = try selectionIndex(index, rows);
        @memcpy(data[dest * width ..][0..width], source.data[row * width ..][0..width]);
    }
    return .{ .data = data, .shape = shape };
}

/// Select component items along the axis immediately before their dimensions.
/// A null component rank selects the leading axis. Bare select retains its
/// leading-axis convention for existing indexing and tuple destructuring.
pub fn selectComponents(a: std.mem.Allocator, source: Value, indices: Value, dimensions: ?usize) !Value {
    if (source.tuple != null) {
        if (dimensions != null and dimensions.? != 0) return error.InvalidAxis;
        return select(a, source, indices);
    }
    if (indices.tuple != null) return error.InvalidInput;
    if (source.shape.len == 0) {
        if (dimensions != null and dimensions.? != 0) return error.InvalidAxis;
        return select(a, source, indices);
    }
    const rank = dimensions orelse source.shape.len - 1;
    if (rank >= source.shape.len) return error.InvalidAxis;
    const axis = source.shape.len - rank - 1;
    const width = source.shape[axis];
    const cell_shape = source.shape[axis + 1 ..];
    var cell_size: usize = 1;
    for (cell_shape) |dim| cell_size *= dim;
    var frames: usize = 1;
    for (source.shape[0..axis]) |dim| frames *= dim;
    // Validate even when an empty outer frame means no data will be copied.
    for (indices.data) |index| _ = try selectionIndex(index, width);
    const shape = try std.mem.concat(a, usize, &.{ source.shape[0..axis], indices.shape, cell_shape });
    const data = try a.alloc(f64, frames * indices.data.len * cell_size);
    for (0..frames) |frame| {
        for (indices.data, 0..) |index, i| {
            const selected = try selectionIndex(index, width);
            @memcpy(data[(frame * indices.data.len + i) * cell_size ..][0..cell_size], source.data[(frame * width + selected) * cell_size ..][0..cell_size]);
        }
    }
    return .{ .data = data, .shape = shape };
}

fn selectionIndex(index: f64, size: usize) !usize {
    if (!std.math.isFinite(index) or @trunc(index) != index) return error.InvalidInput;
    const limit: f64 = @floatFromInt(size);
    if (index >= limit or index < -limit or @abs(index) >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return error.IndexOutOfBounds;
    const magnitude: usize = @intFromFloat(@abs(index));
    return if (index < 0) size - magnitude else magnitude;
}

/// Split a vector at every non-overlapping occurrence of a scalar or vector delimiter.
pub fn split(a: std.mem.Allocator, x: Value, delimiter: Value) !Value {
    return splitImpl(a, x, delimiter, false);
}

/// Split a vector only at the first occurrence of the delimiter.
pub fn @"split.first"(a: std.mem.Allocator, x: Value, delimiter: Value) !Value {
    return splitImpl(a, x, delimiter, true);
}

fn splitImpl(a: std.mem.Allocator, x: Value, delimiter: Value, first_only: bool) !Value {
    if (x.tuple != null or x.shape.len != 1 or delimiter.tuple != null or
        delimiter.shape.len > 1 or delimiter.data.len == 0 or
        (delimiter.shape.len == 0 and delimiter.data.len != 1)) return error.InvalidInput;
    var pieces: std.ArrayList(Value) = .empty;
    defer pieces.deinit(a);
    errdefer for (pieces.items) |piece| a.free(piece.shape);
    var start: usize = 0;
    var cursor: usize = 0;
    while (delimiter.data.len <= x.data.len - cursor) {
        if (!std.mem.eql(f64, x.data[cursor..][0..delimiter.data.len], delimiter.data)) {
            cursor += 1;
            continue;
        }
        const shape = try a.dupe(usize, &.{cursor - start});
        errdefer a.free(shape);
        try pieces.append(a, .{ .data = x.data[start..cursor], .shape = shape });
        cursor += delimiter.data.len;
        start = cursor;
        if (first_only) break;
    }
    const final_shape = try a.dupe(usize, &.{x.data.len - start});
    pieces.append(a, .{ .data = x.data[start..], .shape = final_shape }) catch |err| {
        a.free(final_shape);
        return err;
    };
    const width = pieces.items[0].data.len;
    for (pieces.items) |piece| {
        if (piece.data.len != width) return .{ .tuple = try pieces.toOwnedSlice(a) };
    }
    const shape = try a.dupe(usize, &.{ pieces.items.len, width });
    errdefer a.free(shape);
    const data = try a.alloc(f64, try std.math.mul(usize, pieces.items.len, width));
    for (pieces.items, 0..) |piece, i| {
        @memcpy(data[i * width ..][0..width], piece.data);
        a.free(piece.shape);
    }
    return .{ .data = data, .shape = shape };
}

/// Indices that sort each trailing-axis vector in ascending order.
pub fn rise(a: std.mem.Allocator, value: Value, _: Value) !Value {
    return grade(a, value, false);
}

/// Indices that sort each trailing-axis vector in descending order.
pub fn fall(a: std.mem.Allocator, value: Value, _: Value) !Value {
    return grade(a, value, true);
}

fn grade(a: std.mem.Allocator, value: Value, descending: bool) !Value {
    if (value.tuple != null) return error.InvalidInput;
    const data = try a.alloc(f64, value.data.len);
    errdefer a.free(data);
    if (value.shape.len == 0) {
        data[0] = 0;
        return .{ .data = data, .shape = value.shape };
    }
    const width = value.shape[value.shape.len - 1];
    if (data.len == 0) return .{ .data = data, .shape = value.shape };
    const Context = struct {
        values: []const f64,
        descending: bool,

        fn lessThan(ctx: @This(), lhs: f64, rhs: f64) bool {
            const x = ctx.values[@intFromFloat(if (ctx.descending) rhs else lhs)];
            const y = ctx.values[@intFromFloat(if (ctx.descending) lhs else rhs)];
            // Uiua treats signed zeros as equal and orders NaNs after numbers.
            if (x < y) return true;
            if (x > y) return false;
            return !std.math.isNan(x) and std.math.isNan(y);
        }
    };
    var offset: usize = 0;
    while (offset < data.len) : (offset += width) {
        const indices = data[offset..][0..width];
        for (indices, 0..) |*index, i| index.* = @floatFromInt(i);
        // Preserve input index order for equal values in both directions.
        std.mem.sort(f64, indices, Context{ .values = value.data[offset..][0..width], .descending = descending }, Context.lessThan);
    }
    return .{ .data = data, .shape = value.shape };
}

/// Sort innermost vectors by default; components select trailing cell dimensions.
pub fn sort(a: std.mem.Allocator, value: Value, _: Value) !Value {
    if (value.tuple != null) return error.InvalidInput;
    if (value.shape.len == 0) return value;
    return sortComponents(a, value, 0);
}

pub fn sortComponents(a: std.mem.Allocator, value: Value, dimensions: usize) !Value {
    if (value.tuple != null) return error.InvalidInput;
    if (dimensions >= value.shape.len) return error.InvalidAxis;
    if (value.data.len == 0) return value;
    const axis = value.shape.len - dimensions - 1;
    const shape = value.shape[axis..];
    var size: usize = 1;
    for (shape) |dim| size *= dim;
    const data = try a.alloc(f64, value.data.len);
    var offset: usize = 0;
    while (offset < data.len) : (offset += size) {
        const input: Value = .{ .data = value.data[offset..][0..size], .shape = shape };
        const result = try lexisort(a, input, .{});
        @memcpy(data[offset..][0..size], result.data);
        if (result.data.ptr != input.data.ptr) a.free(result.data);
    }
    return .{ .data = data, .shape = value.shape };
}

/// Uiua sort: reorder leading-axis rows lexicographically, preserving their contents.
pub fn lexisort(a: std.mem.Allocator, value: Value, _: Value) !Value {
    if (value.tuple != null) return error.InvalidInput;
    if (value.shape.len == 0 or value.data.len == 0 or value.shape[0] < 2) return value;
    const width = value.data.len / value.shape[0];
    const indices = try a.alloc(usize, value.shape[0]);
    defer a.free(indices);
    for (indices, 0..) |*index, i| index.* = i;
    const Context = struct {
        data: []const f64,
        width: usize,

        fn lessThan(ctx: @This(), lhs: usize, rhs: usize) bool {
            for (ctx.data[lhs * ctx.width ..][0..ctx.width], ctx.data[rhs * ctx.width ..][0..ctx.width]) |x, y| {
                // Uiua orders NaNs after numbers and treats signed zeros as equal.
                if (x < y) return true;
                if (x > y) return false;
                if (std.math.isNan(x) != std.math.isNan(y)) return std.math.isNan(y);
            }
            return false;
        }
    };
    std.mem.sort(usize, indices, Context{ .data = value.data, .width = width }, Context.lessThan);
    const data = try a.alloc(f64, value.data.len);
    for (indices, 0..) |source, dest| {
        @memcpy(data[dest * width ..][0..width], value.data[source * width ..][0..width]);
    }
    return .{ .data = data, .shape = value.shape };
}

/// Uiua keep on the trailing axis. Counts cycle when short and truncate when long.
/// Real scalar counts resample the axis; negative scalars also reverse it.
pub fn keep(a: std.mem.Allocator, x: Value, counts: Value) !Value {
    if (x.tuple != null or counts.tuple != null) return error.InvalidInput;
    const scalar = counts.shape.len == 0;
    const source_shape: []const usize = if (x.shape.len == 0) &.{1} else x.shape;
    const width = source_shape[source_shape.len - 1];
    if (!scalar and width > 0 and counts.data.len == 0) return @import("../runtime.zig").shapeMismatch(@src().fn_name, &.{ x, counts });
    for (counts.data) |n| {
        if (!std.math.isFinite(n) or (!scalar and @trunc(n) != n)) return error.InvalidInput;
    }
    var new_width: usize = 0;
    if (scalar) {
        new_width = try keepSize(@round(@abs(counts.data[0]) * @as(f64, @floatFromInt(width))));
    } else {
        for (0..width) |i| {
            new_width = try std.math.add(usize, new_width, try keepSize(@max(0, counts.data[i % counts.data.len])));
        }
    }
    var outer: usize = 1;
    for (source_shape[0 .. source_shape.len - 1]) |dim| outer = try std.math.mul(usize, outer, dim);
    const shape = try a.dupe(usize, source_shape);
    shape[shape.len - 1] = new_width;
    const data = try a.alloc(f64, try std.math.mul(usize, outer, new_width));
    for (0..outer) |row| {
        if (scalar) {
            const delta = @as(f64, @floatFromInt(width)) / @as(f64, @floatFromInt(new_width));
            for (0..new_width) |j| {
                const k = if (counts.data[0] < 0) new_width - 1 - j else j;
                const t = @as(f64, @floatFromInt(k)) * delta;
                const fraction = t - @floor(t);
                const index: usize = if (counts.data[0] >= 1 and @trunc(counts.data[0]) == counts.data[0])
                    j / try keepSize(counts.data[0])
                else
                    @intFromFloat(if (fraction <= std.math.floatEps(f64) or fraction >= 1 - std.math.floatEps(f64)) @round(t) else @floor(t));
                data[row * new_width + j] = x.data[row * width + @min(index, width - 1)];
            }
        } else {
            var dest = row * new_width;
            for (0..width) |i| {
                const item_count = try keepSize(@max(0, counts.data[i % counts.data.len]));
                @memset(data[dest..][0..item_count], x.data[row * width + i]);
                dest += item_count;
            }
        }
    }
    return .{ .data = data, .shape = shape };
}

fn keepSize(n: f64) !usize {
    if (!std.math.isFinite(n) or n >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return error.InvalidInput;
    return @intFromFloat(n);
}

pub fn radix10(a: std.mem.Allocator, x: Value, _: Value) !Value {
    return radix(a, x, .{ .data = &.{10} });
}

/// Uiua anti-base: collapse the trailing digit axis.
pub fn radix(a: std.mem.Allocator, x: Value, bases: Value) !Value {
    if (x.tuple != null or bases.tuple != null or bases.shape.len > 1) return error.InvalidInput;
    const shape = x.shape[0 .. x.shape.len - @intFromBool(x.shape.len > 0)];
    const width = if (x.shape.len == 0) 1 else x.shape[x.shape.len - 1];
    var item_count: usize = 1;
    for (shape) |dim| item_count = try std.math.mul(usize, item_count, dim);
    const data = try a.alloc(f64, item_count);
    @memset(data, 0);
    for (data, 0..) |*output, i| {
        var j = width;
        while (j > 0) {
            j -= 1;
            var b: f64 = if (bases.shape.len == 0) bases.data[0] else if (j < bases.data.len) bases.data[j] else 1;
            if (bases.shape.len != 0 and std.math.isInf(b)) {
                b = 1;
                for (bases.data[0..@min(width - j, bases.data.len)]) |factor| {
                    if (!std.math.isInf(factor)) b *= factor;
                }
            }
            output.* = @mulAdd(f64, output.*, b, x.data[i * width + j]);
        }
    }
    return .{ .data = data, .shape = try a.dupe(usize, shape) };
}

/// Swap the two innermost axes independently in each outer cell.
pub fn transpose(a: std.mem.Allocator, x: Value, _: Value) !Value {
    if (x.tuple != null) return error.InvalidInput;
    if (x.shape.len < 2) return x;
    const shape = try a.dupe(usize, x.shape);
    const rows = shape[shape.len - 2];
    const cols = shape[shape.len - 1];
    shape[shape.len - 2] = cols;
    shape[shape.len - 1] = rows;
    const data = try a.alloc(f64, x.data.len);
    for (data, 0..) |*item, i| {
        const cell_size = rows * cols;
        const offset = i % cell_size;
        item.* = x.data[i / cell_size * cell_size + offset % rows * cols + offset / rows];
    }
    return .{ .data = data, .shape = shape };
}
