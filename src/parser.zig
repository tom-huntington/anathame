const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;
const Value = @import("runtime.zig").Value;
pub const Instruction = union(enum) {
    literal: Value,
    cases: Value,
    primitive: []const u8,
    partition: *const Instruction,
    scan: *const Instruction,
    rows: *const Instruction,
    reduce: *const Instruction,
    stencil: struct { function: *const Instruction, size: ?Value = null },
    partial: struct { name: []const u8, argument: Value },
    choices: []const Instruction,
    function_choices: []const Instruction,
    alternative,
    product: struct { branches: []const []const Instruction, shape: []const usize, function_alternatives: bool = false },
    combinator: enum { n, s, sig, b, phi, psi },
    scope: struct { arity: usize, instructions: []const Instruction, default_arguments: ?[]const Value = null },
};
pub fn parse(a: std.mem.Allocator, source: []const u8) ![]const Instruction {
    var lexer: Lexer = .{ .source = source };
    var names: std.StringHashMapUnmanaged(Instruction) = .empty;
    defer names.deinit(a);
    while (true) {
        const start = lexer.offset;
        const name = (try lexer.next()) orelse break;
        const equals = try lexer.next();
        if (equals == null or !std.mem.eql(u8, equals.?, "=")) {
            lexer.offset = start;
            break;
        }
        if (!validName(name) or @import("primitives.zig").known(name) or
            std.mem.eql(u8, name, "sum") or std.mem.eql(u8, name, "Pairwise") or
            std.mem.eql(u8, name, "tup")) return error.InvalidFunctionName;
        if (names.contains(name)) return error.DuplicateFunctionName;
        const body_start = lexer.offset;
        var depth: usize = 0;
        while (true) {
            const before = lexer.offset;
            const token = (try lexer.next()) orelse break;
            if (depth == 0 and std.mem.indexOfScalar(u8, source[before .. lexer.offset - token.len], '\n') != null) {
                lexer.offset = before;
                break;
            }
            if (std.mem.eql(u8, token, "(") or std.mem.eql(u8, token, "{") or std.mem.eql(u8, token, "[")) depth += 1;
            if (std.mem.eql(u8, token, ")") or std.mem.eql(u8, token, "}") or std.mem.eql(u8, token, "]")) {
                if (depth == 0) return error.UnexpectedClose;
                depth -= 1;
            }
        }
        var body_lexer: Lexer = .{ .source = source[body_start..lexer.offset] };
        const declaration = (try body_lexer.next()) orelse return error.InvalidSyntax;
        if (!std.mem.eql(u8, declaration, "(") and !std.mem.eql(u8, declaration, "{") and
            !std.mem.eql(u8, declaration, "\\") and !std.mem.eql(u8, declaration, "\\\\")) return error.InvalidSyntax;
        body_lexer.offset = 0;
        const body = try sequence(a, &body_lexer, null, false, true, &names);
        if (body.len != 1 or body[0] != .scope) return error.InvalidSyntax;
        try names.put(a, name, body[0]);
    }
    return sequence(a, &lexer, null, false, true, &names);
}

pub fn parseProgram(a: std.mem.Allocator, source: []const u8) !Instruction {
    const instructions = try parse(a, source);
    if (instructions.len != 1 or instructions[0] != .scope) return error.InvalidSyntax;
    return instructions[0];
}

fn validName(name: []const u8) bool {
    if (name.len == 0 or !std.ascii.isAlphabetic(name[0])) return false;
    for (name[1..]) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}

