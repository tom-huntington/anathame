const std = @import("std");

extern "kernel32" fn SetConsoleOutputCP(code_page: std.os.windows.UINT) callconv(.winapi) std.os.windows.BOOL;

/// Our output is UTF-8, including when child build steps inherit the console.
pub fn init() void {
    if (@import("builtin").os.tag == .windows) {
        // No console (e.g. redirected output) needs no code-page adjustment.
        _ = SetConsoleOutputCP(65001);
    }
}
