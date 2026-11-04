const run_test = @import("helpers.zig").run_test;

test "N combinator" {
    try run_test("mul couple", "2 3", "[6, 2]");
}

test "S combinator" {
    try run_test("sq couple", "2", "[4, 2]");
}

test "character" {
    try run_test("id", "@a", "97");
}

test "strings" {
    try run_test("id",
        \\"ab"
    , "[97,98]");
}

test "Partial application" {
    try run_test("mul,2", "3", "6");
}
