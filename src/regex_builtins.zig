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
