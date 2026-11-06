const std = @import("std");
const Value = @import("runtime.zig").Value;

/// Split at the first empty line, excluding its surrounding line endings.
pub fn blankline(a: std.mem.Allocator, x: Value, _: Value) !Value {
    if (x.tuple != null or x.shape.len != 1) return error.InvalidInput;
    for (x.data) |character| {
        if (!std.math.isFinite(character) or character < 0 or character > 0x10ffff or
            @trunc(character) != character or (character >= 0xd800 and character <= 0xdfff))
            return error.InvalidInput;
    }
    var left_end = x.data.len;
    var right_start = x.data.len;
    for (x.data, 0..) |character, i| {
        if (character != '\n') continue;
        var next = i + 1;
        if (next < x.data.len and x.data[next] == '\r') next += 1;
        if (next < x.data.len and x.data[next] == '\n') {
            left_end = if (i > 0 and x.data[i - 1] == '\r') i - 1 else i;
            right_start = next + 1;
            break;
        }
    }
    const values = try a.alloc(Value, 2);
    values[0] = .{ .data = x.data[0..left_end], .shape = try a.dupe(usize, &.{left_end}) };
    values[1] = .{ .data = x.data[right_start..], .shape = try a.dupe(usize, &.{x.data.len - right_start}) };
    return .{ .tuple = values };
}
