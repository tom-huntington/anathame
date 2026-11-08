const std = @import("std");
const builtin = @import("builtin");

extern "kernel32" fn SetEnvironmentVariableW([*:0]const u16, ?[*:0]const u16) callconv(.winapi) i32;
extern "c" fn setenv([*:0]const u8, [*:0]const u8, c_int) c_int;
extern "c" fn getenv([*:0]const u8) ?[*:0]const u8;
extern "c" fn unsetenv([*:0]const u8) c_int;

pub fn remove(a: std.mem.Allocator, name: []const u8) !void {
    try validateName(name);
    if (builtin.os.tag == .windows) {
        const key = try std.unicode.utf8ToUtf16LeAllocZ(a, name);
        defer a.free(key);
        if (SetEnvironmentVariableW(key, null) == 0) return error.SetEnvironmentVariableFailed;
    } else {
        const key = try a.dupeZ(u8, name);
        defer a.free(key);
        if (unsetenv(key) != 0) return error.SetEnvironmentVariableFailed;
    }
}

fn validateName(name: []const u8) !void {
    if (name.len == 0 or std.mem.indexOfAny(u8, name, "=\x00") != null)
        return error.InvalidEnvironmentVariableName;
}

/// Update the actual process environment, including values inherited by children.
pub fn set(a: std.mem.Allocator, name: []const u8, value: []const u8) !void {
    try validateName(name);
    if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidEnvironmentVariableValue;
    if (builtin.os.tag == .windows) {
        const key = try std.unicode.utf8ToUtf16LeAllocZ(a, name);
        defer a.free(key);
        const text = try std.unicode.utf8ToUtf16LeAllocZ(a, value);
        defer a.free(text);
        if (SetEnvironmentVariableW(key, text) == 0) return error.SetEnvironmentVariableFailed;
    } else {
        const key = try a.dupeZ(u8, name);
        defer a.free(key);
        const text = try a.dupeZ(u8, value);
        defer a.free(text);
        if (setenv(key, text, 1) != 0) return error.SetEnvironmentVariableFailed;
    }
}

pub fn get(a: std.mem.Allocator, name: []const u8) ![]u8 {
    try validateName(name);
    if (builtin.os.tag == .windows) {
        const environ: std.process.Environ = .{ .block = .global };
        return environ.getAlloc(a, name);
    } else {
        const key = try a.dupeZ(u8, name);
        defer a.free(key);
        const value = getenv(key) orelse return error.EnvironmentVariableMissing;
        return a.dupe(u8, std.mem.span(value));
    }
}
