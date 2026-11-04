const expected_unary = @import("helpers.zig").expected_unary;

test "day 1" {
    try expected_unary(
        \\$L68
        \\$L30
        \\$R48
        \\$L5
        \\$R60
        \\$L55
        \\$L1
        \\$L99
        \\$R14
        \\$L82
    ,
        \\ \ not_eq,@\n |s partition
    , null, @src());
}
