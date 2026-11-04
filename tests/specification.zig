const expected_output21 = @import("helpers.zig").expected_output21;
const literal_eval = @import("helpers.zig").literal_eval;
const expect_output = @import("helpers.zig").expect_output;
const invalid_syntax = @import("helpers.zig").invalid_syntax;

test "N combinator" {
    try invalid_syntax("mul |n couple"); // scope arity must be declared
    try expect_output("\\\\ mul |n couple", .{ "2", "3" }, "[6 2]"); // double backslash \\ starts new dyadic scope that closes only when the current scope ends
    try expect_output("{ mul |n couple }", .{ "2", "3" }, "[6 2]"); // curley braces denote dyadic scope

    try expect_output("\\\\ mul |n couple |b sq", .{ "2", "3" }, "[36 4]"); // combinators are infix. |x is placed after first argument
    try expect_output("\\\\ mul |n couple sq", .{ "2", "3" }, "[36 4]"); // |b combinator can be implicit
}

test "S combinator" {
    try expect_output("\\ sq |s couple", .{"2"}, "[4 2]"); // backslash \ starts new monadic scope
    try expect_output("( sq |s couple )", .{"2"}, "[4 2]"); // parentheses denote monadic scope
}

test "character" {
    try expect_output("\\ id", .{"@a"}, "97");
}

test "strings" {
    try literal_eval(
        \\"ab"
    , "[97 98]");

    try expect_output("\\ not_eq,@a", .{
        \\"abac"
    }, "[0 1 0 1]");

    // multi line strings
    try literal_eval(
        \\$a
        \\$b
        \\$c
    , "[97 10 98 10 99]");
    try expect_output(
        \\\ id
    , .{
        \\$"a"
    }, "[34 97 34]");
}

test "Partial application" {
    try expect_output("\\ mul,2", .{"3"}, "6");
    try expect_output("\\ sub,2", .{"3"}, "1"); // partial application binds second argument
}

test "reverse function application" {
    try expect_output(
        \\ 2 3 |> \ mul |n couple
    , .{}, "[6 2]");

    // when we have |> at top level it specifies default arguments
    try expect_output(
        \\ 2 3 |> \ mul |n couple
    , .{ "5", "7" }, "[35 5]");
}

test "partition" {
    try expect_output(
        \\ \\ partition id
    , .{
        \\[1 2 3 4 5 6 7 8]
        ,
        \\[0 0 2 2 1 1 3 3]
    }, .{
        \\ [3_4 5_6 7_8]
    });

    // uiua has boxed arrays
    // we return a tuple representing a jagged array
    try expect_output(
        \\ \\ partition id
    , .{
        \\[1 2 3 4 5 6 7]
        ,
        \\[0 3 3 3 2 2 1]
    }, .{
        \\ [2 3 4 5 6 7]
        ,
        \\ [0 3 5 6]
    });
}

test "tuple literal" {
    try literal_eval(
        \\ tup( 1, [2 3] )
    , .{ "1", "[2 3]" });
}

test "builtins from uiua" {
    try expected_output21("\\\\ take", "[8 3 9 2 0]", "3", "[8 3 9]");
}

test "builtins" {
    try expect_output("\\\\ split_at", .{ "[1 2 3 4]", "2" }, .{ "[1 2]", "[3 4]" });
}

test "Phi combinator" {
    // phi combinator 112.1 (f,g,h) = x -> h(f(x),g(x))
    try expect_output("\\ take,2 |phi drop,2 mul", .{"[1 2 3 4]"}, .{"[3 8]"});
    // if instead first argument returns 2-tuple (denoted 1²) we have
    // phi combinator 1²2.1 (f,g) = x -> g(*f(x))
    try expect_output("\\ split_at,2 |phi mul", .{"[1 2 3 4]"}, .{"[3 8]"});
}

test "Keywords" {
    // cases binds to 2D array literal on right
    try expect_output("\\ Cases [1_11 2_22 3_33]", .{"[1 2 3]"}, .{"[11 22 33]"});
}
