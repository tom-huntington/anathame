const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;
const Value = @import("runtime.zig").Value;
pub const Instruction = union(enum) {
    literal: Value,
    primitive: []const u8,
    partial: struct { name: []const u8, argument: Value },
    scope: struct { arity: usize, instructions: []const Instruction },
};
pub fn parse(a: std.mem.Allocator, source: []const u8) ![]const Instruction {
    var lexer: Lexer = .{ .source = source };
    return sequence(a, &lexer, null, false);
}

pub fn parseProgram(a: std.mem.Allocator, source: []const u8) !Instruction {
    const instructions = try parse(a, source);
    if (instructions.len != 1 or instructions[0] != .scope) return error.InvalidSyntax;
    return instructions[0];
}

fn sequence(a: std.mem.Allocator, lexer: *Lexer, close: ?[]const u8, implicit: bool) anyerror![]const Instruction {
    var result: std.ArrayList(Instruction) = .empty;
    while (try lexer.next()) |token| {
        if (std.mem.eql(u8, token, ")") or std.mem.eql(u8, token, "}")) {
            if (close == null or !std.mem.eql(u8, token, close.?)) return error.InvalidSyntax;
            if (implicit) lexer.offset -= token.len;
            return result.toOwnedSlice(a);
        }
        const monadic = std.mem.eql(u8, token, "(") or std.mem.eql(u8, token, "\\");
        const dyadic = std.mem.eql(u8, token, "{") or std.mem.eql(u8, token, "\\\\");
        if (monadic or dyadic) {
            const is_implicit = token[0] == '\\';
            const end = if (is_implicit) close else if (monadic) ")" else "}";
            const body = try sequence(a, lexer, end, is_implicit);
            if (body.len == 0) return error.InvalidSyntax;
            for (body) |instruction| if (instruction == .literal) return error.ExpectedFunction;
            try result.append(a, .{ .scope = .{ .arity = if (monadic) 1 else 2, .instructions = body } });
            continue;
        }
        if (std.mem.eql(u8, token, ",")) {
            if (result.items.len == 0) return error.ExpectedFunction;
            const previous = &result.items[result.items.len - 1];
            const name = switch (previous.*) {
                .primitive => |name| name,
                else => return error.ExpectedFunction,
            };
            if (@import("primitives.zig").arity(name) != 2) return error.WrongNumberOfArguments;
            const argument = (try lexer.next()) orelse return error.ExpectedLiteral;
            const value = if (std.mem.eql(u8, argument, "[")) try array(a, lexer) else (try literal(a, argument)) orelse return error.ExpectedLiteral;
            previous.* = .{ .partial = .{ .name = name, .argument = value } };
            continue;
        }
        if (std.mem.eql(u8, token, "]")) return error.UnexpectedClose;
        if (std.mem.eql(u8, token, "[")) {
            try result.append(a, .{ .literal = try array(a, lexer) });
        } else if (try literal(a, token)) |value| {
            try result.append(a, .{ .literal = value });
        } else {
            if (!@import("primitives.zig").known(token)) return error.UnknownPrimitive;
            try result.append(a, .{ .primitive = token });
        }
    }
    if (close != null and !implicit) return error.InvalidSyntax;
    return result.toOwnedSlice(a);
}
fn array(a: std.mem.Allocator, lexer: *Lexer) anyerror!Value {
    var data: std.ArrayList(f64) = .empty;
    var count: usize = 0;
    var child_shape: ?[]const usize = null;
    while (try lexer.next()) |token| {
        if (std.mem.eql(u8, token, "]")) {
            const shape = try a.alloc(usize, 1 + (if (child_shape) |s| s.len else @as(usize, 0)));
            shape[0] = count;
            if (child_shape) |s| @memcpy(shape[1..], s);
            return .{ .data = try data.toOwnedSlice(a), .shape = shape };
        }
        const child: Value = if (std.mem.eql(u8, token, "[")) try array(a, lexer) else (try literal(a, token)) orelse return error.InvalidNumber;
        if (child_shape) |s| {
            if (!std.mem.eql(usize, s, child.shape)) return error.RaggedArray;
        } else child_shape = child.shape;
        try data.appendSlice(a, child.data);
        count += 1;
    }
    return error.UnclosedArray;
}

fn literal(a: std.mem.Allocator, token: []const u8) !?Value {
    if (token[0] == '@' or token[0] == '"') {
        const character = token[0] == '@';
        const raw_character = character and token[1] != '\\';
        const quoted = if (character) try std.mem.concat(a, u8, &.{ "\"", token[1..], "\"" }) else token;
        defer if (character) a.free(quoted);
        const decoded = if (raw_character) try a.dupe(u8, token[1..]) else try std.zig.string_literal.parseAlloc(a, quoted);
        defer a.free(decoded);
        const view = try std.unicode.Utf8View.init(decoded);
        var iterator = view.iterator();
        var data: std.ArrayList(f64) = .empty;
        errdefer data.deinit(a);
        while (iterator.nextCodepoint()) |cp| try data.append(a, @floatFromInt(cp));
        if (character and data.items.len != 1) return error.InvalidCharacterLiteral;
        const shape = if (character) &.{} else try a.dupe(usize, &.{data.items.len});
        return .{ .data = try data.toOwnedSlice(a), .shape = shape };
    }
    const n = std.fmt.parseFloat(f64, token) catch return null;
    if (!std.math.isFinite(n)) return error.InvalidInput;
    return .{ .data = try a.dupe(f64, &.{n}), .shape = &.{} };
}
