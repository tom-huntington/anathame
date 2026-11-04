const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;
const Value = @import("runtime.zig").Value;
pub const Instruction = union(enum) {
    literal: Value,
    cases: Value,
    primitive: []const u8,
    partition: *const Instruction,
    partial: struct { name: []const u8, argument: Value },
    combinator: enum { n, s, S, b, phi },
    scope: struct { arity: usize, instructions: []const Instruction, default_arguments: ?[]const Value = null },
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
        if (std.mem.eql(u8, token, "|n") or std.mem.eql(u8, token, "|s") or std.mem.eql(u8, token, "|S") or std.mem.eql(u8, token, "|b") or std.mem.eql(u8, token, "|phi")) {
            if (result.items.len == 0 or result.items[result.items.len - 1] == .combinator) return error.ExpectedFunction;
            try result.append(a, .{ .combinator = if (token[1] == 'n') .n else if (token[1] == 's') .s else if (token[1] == 'S') .S else if (token[1] == 'p') .phi else .b });
            continue;
        }
        if (result.items.len > 0 and result.items[result.items.len - 1] == .combinator and
            (std.mem.eql(u8, token, ")") or std.mem.eql(u8, token, "}") or std.mem.eql(u8, token, "|>"))) return error.ExpectedFunction;
        if (std.mem.eql(u8, token, "|>")) {
            if (result.items.len < 1 or result.items.len > 2) return error.WrongNumberOfArguments;
            const arguments = try a.alloc(Value, result.items.len);
            for (result.items, arguments) |instruction, *argument| {
                argument.* = switch (instruction) {
                    .literal => |value| value,
                    else => return error.ExpectedLiteral,
                };
            }
            const body = try sequence(a, lexer, close, implicit);
            if (body.len != 1 or body[0] != .scope) return error.ExpectedFunction;
            var application = body[0];
            application.scope.arity = arguments.len;
            application.scope.default_arguments = arguments;
            return a.dupe(Instruction, &.{application});
        }
        if (std.mem.eql(u8, token, ")") or std.mem.eql(u8, token, "}")) {
            if (close == null or !std.mem.eql(u8, token, close.?)) return error.InvalidSyntax;
            if (implicit) lexer.offset -= token.len;
            return bindFunctions(a, result.items);
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
            const value = (try strand(a, lexer, argument)) orelse return error.ExpectedLiteral;
            previous.* = .{ .partial = .{ .name = name, .argument = value } };
            continue;
        }
        if (std.mem.eql(u8, token, "Cases")) {
            const open = (try lexer.next()) orelse return error.ExpectedLiteral;
            if (!std.mem.eql(u8, open, "[")) return error.ExpectedArray;
            const table = try array(a, lexer);
            if (table.shape.len != 2 or table.shape[1] != 2) return error.ShapeMismatch;
            try result.append(a, .{ .cases = table });
            continue;
        }
        if (std.mem.eql(u8, token, "]")) return error.UnexpectedClose;
        if (try strand(a, lexer, token)) |value| {
            try result.append(a, .{ .literal = value });
        } else {
            if (!@import("primitives.zig").known(token)) return error.UnknownPrimitive;
            try result.append(a, .{ .primitive = token });
        }
    }
    if (close != null and !implicit) return error.InvalidSyntax;
    if (result.items.len > 0 and result.items[result.items.len - 1] == .combinator) return error.ExpectedFunction;
    return bindFunctions(a, result.items);
}
// Fold from the right after partial applications have been parsed.
fn bindFunctions(a: std.mem.Allocator, instructions: []const Instruction) ![]const Instruction {
    var result: std.ArrayList(Instruction) = .empty;
    var i = instructions.len;
    while (i > 0) {
        i -= 1;
        const instruction = instructions[i];
        if (instruction == .primitive and std.mem.eql(u8, instruction.primitive, "partition")) {
            const operand = result.pop() orelse return error.ExpectedFunction;
            if (operand == .combinator or operand == .literal) return error.ExpectedFunction;
            const function = try a.create(Instruction);
            function.* = operand;
            try result.append(a, .{ .partition = function });
        } else try result.append(a, instruction);
    }
    std.mem.reverse(Instruction, result.items);
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
        const child = (try strand(a, lexer, token)) orelse return error.InvalidNumber;
        if (child.tuple != null) return error.ExpectedArray;
        if (child_shape) |s| {
            if (!std.mem.eql(usize, s, child.shape)) return error.RaggedArray;
        } else child_shape = child.shape;
        try data.appendSlice(a, child.data);
        count += 1;
    }
    return error.UnclosedArray;
}

