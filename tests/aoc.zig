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
        \\ \ not_eq,@\n |S Partition (pop |phi Cases [@L_-1 @R_1] parse mul) |b prepend,50 Scan add
    , null, @src());
}
