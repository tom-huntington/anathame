const expected_unary = @import("helpers.zig").expected_unary;

test "day 1" {
    try expected_unary(
        \\$ L68
        \\$ L30
        \\$ R48
        \\$ L5
        \\$ R60
        \\$ L55
        \\$ L1
        \\$ L99
        \\$ R14
        \\$ L82
    ,
        \\part1 =\ mod,100 count,0
        \\part2 =\ sub,1 |s {div,100 floor Pairwise sub abs sum |psi add} |b div,2
        \\ \ not_eq,@\n |sig Partition (uncons |phi Cases [@L_-1 @R_1] parse mul) |b prepend,50 Scan add part1 ** part2
    , "[3 6]", @src());
}

test "day 2" {
    try expected_unary(
        \\$ 11-22,95-115,998-1012,1188511880-1188511890,222220-222224,
        \\$ 1698522-1698528,446443-446449,38593856-38593862,565653-565659,
        \\$ 824824821-824824827,2121212118-2121212124
    ,
        \\part1 =\ Rows (to_string re.Matches "^(\d+)\1$")
        \\part2 =\ Rows (to_string re.Matches "^(\d+)\1+$")
        \\ \ not_eq,@, |sig Partition ints |b Rows (Unc range_inclusive Filter part1**part2 sum) sum
    , "[1227775554 4174379265]", @src());
}

test "day 3" {
    try expected_unary(
        \\$ 987654321111111
        \\$ 811111111111119
        \\$ 234234234234278
        \\$ 818181911112111
    ,
        \\ \ digits2d reverse combinations radix,10 Reduce max sum
    , "357", @src());
}

test "day 4" {
    try expected_unary(
        \\$ ..@@.@@@@.
        \\$ @@@.@.@.@@
        \\$ @@@@@.@.@@
        \\$ @.@@@@..@.
        \\$ @@.@@@@.@@
        \\$ .@@@@@@@.@
        \\$ .@.@.@.@@@
        \\$ @.@@@.@@@@
        \\$ .@@@@@@@@.
        \\$ @.@.@@@.@.
    ,
        \\ part1 =\ convolve.same,[[3 3] 1 |> fill] greater,4 |s and
        \\ part2 =\ Fix part1
        \\ \ split,@\n eq,@@ \ part1**part2 |sig sub \ flatten sum
    , "[13 43]", @src());
}

test "day 5" {
    try expected_unary(
        \\$ 3-5
        \\$ 10-14
        \\$ 16-20
        \\$ 12-18
        \\$ 
        \\$ 1
        \\$ 5
        \\$ 8
        \\$ 11
        \\$ 17
        \\$ 32
    ,
        \\ \ tuple.blankline |phi (ints reshape,[inf 2] ) ints Table Flip in.closed total
    , null, @src());
}
