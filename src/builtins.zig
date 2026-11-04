const std = @import("std");
const Value = @import("runtime.zig").Value;

pub fn sq(a: std.mem.Allocator, x: Value, _: Value) !Value {
    return @import("uiua_builtins.zig").mul(a, x, x);
}
