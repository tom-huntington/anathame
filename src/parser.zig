const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;
const Value = @import("runtime.zig").Value;
pub const Instruction = union(enum) { literal: Value, primitive: []const u8 };
pub fn parse(a: std.mem.Allocator, source: []const u8) ![]const Instruction {
    var lexer: Lexer = .{ .source = source };
    var result: std.ArrayList(Instruction) = .empty;
    while (lexer.next()) |token| {
        if (std.mem.eql(u8, token, "]")) return error.UnexpectedClose;
        if (std.mem.eql(u8, token, "[")) {
            try result.append(a, .{ .literal = try array(a, &lexer) });
        } else if (std.fmt.parseFloat(f64, token)) |n| {
            try result.append(a, .{ .literal = .{ .data = try a.dupe(f64, &.{n}), .shape = &.{} } });
        } else |_| {
            if (!@import("primitives.zig").known(token)) return error.UnknownPrimitive;
            try result.append(a, .{ .primitive = token });
        }
    }
    return result.toOwnedSlice(a);
}
fn array(a: std.mem.Allocator, lexer: *Lexer) anyerror!Value {
    var data: std.ArrayList(f64) = .empty;
    var count: usize = 0;
    var child_shape: ?[]const usize = null;
    while (lexer.next()) |token| {
        if (std.mem.eql(u8, token, "]")) {
            const shape = try a.alloc(usize, 1 + (if (child_shape) |s| s.len else @as(usize, 0)));
            shape[0] = count;
            if (child_shape) |s| @memcpy(shape[1..], s);
            return .{ .data = try data.toOwnedSlice(a), .shape = shape };
        }
        const child: Value = if (std.mem.eql(u8, token, "[")) try array(a, lexer) else .{ .data = try a.dupe(f64, &.{std.fmt.parseFloat(f64, token) catch return error.InvalidNumber}), .shape = &.{} };
        if (child_shape) |s| {
            if (!std.mem.eql(usize, s, child.shape)) return error.RaggedArray;
        } else child_shape = child.shape;
        try data.appendSlice(a, child.data);
        count += 1;
    }
    return error.UnclosedArray;
}
