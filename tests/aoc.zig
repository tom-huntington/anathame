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
        \\part1 =\ mod,100 count,0
        \\part2 =\ sub,1 |s {(div,100 floor Pairwise sub abs sum) |psi add} |b div,2
        \\ \ not_eq,@\n |sig Partition (pop |phi Cases [@L_-1 @R_1] parse mul) |b prepend,50 Scan add part1 ** part2
    , null, @src());
}
