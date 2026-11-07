const std = @import("std");

extern "kernel32" fn SetConsoleOutputCP(code_page: std.os.windows.UINT) callconv(.winapi) std.os.windows.BOOL;

const Coord = extern struct { x: i16, y: i16 };
const ScreenInfo = extern struct {
    size: Coord,
    cursor: Coord,
    attributes: u16,
    window: extern struct { left: i16, top: i16, right: i16, bottom: i16 },
    maximum: Coord,
};
extern "kernel32" fn GetConsoleScreenBufferInfo(handle: std.os.windows.HANDLE, info: *ScreenInfo) callconv(.winapi) std.os.windows.BOOL;

/// Width of the visible console, with a conservative default for captured output.
pub fn width() usize {
    if (@import("builtin").os.tag == .windows) {
        var info: ScreenInfo = undefined;
        if (GetConsoleScreenBufferInfo(std.Io.File.stdout().handle, &info).toBool()) {
            const columns = @as(i32, info.window.right) - info.window.left + 1;
            if (columns > 0) return @intCast(columns);
        }
    }
    return 80;
}

/// Keep human-readable output short of the terminal's automatic wrap column.
/// Formatting used for serialization and value comparisons remains unabridged.
pub fn write(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    const limit = width() -| 1;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try w.writeByte('\n');
        first = false;
        var it = std.unicode.Utf8View.initUnchecked(line).iterator();
        var columns: usize = 0;
        var end: usize = 0;
        while (it.nextCodepoint()) |cp| {
            const size: usize = if (cp >= 0x1100 and
                (cp <= 0x115f or cp == 0x2329 or cp == 0x232a or
                    (cp >= 0x2e80 and cp <= 0xa4cf) or
                    (cp >= 0xac00 and cp <= 0xd7a3) or
                    (cp >= 0xf900 and cp <= 0xfaff) or
                    (cp >= 0xfe10 and cp <= 0xfe6f) or
                    (cp >= 0xff01 and cp <= 0xff60) or
                    (cp >= 0xffe0 and cp <= 0xffe6) or
                    (cp >= 0x1f300 and cp <= 0x1faff) or
                    (cp >= 0x20000 and cp <= 0x3fffd))) 2 else 1;
            columns += size;
            if (columns <= limit -| 1) end = it.i;
            if (columns > limit) break;
        }
        if (columns <= limit) {
            try w.writeAll(line);
        } else {
            try w.writeAll(line[0..end]);
            if (limit > 0) try w.writeAll("…");
        }
    }
}

/// Call in the process writing UTF-8, rather than in cached build configuration.
pub fn init() void {
    if (@import("builtin").os.tag == .windows) {
        // No console (e.g. redirected output) needs no code-page adjustment.
        _ = SetConsoleOutputCP(65001);
    }
}
