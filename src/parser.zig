const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;
const Value = @import("runtime.zig").Value;
pub const Instruction = union(enum) {
    component: struct { function: *const Instruction, dimensions: ?usize, type_shape: []const usize = &.{} },
    literal: Value,
    variable: []const u8,
    aggregate: struct { items: []const Instruction, tuple: bool = false },
    expression: struct { arguments: []const Instruction, body: []const Instruction },
    dynamic_applied: struct { function: *const Instruction, argument: *const Instruction },
    cases: Value,
    primitive: []const u8,
    partition: *const Instruction,
    sort_with: *const Instruction,
    scan: struct { function: *const Instruction, exclusive: bool = false },
    partials: *const Instruction,
    rows: *const Instruction,
    table: *const Instruction,
    flip: *const Instruction,
    join: *const Instruction,
    switch_fn: struct { yes: *const Instruction, no: *const Instruction },
    unc: *const Instruction,
    log: *const Instruction,
    logshape: *const Instruction,
    reduce: *const Instruction,
    fold: *const Instruction,
    map_accum: struct { map: *const Instruction, update: *const Instruction },
    repeat: struct { first: *const Instruction, second: ?*const Instruction = null, count: ?Value = null, fixed: bool = false, check: bool = false },
    stencil: struct { function: *const Instruction },
    applied: struct { function: *const Instruction, argument: Value },
    tuples: struct { predicate: *const Instruction, function: *const Instruction },
    partial: struct { name: []const u8, argument: Value },
    choices: []const Instruction,
    function_choices: []const Instruction,
    alternative,
    product: struct { branches: []const []const Instruction, shape: []const usize, function_alternatives: bool = false },
    combinator: enum { n, nu, s, sig, b, phi, psi, d, delta, d2, phi1 },
    scope: struct { macro_definition: ?*const Macro = null, parameters: []const Pattern = &.{}, arity: usize, instructions: []const Instruction, default_arguments: ?[]const Value = null },
};
// Macro bodies are parsed after their function operands have been substituted.
const Macro = struct {
    source: []const u8,
    names: std.StringHashMapUnmanaged(Instruction),
    operands: usize,
};
pub const Pattern = union(enum) { name: []const u8, items: []const Pattern };

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
        if (!validDefinitionName(name) or @import("primitives.zig").known(name) or
            std.mem.eql(u8, name, "rsub") or std.mem.eql(u8, name, "sum") or std.mem.eql(u8, name, "total") or std.mem.eql(u8, name, "split") or std.mem.eql(u8, name, "Pairwise") or
            std.mem.eql(u8, name, "combinations") or std.mem.eql(u8, name, "tup")) return error.InvalidFunctionName;
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
        const source_body = source[body_start..lexer.offset];
        var placeholders: Lexer = .{ .source = source_body };
        var has_f = false;
        var has_g = false;
        while (try placeholders.next()) |token| {
            has_f = has_f or std.mem.eql(u8, token, "F");
            has_g = has_g or std.mem.eql(u8, token, "G");
        }
        const is_hof = std.ascii.isUpper(name[0]);
        if (is_hof != has_f or (has_g and !has_f)) return error.InvalidFunctionName;
        if (is_hof) {
            var declaration_lexer: Lexer = .{ .source = source_body };
            const declaration = (try declaration_lexer.next()) orelse return error.InvalidSyntax;
            if (!std.mem.eql(u8, declaration, "(") and !std.mem.eql(u8, declaration, "{") and
                !std.mem.eql(u8, declaration, "\\") and !std.mem.eql(u8, declaration, "\\\\")) return error.InvalidSyntax;
            const macro = try a.create(Macro);
            macro.* = .{ .source = source_body, .names = try names.clone(a), .operands = if (has_g) 2 else 1 };
            try names.put(a, name, .{ .scope = .{ .arity = 0, .instructions = &.{}, .macro_definition = macro } });
            continue;
        }
        var body_lexer: Lexer = .{ .source = source[body_start..lexer.offset] };
        const declaration = (try body_lexer.next()) orelse return error.InvalidSyntax;
        const is_function = std.mem.eql(u8, declaration, "(") or std.mem.eql(u8, declaration, "{") or
            std.mem.eql(u8, declaration, "\\") or std.mem.eql(u8, declaration, "\\\\");
        if (!is_function and (try strand(a, &body_lexer, declaration, &names)) == null) {
            std.debug.print("Invalid declaration for '{s}': expected a constant or a function with an explicit arity.\nTo declare a unary function, write: {s} =\\ {s} ...\n", .{ name, name, declaration });
            return error.InvalidSyntax;
        }
        body_lexer.offset = 0;
        const body = try sequence(a, &body_lexer, null, false, true, &names);
        if (body.len != 1) return error.InvalidSyntax;
        const definition: Instruction = if (is_function) blk: {
            if (body[0] != .scope) return error.InvalidSyntax;
            break :blk body[0];
        } else if (body[0] == .literal) body[0] else blk: {
            if (body[0] != .scope or body[0].scope.default_arguments == null) return error.InvalidSyntax;
            break :blk .{ .literal = try @import("runtime.zig").evaluateConstant(a, body[0]) };
        };
        try names.put(a, name, definition);
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

fn validDefinitionName(name: []const u8) bool {
    if (!validName(name) or std.mem.eql(u8, name, "F") or std.mem.eql(u8, name, "G")) return false;
    if (std.ascii.isUpper(name[0])) {
        // TitleCase: capitalized words, without underscores or acronyms.
        for (name, 0..) |c, i| {
            if (c == '_') return false;
            if (i > 0 and std.ascii.isUpper(c) and std.ascii.isUpper(name[i - 1])) return false;
        }
    } else {
        for (name, 0..) |c, i| {
            if (std.ascii.isUpper(c)) return false;
            if (c == '_' and (i == name.len - 1 or name[i - 1] == '_')) return false;
        }
    }
    return true;
}

