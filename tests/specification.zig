const expect_output = @import("helpers.zig").expect_output;
const invalid_syntax = @import("helpers.zig").invalid_syntax;

test "N combinator" {
    try invalid_syntax("mul couple"); // scope arity must be declared
    try expect_output("\\\\ mul couple", "2 3", "[6, 2]"); // double backslash \\ starts new dyadic scope that closes only when the current scope ends
    try expect_output("{ mul couple }", "2 3", "[6, 2]"); // curley braces denote dyadic scope
}

test "S combinator" {
    try expect_output("\\ sq couple", "2", "[4, 2]"); // backslash \ starts new monadic scope
    try expect_output("( sq couple )", "2", "[4, 2]"); // parentheses denote monadic scope
}

test "character" {
    try expect_output("\\ id", "@a", "97");
}

test "strings" {
    try expect_output("\\ id",
        \\"ab"
    , "[97,98]");

    try expect_output("\\ not_eq,@a",
        \\"abac"
    , "[0,1,0,1]");
}

test "Partial application" {
    try expect_output("\\ mul,2", "3", "6");
    try expect_output("\\ sub,2", "3", "1"); // partial application binds second argument
}

test "reverse function application" {
    try expect_output(
        \\ 2 3 |> \ mul couple
    , null, "[6,2]");

    // when we have |> at top level it specifies default arguments
    try expect_output(
        \\ 2 3 |> \ mul couple
    , "5 7", "[35,5]");
}
