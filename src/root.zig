pub const lexer = @import("lexer.zig");
pub const parser = @import("parser.zig");
pub const builtins = struct {
    pub const pervasives = @import("builtins/pervasives.zig");
    pub const axis_polymorphic = @import("builtins/axis_polymorphic.zig");
    pub const axis_monomorphic = @import("builtins/axis_monomorphic.zig");
    pub const hofs = @import("builtins/hofs.zig");
    pub const convolve_builtins = @import("builtins/convolve_builtins.zig");
    pub const regex_builtins = @import("builtins/regex_builtins.zig");
};
pub const memory = @import("memory.zig");
pub const runtime = @import("runtime.zig");
pub const console = @import("console.zig");
pub const environment = @import("environment.zig");
pub const ReservedBumpAllocator = @import("reserved_bump_allocator.zig").ReservedBumpAllocator;
test {
    _ = @import("memory.zig");
    _ = @import("reserved_bump_allocator.zig");
}