fn sequence(a: std.mem.Allocator, lexer: *Lexer, close: ?[]const u8, implicit: bool, root: bool, names: *const std.StringHashMapUnmanaged(Instruction)) anyerror![]const Instruction {
    var result: std.ArrayList(Instruction) = .empty;
    while (try lexer.next()) |token| {
        if (std.mem.eql(u8, token, "|n") or std.mem.eql(u8, token, "|s") or std.mem.eql(u8, token, "|sig") or std.mem.eql(u8, token, "|b") or std.mem.eql(u8, token, "|phi") or std.mem.eql(u8, token, "|psi")) {
            if (result.items.len == 0 or result.items[result.items.len - 1] == .combinator) return error.ExpectedFunction;
            try result.append(a, .{ .combinator = if (token[1] == 'n') .n else if (std.mem.eql(u8, token, "|sig")) .sig else if (token[1] == 's') .s else if (std.mem.eql(u8, token, "|psi")) .psi else if (token[1] == 'p') .phi else .b });
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
            const body = try sequence(a, lexer, close, implicit, root, names);
            if (body.len != 1 or body[0] != .scope) return error.ExpectedFunction;
            var application = body[0];
            application.scope.arity = arguments.len;
            application.scope.default_arguments = arguments;
            return a.dupe(Instruction, &.{application});
        }
        if (std.mem.eql(u8, token, ")") or std.mem.eql(u8, token, "}")) {
            if (close == null or !std.mem.eql(u8, token, close.?)) return error.InvalidSyntax;
            if (implicit) lexer.offset -= token.len;
            return bindFunctions(a, result.items, !root);
        }
        const monadic = std.mem.eql(u8, token, "(") or std.mem.eql(u8, token, "\\");
        const dyadic = std.mem.eql(u8, token, "{") or std.mem.eql(u8, token, "\\\\");
        if (monadic or dyadic) {
            const is_implicit = token[0] == '\\';
            const end = if (is_implicit) close else if (monadic) ")" else "}";
            const body = try sequence(a, lexer, end, is_implicit, false, names);
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
            var choices: std.ArrayList(Instruction) = .empty;
            try choices.append(a, .{ .partial = .{ .name = name, .argument = value } });
            while (true) {
                const offset = lexer.offset;
                const separator = try lexer.next();
                if (separator == null or !std.mem.eql(u8, separator.?, "*")) {
                    lexer.offset = offset;
                    break;
                }
                const next = (try lexer.next()) orelse return error.ExpectedLiteral;
                const choice = (try strand(a, lexer, next)) orelse return error.ExpectedLiteral;
                try choices.append(a, .{ .partial = .{ .name = name, .argument = choice } });
            }
            previous.* = if (choices.items.len == 1) choices.items[0] else .{ .choices = try choices.toOwnedSlice(a) };
            continue;
        }
        if (std.mem.eql(u8, token, "**")) {
            try result.append(a, .alternative);
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
        if (names.get(token)) |function| {
            try result.append(a, function);
            continue;
        }
        if (std.mem.eql(u8, token, "sum")) {
            try result.appendSlice(a, try parse(a, "Reduce add"));
            continue;
        }
        if (std.mem.eql(u8, token, "Pairwise")) {
            try result.append(a, .{ .partial = .{ .name = "Stencil", .argument = .{ .data = &.{2} } } });
            continue;
        }
        if (std.mem.startsWith(u8, token, "re.") and @import("primitives.zig").known(token)) {
            const pattern = (try lexer.next()) orelse return error.ExpectedLiteral;
            // Regex literals preserve backslashes for the regex parser.
            const escaped = if (pattern[0] == '"') try std.mem.replaceOwned(u8, a, pattern, "\\", "\\\\") else pattern;
            defer if (pattern[0] == '"') a.free(escaped);
            const argument = (try strand(a, lexer, escaped)) orelse return error.ExpectedLiteral;
            try result.append(a, .{ .partial = .{ .name = token, .argument = argument } });
            continue;
        }
        if (try strand(a, lexer, token)) |value| {
            try result.append(a, .{ .literal = value });
        } else {
            if (!@import("primitives.zig").known(token)) {
                std.debug.print("Unknown primitive: {s}\n", .{token});
                return error.UnknownPrimitive;
            }
            try result.append(a, .{ .primitive = token });
        }
    }
    if (close != null and !implicit) return error.InvalidSyntax;
    if (result.items.len > 0 and result.items[result.items.len - 1] == .combinator) return error.ExpectedFunction;
    return bindFunctions(a, result.items, !root);
}
// Fold from the right after partial applications have been parsed.
fn bindFunctions(a: std.mem.Allocator, input: []const Instruction, lift_scopes: bool) anyerror![]const Instruction {
    // Lift grouped function alternatives so subsequent functions compose with
    // each branch. Keep the outermost scope as the program arity declaration.
    var prepared: std.ArrayList(Instruction) = .empty;
    for (input) |original| {
        var instruction = original;
        if (lift_scopes and instruction == .scope) {
            const body = instruction.scope.instructions;
            if (body.len == 1 and body[0] == .product and body[0].product.function_alternatives) {
                const alternatives = try a.alloc(Instruction, body[0].product.branches.len);
                for (alternatives, body[0].product.branches) |*choice, branch| {
                    choice.* = instruction;
                    choice.scope.instructions = branch;
                }
                instruction = .{ .function_choices = alternatives };
            }
        }
        try prepared.append(a, instruction);
    }
    var expanded: std.ArrayList(Instruction) = .empty;
    var cursor: usize = 0;
    while (cursor < prepared.items.len) {
        var instruction = prepared.items[cursor];
        cursor += 1;
        if (instruction == .alternative) return error.ExpectedFunction;
        if (cursor < prepared.items.len and prepared.items[cursor] == .alternative) {
            var choices: std.ArrayList(Instruction) = .empty;
            if (instruction == .literal or instruction == .combinator) return error.ExpectedFunction;
            if (instruction == .function_choices) try choices.appendSlice(a, instruction.function_choices) else try choices.append(a, instruction);
            while (cursor < prepared.items.len and prepared.items[cursor] == .alternative) {
                cursor += 1;
                if (cursor == prepared.items.len) return error.ExpectedFunction;
                const next = prepared.items[cursor];
                cursor += 1;
                if (next == .literal or next == .combinator or next == .alternative) return error.ExpectedFunction;
                if (next == .function_choices) try choices.appendSlice(a, next.function_choices) else try choices.append(a, next);
            }
            instruction = .{ .function_choices = try choices.toOwnedSlice(a) };
        }
        try expanded.append(a, instruction);
    }
    const instructions = expanded.items;
    var dimensions: std.ArrayList(usize) = .empty;
    var count: usize = 1;
    var function_alternatives = false;
    for (instructions) |instruction| {
        if (instruction == .function_choices) function_alternatives = true;
        if (instruction == .choices or instruction == .function_choices) {
            const choices = if (instruction == .choices) instruction.choices else instruction.function_choices;
            try dimensions.append(a, choices.len);
            count = try std.math.mul(usize, count, choices.len);
        }
    }
    if (dimensions.items.len > 0) {
        const branches = try a.alloc([]const Instruction, count);
        for (branches, 0..) |*branch, index| {
            const selected = try a.dupe(Instruction, instructions);
            var remaining = index;
            // Function alternatives follow source order; literal-only products
            // retain their existing first-choice-fastest ordering.
            var stride = count;
            for (selected) |*instruction| {
                if (instruction.* == .choices or instruction.* == .function_choices) {
                    const choices = if (instruction.* == .choices) instruction.choices else instruction.function_choices;
                    if (function_alternatives) {
                        stride /= choices.len;
                        instruction.* = choices[(index / stride) % choices.len];
                    } else {
                        instruction.* = choices[remaining % choices.len];
                        remaining /= choices.len;
                    }
                }
            }
            branch.* = try bindFunctions(a, selected, false);
        }
        if (!function_alternatives) std.mem.reverse(usize, dimensions.items);
        return a.dupe(Instruction, &.{.{ .product = .{ .branches = branches, .shape = try dimensions.toOwnedSlice(a), .function_alternatives = function_alternatives } }});
    }
    var result: std.ArrayList(Instruction) = .empty;
    var i = instructions.len;
    while (i > 0) {
        i -= 1;
        const instruction = instructions[i];
        const name = switch (instruction) {
            .primitive => |name| name,
            .partial => |partial| partial.name,
            else => "",
        };
        if (std.mem.eql(u8, name, "Partition") or std.mem.eql(u8, name, "Scan") or std.mem.eql(u8, name, "Rows") or std.mem.eql(u8, name, "Reduce") or std.mem.eql(u8, name, "Stencil")) {
            const operand = result.pop() orelse return error.ExpectedFunction;
            if (operand == .combinator or operand == .literal) return error.ExpectedFunction;
            const function = try a.create(Instruction);
            function.* = operand;
            try result.append(a, if (std.mem.eql(u8, name, "Partition")) .{ .partition = function } else if (std.mem.eql(u8, name, "Scan")) .{ .scan = function } else if (std.mem.eql(u8, name, "Rows")) .{ .rows = function } else if (std.mem.eql(u8, name, "Reduce")) .{ .reduce = function } else .{ .stencil = .{ .function = function, .size = if (instruction == .partial) instruction.partial.argument else null } });
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
        try decoded.appendSlice(a, std.mem.trimEnd(u8, content[2..], "\r"));
        first = false;
    }
    return decoded.toOwnedSlice(a);
}