fn sequence(a: std.mem.Allocator, lexer: *Lexer, close: ?[]const u8, implicit: bool, root: bool, names: *const std.StringHashMapUnmanaged(Instruction)) anyerror![]const Instruction {
    var result: std.ArrayList(Instruction) = .empty;
    while (try lexer.next()) |token| {
        if (std.mem.eql(u8, token, "|d2") or std.mem.eql(u8, token, "|phi1") or std.mem.eql(u8, token, "|d") or std.mem.eql(u8, token, "|delta") or std.mem.eql(u8, token, "|n") or std.mem.eql(u8, token, "|nu") or std.mem.eql(u8, token, "|s") or std.mem.eql(u8, token, "|sig") or std.mem.eql(u8, token, "|b") or std.mem.eql(u8, token, "|phi") or std.mem.eql(u8, token, "|psi")) {
            if (result.items.len == 0 or result.items[result.items.len - 1] == .combinator) return error.ExpectedFunction;
            try result.append(a, .{ .combinator = if (std.mem.eql(u8, token, "|d2")) .d2 else if (std.mem.eql(u8, token, "|phi1")) .phi1 else if (std.mem.eql(u8, token, "|delta")) .delta else if (std.mem.eql(u8, token, "|d")) .d else if (std.mem.eql(u8, token, "|nu")) .nu else if (token[1] == 'n') .n else if (std.mem.eql(u8, token, "|sig")) .sig else if (token[1] == 's') .s else if (std.mem.eql(u8, token, "|psi")) .psi else if (token[1] == 'p') .phi else .b });
            continue;
        }
        if (result.items.len > 0 and result.items[result.items.len - 1] == .combinator and
            (std.mem.eql(u8, token, ")") or std.mem.eql(u8, token, "}") or std.mem.eql(u8, token, "|>"))) return error.ExpectedFunction;
        if (std.mem.eql(u8, token, "|>")) {
            if (result.items.len < 1 or result.items.len > 2) return error.WrongNumberOfArguments;
            const dynamic = for (result.items) |item| {
                if (item != .literal) break true;
            } else false;
            if (dynamic) {
                for (result.items) |item| if (!isValue(item)) return error.ExpectedLiteral;
                const body = try sequence(a, lexer, close, implicit, root, names);
                if (body.len == 0) return error.ExpectedFunction;
                return a.dupe(Instruction, &.{.{ .expression = .{ .arguments = try result.toOwnedSlice(a), .body = body } }});
            }
            const arguments = try a.alloc(Value, result.items.len);
            for (result.items, arguments) |instruction, *argument| {
                argument.* = switch (instruction) {
                    .literal => |value| value,
                    else => return error.ExpectedLiteral,
                };
            }
            const body = try sequence(a, lexer, close, implicit, root, names);
            if (body.len == 0) return error.ExpectedFunction;
            var application: Instruction = if (body.len == 1 and body[0] == .scope) body[0] else .{ .scope = .{ .arity = arguments.len, .instructions = body } };
            application.scope.arity = arguments.len;
            try validateCombinatorArity(application.scope.instructions, arguments.len);
            application.scope.default_arguments = arguments;
            return a.dupe(Instruction, &.{application});
        }
        if (std.mem.eql(u8, token, ")") or std.mem.eql(u8, token, "}") or std.mem.eql(u8, token, "]")) {
            if (close == null or !std.mem.eql(u8, token, close.?)) return error.InvalidSyntax;
            if (implicit) lexer.offset -= token.len;
            return bindFunctions(a, result.items, !root);
        }
        const monadic = std.mem.eql(u8, token, "(") or std.mem.eql(u8, token, "\\");
        const dyadic = std.mem.eql(u8, token, "{") or std.mem.eql(u8, token, "\\\\");
        if (monadic or dyadic) {
            const is_implicit = token[0] == '\\';
            const end = if (is_implicit) close else if (monadic) ")" else "}";
            var local_names = try names.clone(a);
            defer local_names.deinit(a);
            const parameters = try lambdaParameters(a, lexer, &local_names);
            if (parameters.len != 0 and parameters.len != (if (monadic) @as(usize, 1) else 2)) return error.WrongNumberOfArguments;
            const body = try sequence(a, lexer, end, is_implicit, false, &local_names);
            if (body.len == 0) return error.InvalidSyntax;
            if (parameters.len == 0) {
                for (body) |instruction| if (instruction == .literal) return error.ExpectedFunction;
            }
            try validateCombinatorArity(body, if (monadic) 1 else 2);
            try result.append(a, .{ .scope = .{ .parameters = parameters, .arity = if (monadic) 1 else 2, .instructions = body } });
            continue;
        }
        if (std.mem.eql(u8, token, ",")) {
            if (result.items.len == 0) return error.ExpectedFunction;
            const previous = &result.items[result.items.len - 1];
            const selected_component = if (previous.* == .component) previous.component else null;
            if (selected_component) |c| previous.* = c.function.*;
            const name = if (previous.* == .primitive) previous.primitive else "";
            if (previous.* != .primitive and previous.* != .scope) return error.ExpectedFunction;
            if (previous.* == .scope and previous.scope.arity != 2) return error.WrongNumberOfArguments;
            if (previous.* == .primitive and @import("primitives.zig").arity(name) != 2) return error.WrongNumberOfArguments;
            const function = try a.create(Instruction);
            function.* = previous.*;
            const argument = (try lexer.next()) orelse return error.ExpectedLiteral;
            const parsed_argument = (try valueExpression(a, lexer, argument, names, 0)) orelse return error.ExpectedLiteral;
            if (parsed_argument != .literal) {
                const arg = try a.create(Instruction);
                arg.* = parsed_argument;
                previous.* = .{ .dynamic_applied = .{ .function = function, .argument = arg } };
                if (selected_component) |c| {
                    const selected = try a.create(Instruction);
                    selected.* = previous.*;
                    previous.* = .{ .component = .{ .function = selected, .dimensions = c.dimensions, .type_shape = c.type_shape } };
                }
                continue;
            }
            const value = parsed_argument.literal;
            var choices: std.ArrayList(Instruction) = .empty;
            try choices.append(a, if (name.len != 0) .{ .partial = .{ .name = name, .argument = value } } else .{ .applied = .{ .function = function, .argument = value } });
            while (true) {
                const offset = lexer.offset;
                const separator = try lexer.next();
                if (separator == null or !std.mem.eql(u8, separator.?, "***")) {
                    lexer.offset = offset;
                    break;
                }
                const next = (try lexer.next()) orelse return error.ExpectedLiteral;
                const choice = (try strand(a, lexer, next, names)) orelse return error.ExpectedLiteral;
                try choices.append(a, if (name.len != 0) .{ .partial = .{ .name = name, .argument = choice } } else .{ .applied = .{ .function = function, .argument = choice } });
            }
            if (selected_component) |c| {
                for (choices.items) |*choice| {
                    const selected = try a.create(Instruction);
                    selected.* = choice.*;
                    choice.* = .{ .component = .{ .function = selected, .dimensions = c.dimensions, .type_shape = c.type_shape } };
                }
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
            const table = try array(a, lexer, names);
            if (table.shape.len != 2 or table.shape[1] != 2) return @import("runtime.zig").shapeMismatch("Cases requires a two-column table", &.{table});
            try result.append(a, .{ .cases = table });
            continue;
        }
        if (std.mem.eql(u8, token, "]")) return error.UnexpectedClose;
        if (try valueExpression(a, lexer, token, names, 0)) |value| {
            try result.append(a, value);
            continue;
        }
        if (names.get(token)) |function| {
            try result.append(a, function);
            continue;
        }
        if (std.mem.eql(u8, token, "first") or std.mem.eql(u8, token, "last") or std.mem.eql(u8, token, "second") or std.mem.startsWith(u8, token, "first.") or (std.mem.startsWith(u8, token, "last.") and !std.mem.eql(u8, token, "last.row"))) {
            const dot = std.mem.indexOfScalar(u8, token, '.');
            const name = token[0 .. dot orelse token.len];
            const suffix = if (dot) |i| token[i..] else if (std.mem.eql(u8, name, "second")) "" else ".r";
            const index = if (std.mem.eql(u8, name, "first")) "0" else if (std.mem.eql(u8, name, "last")) "-1" else "1";
            try result.appendSlice(a, try parse(a, try std.fmt.allocPrint(a, "select{s},{s}", .{ suffix, index })));
            continue;
        }
        if (std.mem.eql(u8, token, "combinations") or std.mem.startsWith(u8, token, "combinations.")) {
            const suffix = token["combinations".len..];
            try result.appendSlice(a, try parse(a, try std.fmt.allocPrint(a, "Tuples{s},2 less", .{suffix})));
            continue;
        }
        if (std.mem.eql(u8, token, "sum")) {
            try result.appendSlice(a, try parse(a, "Fold,0 add"));
            continue;
        }
        if (std.mem.eql(u8, token, "total")) {
            try result.appendSlice(a, try parse(a, "(flatten sum)"));
            continue;
        }
        if (std.mem.eql(u8, token, "rsub")) {
            try result.appendSlice(a, try parse(a, "{Flip sub}"));
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
            const argument = (try strand(a, lexer, escaped, names)) orelse return error.ExpectedLiteral;
            try result.append(a, .{ .partial = .{ .name = token, .argument = argument } });
            continue;
        }
        if (std.mem.indexOfScalar(u8, token, '.')) |dot| {
            const name = token[0..dot];
            if (std.mem.eql(u8, name, "select") or std.mem.eql(u8, name, "indexin") or std.mem.eql(u8, name, "sort") or std.mem.eql(u8, name, "deduplicate") or std.mem.eql(u8, name, "uncons") or std.mem.eql(u8, name, "Unc") or std.mem.eql(u8, name, "Reduce") or std.mem.eql(u8, name, "Fold") or std.mem.eql(u8, name, "Scan") or std.mem.eql(u8, name, "Partials") or std.mem.eql(u8, name, "Tuples") or std.mem.eql(u8, name, "TuplesWith")) {
                var parts = std.mem.splitScalar(u8, token[dot + 1 ..], '.');
                var type_dimension: usize = 0;
                var type_shape: []const usize = &.{};
                var axis_dimension: usize = 0;
                var has_type = false;
                var has_axis = false;
                var outer = false;
                var exclusive = false;
                while (parts.next()) |part| {
                    if (std.mem.eql(u8, part, "exclusive")) {
                        if (!std.mem.eql(u8, name, "Scan") or exclusive) return error.InvalidComponent;
                        exclusive = true;
                    } else if (part.len > 0 and (part[0] == 'r' or part[0] == 'c') and (part.len == 1 or std.ascii.isDigit(part[1]))) {
                        if (has_type or has_axis) return error.InvalidComponent;
                        has_type = true;
                        // Each digit adds a fixed dimension; complex scalars add a trailing pair.
                        type_dimension = part.len - 1 + @as(usize, if (part[0] == 'c') 1 else 0);
                        const shape = try a.alloc(usize, type_dimension);
                        for (part[1..], 0..) |digit, i| {
                            if (digit < '0' or digit > '9') return error.InvalidComponent;
                            shape[i] = digit - '0';
                        }
                        if (part[0] == 'c') shape[shape.len - 1] = 2;
                        type_shape = shape;
                    } else if (std.mem.eql(u8, part, "vec") or std.mem.eql(u8, part, "mat")) {
                        if (has_axis) return error.InvalidComponent;
                        has_axis = true;
                        axis_dimension = if (std.mem.eql(u8, part, "vec")) 1 else 2;
                    } else if (std.mem.eql(u8, part, "rows") or std.mem.eql(u8, part, "grids") or std.mem.eql(u8, part, "outer")) {
                        if (has_axis) return error.InvalidComponent;
                        has_axis = true;
                        outer = std.mem.eql(u8, part, "outer");
                        axis_dimension = if (std.mem.eql(u8, part, "rows")) 1 else if (std.mem.eql(u8, part, "grids")) 2 else 0;
                    } else return error.InvalidComponent;
                }
                const function = try a.create(Instruction);
                function.* = .{ .primitive = if (exclusive) "Scan.exclusive" else name };
                if (!has_type and !has_axis and exclusive) {
                    try result.append(a, function.*);
                    continue;
                }
                try result.append(a, .{ .component = .{ .function = function, .dimensions = if (outer) null else type_dimension + axis_dimension, .type_shape = type_shape } });
                continue;
            }
        }
        if (try strand(a, lexer, token, names)) |value| {
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
fn printArityInstruction(instruction: Instruction) void {
    switch (instruction) {
        .primitive, .variable => |name| std.debug.print("{s}", .{name}),
        .partial => |partial| std.debug.print("{s} (partially applied)", .{partial.name}),
        .component => |component| printArityInstruction(component.function.*),
        .scope => |scope| {
            std.debug.print("(", .{});
            for (scope.instructions, 0..) |child, i| {
                if (i > 0) std.debug.print(" ", .{});
                printArityInstruction(child);
            }
            std.debug.print(")", .{});
        },
        .combinator => |combinator| std.debug.print("|{s}", .{@tagName(combinator)}),
        else => std.debug.print("{s}", .{@tagName(instruction)}),
    }
}

// Composition preserves the input arity; the other combinators declare it.
fn validateCombinatorArity(body: []const Instruction, declared: usize) !void {
    // Ordinary composition passes one result onward (B/B1). Only an
    // explicit combinator may supply two arguments to a later function.
    var available = declared;
    var explicit_operands: usize = 0;
    var active_combinator: []const u8 = "b";
    var argument_source: ?Instruction = null;
    for (body, 0..) |instruction, index| {
        if (instruction == .combinator) {
            argument_source = null;
            active_combinator = @tagName(instruction.combinator);
            explicit_operands = switch (instruction.combinator) {
                .b => 0,
                .d2, .phi1 => 2,
                .phi => if (index + 1 < body.len and @import("runtime.zig").functionArity(body[index + 1]) == 2) 1 else if (index + 2 < body.len and @import("runtime.zig").functionArity(body[index + 2]) == 2) 2 else 3,
                else => 1,
            };
            available = if (instruction.combinator == .b) 1 else 2;
            continue;
        }
        if (instruction == .scope) try validateCombinatorArity(instruction.scope.instructions, instruction.scope.arity);
        if (explicit_operands > 0 and available == 2) {
            explicit_operands -= 1;
        } else if (@import("runtime.zig").functionArity(instruction)) |arity| {
            if (arity > available) {
                std.debug.print("WrongNumberOfArguments: combinator |{s}: expected {d} argument(s), actual {d}.\n", .{ active_combinator, arity, available });
                std.debug.print("  Function: ", .{});
                printArityInstruction(instruction);
                std.debug.print("\n  Arguments: ", .{});
                if (argument_source) |source| {
                    std.debug.print("result of ", .{});
                    printArityInstruction(source);
                    std.debug.print(" (composition passes one result onward).\n", .{});
                } else {
                    std.debug.print("{d} input argument(s) from the enclosing function.\n", .{available});
                }
                std.debug.print("  Argument values, types, and shapes are unknown during parsing.\n", .{});
                return error.WrongNumberOfArguments;
            }
        }
        if (explicit_operands == 0) {
            available = 1;
            active_combinator = "b";
            argument_source = instruction;
        }
    }
    var result_arity: ?usize = null;
    var combinator_name: []const u8 = "";
    for (body) |instruction| {
        if (instruction == .product) {
            for (instruction.product.branches) |branch| try validateCombinatorArity(branch, declared);
        }
        if (instruction != .combinator) continue;
        switch (instruction.combinator) {
            .s, .sig => {
                result_arity = 1;
                combinator_name = @tagName(instruction.combinator);
            },
            .n, .nu, .d, .delta, .psi, .d2, .phi1 => {
                result_arity = 2;
                combinator_name = @tagName(instruction.combinator);
            },
            .b, .phi => {},
        }
    }
    if (result_arity) |arity| if (arity != declared) {
        std.debug.print("WrongNumberOfArguments: combinator |{s}: expected {d} argument(s), actual {d}.\n", .{ combinator_name, arity, declared });
        return error.WrongNumberOfArguments;
    };
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
        var instruction = instructions[i];
        if (instruction == .scope and instruction.scope.macro_definition != null) {
            const macro = instruction.scope.macro_definition.?;
            var local_names = try macro.names.clone(a);
            defer local_names.deinit(a);
            for (([_][]const u8{ "F", "G" })[0..macro.operands]) |placeholder| {
                const operand = result.pop() orelse return error.ExpectedFunction;
                if (isValue(operand) or operand == .combinator or operand == .alternative) return error.ExpectedFunction;
                try local_names.put(a, placeholder, operand);
            }
            var body_lexer: Lexer = .{ .source = macro.source };
            const body = try sequence(a, &body_lexer, null, false, true, &local_names);
            if (body.len != 1 or body[0] != .scope or body[0].scope.macro_definition != null) return error.InvalidSyntax;
            instruction = body[0];
        }
        const component = if (instruction == .component) instruction.component else null;
        if (component) |c| instruction = c.function.*;
        const dynamic = if (instruction == .dynamic_applied and instruction.dynamic_applied.function.* == .primitive) instruction.dynamic_applied else null;
        if (dynamic) |application| instruction = .{ .partial = .{ .name = application.function.primitive, .argument = .{ .data = &.{0} } } };
        const name = switch (instruction) {
            .primitive => |name| name,
            .partial => |partial| partial.name,
            else => "",
        };
        if (std.mem.eql(u8, name, "Switch")) {
            const yes = result.pop() orelse return error.ExpectedFunction;
            const no = result.pop() orelse return error.ExpectedFunction;
            if (@import("runtime.zig").functionArity(yes) != 1 or @import("runtime.zig").functionArity(no) != 1) return error.WrongNumberOfArguments;
            const yes_ptr = try a.create(Instruction);
            yes_ptr.* = yes;
            const no_ptr = try a.create(Instruction);
            no_ptr.* = no;
            var bound: Instruction = .{ .switch_fn = .{ .yes = yes_ptr, .no = no_ptr } };
            if (instruction == .partial) {
                const function = try a.create(Instruction);
                function.* = bound;
                bound = .{ .applied = .{ .function = function, .argument = instruction.partial.argument } };
            }
            try result.append(a, bound);
        } else if (std.mem.eql(u8, name, "Join")) {
            if (instruction == .partial) return error.WrongNumberOfArguments;
            const operand = result.pop() orelse return error.ExpectedFunction;
            if (@import("runtime.zig").functionArity(operand) != 2) return error.WrongNumberOfArguments;
            const function = try a.create(Instruction);
            function.* = operand;
            try result.append(a, .{ .join = function });
        } else if (std.mem.eql(u8, name, "Flip")) {
            const operand = result.pop() orelse return error.ExpectedFunction;
            if (@import("runtime.zig").functionArity(operand) != 2) return error.WrongNumberOfArguments;
            const function = try a.create(Instruction);
            function.* = operand;
            const bound: Instruction = .{ .flip = function };
            if (instruction == .partial) {
                const flipped = try a.create(Instruction);
                flipped.* = bound;
                try result.append(a, .{ .applied = .{ .function = flipped, .argument = instruction.partial.argument } });
            } else try result.append(a, bound);
        } else if (std.mem.eql(u8, name, "Log") or std.mem.eql(u8, name, "Logshape")) {
            const operand = result.pop() orelse return error.ExpectedFunction;
            const arity = @import("runtime.zig").functionArity(operand) orelse return error.ExpectedFunction;
            if (instruction == .partial and arity != 2) return error.WrongNumberOfArguments;
            const function = try a.create(Instruction);
            function.* = operand;
            var bound: Instruction = if (std.mem.eql(u8, name, "Logshape")) .{ .logshape = function } else .{ .log = function };
            if (instruction == .partial) {
                const logged = try a.create(Instruction);
                logged.* = bound;
                bound = .{ .applied = .{ .function = logged, .argument = instruction.partial.argument } };
            }
            try result.append(a, bound);
        } else if (std.mem.eql(u8, name, "Unc")) {
            const operand = result.pop() orelse return error.ExpectedFunction;
            if (operand == .combinator or operand == .literal) return error.ExpectedFunction;
            const function = try a.create(Instruction);
            function.* = operand;
            try result.append(a, .{ .unc = function });
        } else if (std.mem.eql(u8, name, "MapAccum")) {
            const map = result.pop() orelse return error.ExpectedFunction;
            const update = result.pop() orelse return error.ExpectedFunction;
            if (@import("runtime.zig").functionArity(map) != 2 or @import("runtime.zig").functionArity(update) != 2) return error.WrongNumberOfArguments;
            const map_ptr = try a.create(Instruction);
            map_ptr.* = map;
            const update_ptr = try a.create(Instruction);
            update_ptr.* = update;
            var bound: Instruction = .{ .map_accum = .{ .map = map_ptr, .update = update_ptr } };
            if (instruction == .partial) {
                const function = try a.create(Instruction);
                function.* = bound;
                bound = .{ .applied = .{ .function = function, .argument = instruction.partial.argument } };
            }
            try result.append(a, bound);
        } else if (std.mem.eql(u8, name, "Repeat") or std.mem.eql(u8, name, "Fix") or std.mem.eql(u8, name, "Repeat.check") or std.mem.eql(u8, name, "Fix.check")) {
            const fixed = std.mem.startsWith(u8, name, "Fix");
            const operand = result.pop() orelse return error.ExpectedFunction;
            const arity = @import("runtime.zig").functionArity(operand) orelse return error.ExpectedFunction;
            const first = try a.create(Instruction);
            first.* = operand;
            var second: ?*const Instruction = null;
            if (arity == 2 and (instruction == .partial or fixed) and
                result.items.len > 0 and @import("runtime.zig").functionArity(result.items[result.items.len - 1]) == 2)
            {
                const other = result.pop().?;
                const ptr = try a.create(Instruction);
                ptr.* = other;
                second = ptr;
            }
            if (instruction == .partial and fixed) return error.WrongNumberOfArguments;
            try result.append(a, .{ .repeat = .{
                .first = first,
                .second = second,
                .count = if (instruction == .partial) instruction.partial.argument else null,
                .fixed = fixed,
                .check = std.mem.endsWith(u8, name, ".check"),
            } });
        } else if (std.mem.eql(u8, name, "Sort.by")) {
            const operand = result.pop() orelse return error.ExpectedFunction;
            if (@import("runtime.zig").functionArity(operand) == null) return error.ExpectedFunction;
            try result.append(a, .{ .scope = .{ .arity = 1, .instructions = try a.dupe(Instruction, &.{
                operand,
                .{ .primitive = "rise" },
                .{ .combinator = .sig },
                .{ .primitive = "select" },
            }) } });
        } else if (std.mem.eql(u8, name, "Sort.with")) {
            const operand = result.pop() orelse return error.ExpectedFunction;
            if (@import("runtime.zig").functionArity(operand) != 2) return error.WrongNumberOfArguments;
            const function = try a.create(Instruction);
            function.* = operand;
            try result.append(a, .{ .sort_with = function });
        } else if (std.mem.eql(u8, name, "Filter")) {
            const operand = result.pop() orelse return error.ExpectedFunction;
            if (operand == .combinator or operand == .literal) return error.ExpectedFunction;
            try result.append(a, .{ .scope = .{ .arity = 1, .instructions = try a.dupe(Instruction, &.{
                operand,
                .{ .combinator = .sig },
                .{ .primitive = "keep" },
            }) } });
        } else if (std.mem.eql(u8, name, "Partition") or std.mem.eql(u8, name, "Scan") or std.mem.eql(u8, name, "Scan.exclusive") or std.mem.eql(u8, name, "Partials") or std.mem.eql(u8, name, "Rows") or std.mem.eql(u8, name, "Reduce") or std.mem.eql(u8, name, "Fold") or std.mem.eql(u8, name, "Stencil") or std.mem.eql(u8, name, "Tuples") or std.mem.eql(u8, name, "TuplesWith") or std.mem.eql(u8, name, "Table")) {
            const operand = result.pop() orelse return error.ExpectedFunction;
            if (operand == .combinator or operand == .literal) return error.ExpectedFunction;
            if (std.mem.eql(u8, name, "Table") and @import("runtime.zig").functionArity(operand) != 2) return error.WrongNumberOfArguments;
            const function = try a.create(Instruction);
            function.* = operand;
            var tuple_function: ?*Instruction = null;
            if (std.mem.eql(u8, name, "Tuples") or std.mem.eql(u8, name, "TuplesWith")) {
                const mapper: Instruction = if (std.mem.eql(u8, name, "TuplesWith")) result.pop() orelse return error.ExpectedFunction else .{ .primitive = "couple" };
                if (@import("runtime.zig").functionArity(operand) != 2 or @import("runtime.zig").functionArity(mapper) != 2) return error.WrongNumberOfArguments;
                tuple_function = try a.create(Instruction);
                tuple_function.?.* = mapper;
            }
            var bound: Instruction = if (std.mem.eql(u8, name, "Partition")) .{ .partition = function } else if (std.mem.eql(u8, name, "Scan") or std.mem.eql(u8, name, "Scan.exclusive")) .{ .scan = .{ .function = function, .exclusive = std.mem.eql(u8, name, "Scan.exclusive") } } else if (std.mem.eql(u8, name, "Partials")) .{ .partials = function } else if (std.mem.eql(u8, name, "Rows")) .{ .rows = function } else if (std.mem.eql(u8, name, "Reduce")) .{ .reduce = function } else if (std.mem.eql(u8, name, "Fold")) .{ .fold = function } else if (std.mem.eql(u8, name, "Table")) .{ .table = function } else if (std.mem.eql(u8, name, "Tuples") or std.mem.eql(u8, name, "TuplesWith")) .{ .tuples = .{ .predicate = function, .function = tuple_function.? } } else .{ .stencil = .{ .function = function } };
            if (component) |c| {
                if (std.mem.eql(u8, name, "Tuples") or std.mem.eql(u8, name, "TuplesWith")) {
                    const selected = try a.create(Instruction);
                    selected.* = bound;
                    bound = .{ .component = .{ .function = selected, .dimensions = c.dimensions, .type_shape = c.type_shape } };
                }
            }
            if (instruction == .partial) {
                const scope = try a.create(Instruction);
                scope.* = .{ .scope = .{ .arity = 2, .instructions = try a.dupe(Instruction, &.{bound}) } };
                bound = .{ .applied = .{ .function = scope, .argument = instruction.partial.argument } };
            }
            try result.append(a, bound);
        } else try result.append(a, instruction);
        if (if (std.mem.eql(u8, name, "Tuples") or std.mem.eql(u8, name, "TuplesWith")) null else component) |c| {
            const bound = &result.items[result.items.len - 1];
            const function = try a.create(Instruction);
            function.* = bound.*;
            bound.* = .{ .component = .{ .function = function, .dimensions = c.dimensions, .type_shape = c.type_shape } };
        }
        if (dynamic) |application| {
            const bound = &result.items[result.items.len - 1];
            const function = try a.create(Instruction);
            const bound_component = if (bound.* == .component) bound.component else null;
            const inner = if (bound_component) |c| c.function.* else bound.*;
            function.* = switch (inner) {
                .partial => |partial| .{ .primitive = partial.name },
                .applied => |applied| applied.function.*,
                .repeat => |repeat| .{ .repeat = .{ .first = repeat.first, .second = repeat.second, .fixed = repeat.fixed, .check = repeat.check } },
                else => return error.ExpectedFunction,
            };
            if (bound_component) |c| {
                const selected = try a.create(Instruction);
                selected.* = function.*;
                function.* = .{ .component = .{ .function = selected, .dimensions = c.dimensions, .type_shape = c.type_shape } };
            }
            bound.* = .{ .dynamic_applied = .{ .function = function, .argument = application.argument } };
        }
    }
    std.mem.reverse(Instruction, result.items);
    return result.toOwnedSlice(a);
}

fn array(a: std.mem.Allocator, lexer: *Lexer, names: *const std.StringHashMapUnmanaged(Instruction)) anyerror!Value {
    var lookahead = lexer.*;
    var depth: usize = 0;
    while (try lookahead.next()) |token| {
        if (std.mem.eql(u8, token, "]") and depth == 0) break;
        if (depth == 0 and std.mem.eql(u8, token, "|>")) {
            const body = try sequence(a, lexer, "]", false, true, names);
            if (body.len != 1) return error.InvalidSyntax;
            const value = try @import("runtime.zig").evaluateConstant(a, body[0]);
            if (value.tuple != null) return error.ExpectedArray;
            return value;
        }
        if (std.mem.eql(u8, token, "[") or std.mem.eql(u8, token, "(") or std.mem.eql(u8, token, "{")) depth += 1;
        if (std.mem.eql(u8, token, "]") or std.mem.eql(u8, token, ")") or std.mem.eql(u8, token, "}")) {
            if (depth == 0) return error.InvalidSyntax;
            depth -= 1;
        }
    }
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
        const child = (try strand(a, lexer, token, names)) orelse return error.InvalidNumber;
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
fn tuple(a: std.mem.Allocator, lexer: *Lexer, names: *const std.StringHashMapUnmanaged(Instruction)) anyerror!Value {
    const open = (try lexer.next()) orelse return error.InvalidSyntax;
    if (!std.mem.eql(u8, open, "(")) return error.InvalidSyntax;
    var items: std.ArrayList(Value) = .empty;
    var token = (try lexer.next()) orelse return error.InvalidSyntax;
    if (std.mem.eql(u8, token, ")")) return .{ .tuple = try items.toOwnedSlice(a) };
    while (true) {
        const item = (try strand(a, lexer, token, names)) orelse return error.ExpectedLiteral;
        try items.append(a, item);
        const separator = (try lexer.next()) orelse return error.InvalidSyntax;
        if (std.mem.eql(u8, separator, ")")) return .{ .tuple = try items.toOwnedSlice(a) };
        if (!std.mem.eql(u8, separator, ",")) return error.InvalidSyntax;
        token = (try lexer.next()) orelse return error.ExpectedLiteral;
    }
}

// Strands stack equally shaped literals along a new leading axis.
fn isValue(value: Instruction) bool {
    return value == .literal or value == .variable or value == .expression or value == .aggregate;
}

fn foldValue(a: std.mem.Allocator, value: Instruction) anyerror!Instruction {
    const constant = switch (value) {
        .literal => return value,
        .expression => |e| for (e.arguments) |arg| {
            if (arg != .literal) break false;
        } else true,
        .aggregate => |e| for (e.items) |arg| {
            if (arg != .literal) break false;
        } else true,
        else => false,
    };
    return if (constant) .{ .literal = try @import("runtime.zig").evaluateConstant(a, .{ .scope = .{ .arity = 1, .instructions = try a.dupe(Instruction, &.{value}), .default_arguments = try a.dupe(Value, &.{.{ .data = &.{0} }}) } }) } else value;
}

fn valueExpression(a: std.mem.Allocator, lexer: *Lexer, token: []const u8, names: *const std.StringHashMapUnmanaged(Instruction), minimum: u8) anyerror!?Instruction {
    var left: Instruction = blk: {
        if (std.mem.eql(u8, token, "[") or std.mem.eql(u8, token, "tup")) {
            const is_tuple = std.mem.eql(u8, token, "tup");
            if (is_tuple) {
                const open = (try lexer.next()) orelse return error.InvalidSyntax;
                if (!std.mem.eql(u8, open, "(")) return error.InvalidSyntax;
            } else {
                // Preserve the existing array pipeline syntax.
                var look = lexer.*;
                var depth: usize = 0;
                while (try look.next()) |t| {
                    if (depth == 0 and std.mem.eql(u8, t, "]")) break;
                    if (depth == 0 and std.mem.eql(u8, t, "|>")) {
                        const body = try sequence(a, lexer, "]", false, true, names);
                        if (body.len != 1) return error.InvalidSyntax;
                        break :blk if (body[0] == .scope) .{ .literal = try @import("runtime.zig").evaluateConstant(a, body[0]) } else body[0];
                    }
                    if (std.mem.eql(u8, t, "[")) depth += 1;
                    if (std.mem.eql(u8, t, "]")) depth -= 1;
                }
            }
            var items: std.ArrayList(Instruction) = .empty;
            const close = if (is_tuple) ")" else "]";
            while (true) {
                const next = (try lexer.next()) orelse return error.UnclosedArray;
                if (std.mem.eql(u8, next, close)) break;
                if (is_tuple and items.items.len > 0) {
                    if (!std.mem.eql(u8, next, ",")) return error.InvalidSyntax;
                    const child = (try lexer.next()) orelse return error.ExpectedLiteral;
                    try items.append(a, (try valueExpression(a, lexer, child, names, 0)) orelse return error.ExpectedLiteral);
                } else try items.append(a, (try valueExpression(a, lexer, next, names, 0)) orelse return error.ExpectedLiteral);
            }
            break :blk try foldValue(a, .{ .aggregate = .{ .items = try items.toOwnedSlice(a), .tuple = is_tuple } });
        }
        if (names.get(token)) |v| {
            if (!isValue(v)) return null;
            break :blk v;
        }
        break :blk .{ .literal = (try literal(a, token)) orelse return null };
    };
    while (true) {
        const offset = lexer.offset;
        const op = (try lexer.next()) orelse break;
        const adjacent = lexer.offset - op.len == offset;
        const precedence: u8 = if (std.mem.eql(u8, op, "_")) 1 else if (std.mem.eql(u8, op, "+") or std.mem.eql(u8, op, "-")) 2 else if (std.mem.eql(u8, op, "/") or std.mem.eql(u8, op, "*")) 3 else 0;
        // A signed numeric token immediately following an atom is subtraction.
        const signed = adjacent and op.len > 1 and op[0] == '-' and op[1] != '>';
        const rank: u8 = if (signed) 2 else precedence;
        if (rank == 0 or rank < minimum) {
            lexer.offset = offset;
            break;
        }
        const next = if (signed) op[1..] else (try lexer.next()) orelse return error.ExpectedLiteral;
        const right = (try valueExpression(a, lexer, next, names, rank + 1)) orelse return error.ExpectedLiteral;
        if (precedence == 1) {
            var items: std.ArrayList(Instruction) = .empty;
            try items.appendSlice(a, &.{ left, right });
            while (true) {
                const before = lexer.offset;
                const separator = try lexer.next();
                if (separator == null or !std.mem.eql(u8, separator.?, "_")) {
                    lexer.offset = before;
                    break;
                }
                const child = (try lexer.next()) orelse return error.ExpectedLiteral;
                try items.append(a, (try valueExpression(a, lexer, child, names, 2)) orelse return error.ExpectedLiteral);
            }
            left = try foldValue(a, .{ .aggregate = .{ .items = try items.toOwnedSlice(a) } });
        } else {
            const name: []const u8 = if (signed or op[0] == '-') "sub" else switch (op[0]) {
                '+' => "add",
                '*' => "mul",
                '/' => "div",
                else => unreachable,
            };
            left = try foldValue(a, .{ .expression = .{ .arguments = try a.dupe(Instruction, &.{ left, right }), .body = try a.dupe(Instruction, &.{.{ .primitive = name }}) } });
        }
    }
    return left;
}

fn strand(a: std.mem.Allocator, lexer: *Lexer, token: []const u8, names: *const std.StringHashMapUnmanaged(Instruction)) anyerror!?Value {
    const value = (try valueExpression(a, lexer, token, names, 0)) orelse return null;
    return if (value == .literal) value.literal else null;
}

fn namedLiteral(a: std.mem.Allocator, token: []const u8, names: *const std.StringHashMapUnmanaged(Instruction)) !?Value {
    if (names.get(token)) |definition| {
        if (definition == .literal) return definition.literal;
        return null;
    }
    return literal(a, token);
}

fn literal(a: std.mem.Allocator, token: []const u8) !?Value {
    if (std.mem.eql(u8, token, "inf") or std.mem.eql(u8, token, "-inf"))
        return .{ .data = try a.dupe(f64, &.{if (token[0] == '-') -std.math.inf(f64) else std.math.inf(f64)}), .shape = &.{} };
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

fn shadowed() error{ShadowedNamesNotAllowed} {
    std.debug.print("shadowed names not allowed\n", .{});
    return error.ShadowedNamesNotAllowed;
}

fn parsePattern(a: std.mem.Allocator, lexer: *Lexer, names: *std.StringHashMapUnmanaged(Instruction)) anyerror!Pattern {
    const token = (try lexer.next()) orelse return error.InvalidSyntax;
    if (std.mem.eql(u8, token, "[")) {
        var items: std.ArrayList(Pattern) = .empty;
        while (true) {
            const offset = lexer.offset;
            const next = (try lexer.next()) orelse return error.InvalidSyntax;
            if (std.mem.eql(u8, next, "]")) break;
            lexer.offset = offset;
            try items.append(a, try parsePattern(a, lexer, names));
        }
        return .{ .items = try items.toOwnedSlice(a) };
    }
    if (!validName(token) or std.mem.eql(u8, token, "F") or std.mem.eql(u8, token, "G")) return error.InvalidFunctionName;
    if (names.contains(token) or @import("primitives.zig").known(token) or
        std.mem.eql(u8, token, "rsub") or std.mem.eql(u8, token, "sum") or std.mem.eql(u8, token, "total") or
        std.mem.eql(u8, token, "split") or std.mem.eql(u8, token, "Pairwise") or
        std.mem.eql(u8, token, "combinations") or std.mem.eql(u8, token, "tup")) return shadowed();
    try names.put(a, token, .{ .variable = token });
    return .{ .name = token };
}

fn lambdaParameters(a: std.mem.Allocator, lexer: *Lexer, names: *std.StringHashMapUnmanaged(Instruction)) ![]const Pattern {
    var look = lexer.*;
    var found = false;
    while (try look.next()) |token| {
        if (std.mem.eql(u8, token, "->")) {
            found = true;
            break;
        }
        if (!validName(token) and !std.mem.eql(u8, token, "[") and !std.mem.eql(u8, token, "]") and !std.mem.eql(u8, token, ",")) break;
    }
    if (!found) return &.{};
    var parameters: std.ArrayList(Pattern) = .empty;
    while (true) {
        try parameters.append(a, try parsePattern(a, lexer, names));
        const separator = (try lexer.next()) orelse return error.InvalidSyntax;
        if (std.mem.eql(u8, separator, "->")) break;
        if (!std.mem.eql(u8, separator, ",")) return error.InvalidSyntax;
    }
    return parameters.toOwnedSlice(a);
}