// Tuple literals use a prefix to distinguish them from monadic scopes.
fn tuple(a: std.mem.Allocator, lexer: *Lexer) anyerror!Value {
    const open = (try lexer.next()) orelse return error.InvalidSyntax;
    if (!std.mem.eql(u8, open, "(")) return error.InvalidSyntax;
    var items: std.ArrayList(Value) = .empty;
    var token = (try lexer.next()) orelse return error.InvalidSyntax;
    if (std.mem.eql(u8, token, ")")) return .{ .tuple = try items.toOwnedSlice(a) };
    while (true) {
        const item = (try strand(a, lexer, token)) orelse return error.ExpectedLiteral;
        try items.append(a, item);
        const separator = (try lexer.next()) orelse return error.InvalidSyntax;
        if (std.mem.eql(u8, separator, ")")) return .{ .tuple = try items.toOwnedSlice(a) };
        if (!std.mem.eql(u8, separator, ",")) return error.InvalidSyntax;
        token = (try lexer.next()) orelse return error.ExpectedLiteral;
    }
}

// Strands stack equally shaped literals along a new leading axis.
fn strand(a: std.mem.Allocator, lexer: *Lexer, token: []const u8) anyerror!?Value {
    const first = if (std.mem.eql(u8, token, "tup")) try tuple(a, lexer) else if (std.mem.eql(u8, token, "[")) try array(a, lexer) else (try literal(a, token)) orelse return null;
    var data: std.ArrayList(f64) = .empty;
    var count: usize = 1;
    while (true) {
        const offset = lexer.offset;
        const separator = try lexer.next();
        if (separator == null or !std.mem.eql(u8, separator.?, "_")) {
            lexer.offset = offset;
            break;
        }
        if (first.tuple != null) return error.ExpectedArray;
        if (count == 1) try data.appendSlice(a, first.data);
        const next = (try lexer.next()) orelse return error.ExpectedLiteral;
        const child = if (std.mem.eql(u8, next, "[")) try array(a, lexer) else (try literal(a, next)) orelse return error.ExpectedLiteral;
        if (!std.mem.eql(usize, first.shape, child.shape)) return error.RaggedArray;
        try data.appendSlice(a, child.data);
        count += 1;
    }
    if (count == 1) return first;
    const shape = try a.alloc(usize, first.shape.len + 1);
    shape[0] = count;
    @memcpy(shape[1..], first.shape);
    return .{ .data = try data.toOwnedSlice(a), .shape = shape };
}

fn literal(a: std.mem.Allocator, token: []const u8) !?Value {
    if (token[0] == '@' or token[0] == '"' or token[0] == '$') {
        const character = token[0] == '@';
        const multiline = token[0] == '$';
        const raw_character = character and token[1] != '\\';
        const quoted = if (character) try std.mem.concat(a, u8, &.{ "\"", token[1..], "\"" }) else token;
        defer if (character) a.free(quoted);
        const decoded = if (multiline) try multilineString(a, token) else if (raw_character) try a.dupe(u8, token[1..]) else try std.zig.string_literal.parseAlloc(a, quoted);
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

fn multilineString(a: std.mem.Allocator, token: []const u8) ![]const u8 {
    var decoded: std.ArrayList(u8) = .empty;
    errdefer decoded.deinit(a);
    var lines = std.mem.splitScalar(u8, token, '\n');
    var first = true;
    while (lines.next()) |line| {
        const content = if (first) line else std.mem.trimStart(u8, line, " \t");
        if (!first) try decoded.append(a, '\n');
        try decoded.appendSlice(a, std.mem.trimEnd(u8, content[1..], "\r"));
        first = false;
    }
    return decoded.toOwnedSlice(a);
}
