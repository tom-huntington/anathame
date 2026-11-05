const std = @import("std");

extern "kernel32" fn SetConsoleOutputCP(code_page: std.os.windows.UINT) callconv(.winapi) std.os.windows.BOOL;

/// Call in the process writing UTF-8, rather than in cached build configuration.
pub fn init() void {
    if (@import("builtin").os.tag == .windows) {
        // No console (e.g. redirected output) needs no code-page adjustment.
        _ = SetConsoleOutputCP(65001);
    }
}
