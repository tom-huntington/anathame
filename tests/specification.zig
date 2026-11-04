const run_test = @import("helpers.zig").run_test;

test "N combinator" {
    try run_test("mul couple", "2 3", "[6, 2]");
}

test "S combinator" {
    try run_test("sq couple", "2", "[4, 2]");
}
