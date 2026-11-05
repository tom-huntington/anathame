const test_alias = @import("helpers.zig").test_alias;
const test_hof_alias = @import("helpers.zig").test_hof_alias;
const literal_eval = @import("helpers.zig").literal_eval;
const expect_output = @import("helpers.zig").expect_output;
const invalid_syntax = @import("helpers.zig").invalid_syntax;
const expected_unary = @import("helpers.zig").expected_unary;

test "part1 regex on the to_string output" {
    // Match each row of character codes independently.
    try expected_unary("[49_49 49_50]",
        \\ \ re.Matches "^(\d+)\1$"
    , "[1 0]", @src());
}

test "Must declare arity explicitly" {
    try invalid_syntax("mul |n couple"); // scope arity must be declared
    try invalid_syntax("f = sq\n\\ f"); // named function arity must be declared
}
test "N combinator" {
    try expect_output("\\\\ mul |n couple", .{ "2", "3" }, "[6 2]"); // double backslash \\ starts new dyadic scope that closes only when the current scope ends
    try expect_output("{ mul |n couple }", .{ "2", "3" }, "[6 2]"); // curley braces denote dyadic scope

    try expect_output("\\\\ mul |n couple |b sq", .{ "2", "3" }, "[36 4]"); // combinators are infix. |x is placed after first argument
    try expect_output("\\\\ mul |n couple sq", .{ "2", "3" }, "[36 4]"); // |b combinator can be implicit
}

test "S and Sig combinators" {
    // s combinator 12.1 (f,g) = x -> g(f(x), x)
    try expect_output("\\ sq |s couple", .{"2"}, "[4 2]"); // backslash \ starts new monadic scope
    try expect_output("( sq |s couple )", .{"2"}, "[4 2]"); // parentheses denote monadic scope
    // sig combinator 12.1 (f,g) = x -> g(x, f(x))
    try expect_output("\\ sq |sig couple", .{"2"}, "[2 4]"); // backslash \ starts new monadic scope
}

test "Combinators" {
    // psi combinator 12.2 (f,g) = x, y -> g(f(x), f(y))
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
        \\$ a
        \\$ b
        \\$ c
    , "[97 10 98 10 99]");
    try literal_eval(
        \\$ "a"
    , "[34 97 34]");

    // ints finds all connected digit codepoints and evals them into integer
    try expect_output(
        \\\ ints
    , "[49 50 32 32 51 52 10 53 54 32 55 56]", "[12 34 56 78]");
    try expect_output(
        \\\ digits
    , "[49 50 32 32 51 52 10 53 54 32 55 56]", "[1 2 3 4 5 6 7 8]");
    try expect_output(
        \\\ digits2d
    , "[49 50 32 32 51 52 10 53 54 32 55 56]", "[1_2_3_4 5_6_7_8]");
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

test "Partition" {
    try expect_output(
        \\ \\ Partition id
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
        \\ \\ Partition id
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

test "builtins" {
    try expect_output("\\\\ take", .{ "[8 3 9 2 0]", "3" }, "[8 3 9]");
    try expect_output("\\\\ split_at", .{ "[1 2 3 4]", "2" }, .{ "[1 2]", "[3 4]" });
    try expect_output("\\ uncons", .{"[1 2 3 4]"}, .{ "1", "[2 3 4]" });

    try expect_output("\\ parse", .{"[49 49]"}, .{"11"});
    try expect_output("\\ parse", .{
        \\"11"
    }, .{"11"});
    try expect_output("\\ to_string", .{"11"}, .{"[49 49]"});
    try expect_output("\\ to_string", .{"[11 12]"}, "[49_49 49_50]");

    // inclusive range
    try expect_output("\\\\ range_inclusive", .{ "1", "3" }, "[1 2 3]");
}

test "Phi combinator" {
    // phi combinator 112.1 (f,g,h) = x -> h(f(x),g(x))
    try expect_output("\\ take,2 |phi drop,2 mul", .{"[1 2 3 4]"}, .{"[3 8]"});
    // if instead first argument returns 2-tuple (denoted 1²) we have
    // phi combinator 1²2.1 (f,g) = x -> g(*f(x))
    try expect_output("\\ split_at,2 |phi mul", .{"[1 2 3 4]"}, .{"[3 8]"});
    // phi combinator 1²112.1 (f,g,h,k) = x -> k(g(f(x)[0]), h(f(x)[1]))
    try expect_output("\\ split_at,2 |phi add,1 sq couple", .{"[1 2 3 4]"}, .{"[2_3 9_16]"});
}

test "Keywords" {
    // cases binds to 2D array literal on right
    try expect_output("\\ Cases [1_11 2_22 3_33]", .{"[1 2 3]"}, .{"[11 22 33]"});
}

test "Literal alternatives macro" {
    //  Cartesian array of compositions
    // * separates alternative literals for inlining.
    // Run every composition on the same input
    try expect_output("\\ mul,2*3 mul,5*7", .{"1"}, .{"[10_15 14_21]"});

    // ** does the same but with functions
    try expect_output("\\ (sq ** mul,3) |b (mul,5 ** mul,7)", .{"2"}, .{"[20_28 30_42]"});
}

test "Aliases" {
    try test_alias("sum", "Reduce add");
    try test_hof_alias("Pairwise", "Stencil,2");
}

test "Regex" {
    // regex functions bind tightly to literal on right
    try expect_output(
        \\ \ re.Matches "^(\d+)\1$"
    , .{
        \\"99"
    }, "1");
    try expect_output(
        \\ \ re.Matches "^(\d+)\1$"
    , .{
        \\"1010"
    }, "1");
    try expect_output(
        \\ \ re.Matches "^(\d+)\1$"
    , .{
        \\"101"
    }, "0");
    try expect_output(
        \\ \ re.Findall "(\d+)-(\d+)"
    , .{
        \\$ 11-22,95-115,
        \\$ 998-1012
    }, "[11_22 95_115 998_1012]");
}

test "High order functions (hofs)" {
    // Unc uncurry can handle both 2-tuple and array with outer dimension 2
    try expect_output("\\ Unc range", .{"[1 4]"}, "[1 2 3]");
    // Rows calls a function on each row
    try expect_output("\\ Rows (Unc range length)", .{"[[1 2] [3 4]]"}, "[1 1]");
    try expect_output("\\ Filter mod,2", .{"[1 2 3 4 5]"}, "[1 3 5]");
}
