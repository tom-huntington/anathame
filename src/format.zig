const std = @import("std");
const types = @import("types.zig");

const Value = types.Value;

pub const FormatError = error{
    OutOfMemory,
    InvalidChar,
};

pub fn allocPrint(allocator: std.mem.Allocator, value: Value) FormatError![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try writeValue(&aw.writer, value);
    return try aw.toOwnedSlice();
}

pub fn writeValue(writer: *std.Io.Writer, value: Value) FormatError!void {
    switch (value) {
        .scalar => |scalar| {
            if (scalar.is_char) {
                try writer.writeByte('@');
                try writeEscapedChar(writer, scalar.value);
            } else {
                try writer.print("{d}", .{scalar.value});
            }
        },
        .array => |array| {
            if (array.is_char and array.shape.len <= 1) {
                try writeQuotedChars(writer, array.data);
            } else if (array.shape.len == 0) {
                try writer.writeAll("[]");
            } else {
                try writeArray(writer, array.data, array.shape, array.is_char, 0);
            }
        },
    }
}

fn writeArray(
    writer: *std.Io.Writer,
    data: []const f64,
    shape: []const u32,
    is_char: bool,
    indent: usize,
) FormatError!void {
    if (is_char and shape.len == 1) {
        try writeQuotedChars(writer, data);
        return;
    }
    if (shape.len == 1) {
        try writeVector(writer, data, is_char);
        return;
    }

    const rows: usize = shape[0];
    if (rows == 0) {
        try writer.writeAll("[]");
        return;
    }

    const row_len = flatLen(shape[1..]);
    try writer.writeAll("[\n");
    for (0..rows) |i| {
        try writeIndent(writer, indent + 2);
        const start = i * row_len;
        const end = start + row_len;
        try writeArray(writer, data[start..end], shape[1..], is_char, indent + 2);
        if (i + 1 < rows) {
            try writer.writeByte('\n');
        }
    }
    try writer.writeByte('\n');
    try writeIndent(writer, indent);
    try writer.writeByte(']');
}

fn writeVector(writer: *std.Io.Writer, data: []const f64, is_char: bool) FormatError!void {
    if (is_char) {
        try writeQuotedChars(writer, data);
        return;
    }

    try writer.writeByte('[');
    for (data, 0..) |item, i| {
        if (i > 0) try writer.writeByte(' ');
        try writer.print("{d}", .{item});
    }
    try writer.writeByte(']');
}

fn writeQuotedChars(writer: *std.Io.Writer, data: []const f64) FormatError!void {
    try writer.writeByte('"');
    for (data) |value| {
        try writeEscapedChar(writer, value);
    }
    try writer.writeByte('"');
}

fn writeEscapedChar(writer: *std.Io.Writer, value: f64) FormatError!void {
    const codepoint = try toCodepoint(value);
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(codepoint, &buf) catch return error.InvalidChar;
    try std.zig.stringEscape(buf[0..len], writer);
}

fn toCodepoint(value: f64) FormatError!u21 {
    if (!std.math.isFinite(value)) return error.InvalidChar;
    if (value < 0 or value > 0x10ffff) return error.InvalidChar;
    if (@floor(value) != value) return error.InvalidChar;
    return @intFromFloat(value);
}

fn flatLen(shape: []const u32) usize {
    var len: usize = 1;
    for (shape) |dim| {
        len *= dim;
    }
    return len;
}

fn writeIndent(writer: *std.Io.Writer, indent: usize) FormatError!void {
    for (0..indent) |_| {
        try writer.writeByte(' ');
    }
}

test "formats numeric scalars" {
    const allocator = std.testing.allocator;
    const formatted = try allocPrint(allocator, .{
        .scalar = .{ .value = 42, .is_char = false },
    });
    defer allocator.free(formatted);

    try std.testing.expectEqualStrings("42", formatted);
}

test "formats char scalars with escapes" {
    const allocator = std.testing.allocator;
    const formatted = try allocPrint(allocator, .{
        .scalar = .{ .value = '\n', .is_char = true },
    });
    defer allocator.free(formatted);

    try std.testing.expectEqualStrings("@\\n", formatted);
}

test "formats char vectors as strings" {
    const allocator = std.testing.allocator;
    const formatted = try allocPrint(allocator, .{
        .array = .{
            .data = &.{ 'a', '\n', '"' },
            .shape = &.{3},
            .is_char = true,
        },
    });
    defer allocator.free(formatted);

    try std.testing.expectEqualStrings("\"a\\n\\\"\"", formatted);
}

test "formats numeric matrices" {
    const allocator = std.testing.allocator;
    const formatted = try allocPrint(allocator, .{
        .array = .{
            .data = &.{ 1, 2, 3, 4 },
            .shape = &.{ 2, 2 },
            .is_char = false,
        },
    });
    defer allocator.free(formatted);

    try std.testing.expectEqualStrings(
        \\[
        \\  [1 2]
        \\  [3 4]
        \\]
    , formatted);
}

test "formats rank-2 char arrays as rows of strings" {
    const allocator = std.testing.allocator;
    const formatted = try allocPrint(allocator, .{
        .array = .{
            .data = &.{ 'a', 'b', 'c', 'd' },
            .shape = &.{ 2, 2 },
            .is_char = true,
        },
    });
    defer allocator.free(formatted);

    try std.testing.expectEqualStrings(
        \\[
        \\  "ab"
        \\  "cd"
        \\]
    , formatted);
}
