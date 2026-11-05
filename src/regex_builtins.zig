const std = @import("std");
const Value = @import("runtime.zig").Value;
const regex = @import("regex");

// Strings contain Unicode codepoints as f64 values; zig-regex takes UTF-8.
fn stringBytes(a: std.mem.Allocator, value: Value) ![]u8 {
    if (value.tuple != null or value.shape.len != 1) return error.ExpectedString;
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(a);
    for (value.data) |number| {
        if (!std.math.isFinite(number) or number < 0 or number > 0x10ffff or @trunc(number) != number) return error.InvalidCharacter;
        var encoded: [4]u8 = undefined;
        const length = try std.unicode.utf8Encode(@intFromFloat(number), &encoded);
        try bytes.appendSlice(a, encoded[0..length]);
    }
    return bytes.toOwnedSlice(a);
}

pub fn Matches(a: std.mem.Allocator, input: Value, pattern: Value) !Value {
    const pattern_bytes = try stringBytes(a, pattern);
    defer a.free(pattern_bytes);
    const input_bytes = try stringBytes(a, input);
    defer a.free(input_bytes);
    var compiled = try regex.Regex.compile(a, pattern_bytes);
    defer compiled.deinit();
    return .{ .data = try a.dupe(f64, &.{@floatFromInt(@intFromBool(try compiled.isMatch(input_bytes)))}) };
}

/// Find non-overlapping numeric matches, or numeric capture groups when present.
pub fn Findall(a: std.mem.Allocator, input: Value, pattern: Value) !Value {
    const pattern_bytes = try stringBytes(a, pattern);
    defer a.free(pattern_bytes);
    const input_bytes = try stringBytes(a, input);
    defer a.free(input_bytes);
    var compiled = try regex.Regex.compile(a, pattern_bytes);
    defer compiled.deinit();
    const matches = try compiled.findAll(a, input_bytes);
    defer {
        for (matches) |*match| match.deinit(a);
        a.free(matches);
    }

    const columns = @max(compiled.capture_count, 1);
    const data = try a.alloc(f64, try std.math.mul(usize, matches.len, columns));
    errdefer a.free(data);
    for (matches, 0..) |match, row| {
        if (compiled.capture_count == 0) {
            data[row] = std.fmt.parseFloat(f64, match.slice) catch return error.InvalidInput;
        } else {
            for (match.captures, 0..) |capture, column| {
                data[row * columns + column] = std.fmt.parseFloat(f64, capture) catch return error.InvalidInput;
            }
        }
    }
    const shape = if (columns == 1)
        try a.dupe(usize, &.{matches.len})
    else
        try a.dupe(usize, &.{ matches.len, columns });
    return .{ .data = data, .shape = shape };
}
