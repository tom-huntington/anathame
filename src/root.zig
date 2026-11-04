pub const lexer = @import("lexer.zig");
pub const parser = @import("parser.zig");
pub const builtins = @import("builtins.zig");
pub const uiua_builtins = @import("uiua_builtins.zig");
pub const memory = @import("memory.zig");
pub const runtime = @import("runtime.zig");
pub const ReservedBumpAllocator = @import("reserved_bump_allocator.zig").ReservedBumpAllocator;
test {
    _ = @import("memory.zig");
    _ = @import("reserved_bump_allocator.zig");
}
