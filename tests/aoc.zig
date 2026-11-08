const expected_result = @import("helpers.zig").expected_result;

test "day 1" {
    try expected_result(
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
        \\ \ not_eq,@\n |sig Partition (uncons |phi Cases [@L_-1 @R_1] parse mul) |b prepend,50 Partials add part1 ** part2
    , "[3 6]", @src());
}

test "day 2" {
    try expected_result(
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
    try expected_result(
        \\$ 987654321111111
        \\$ 811111111111119
        \\$ 234234234234278
        \\$ 818181911112111
    ,
        \\ \ digits2d reverse combinations radix,10 Reduce max sum
    , "357", @src());
}

test "day 4" {
    try expected_result(
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
    try expected_result(
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
        \\ part1 =\ split.first,"\n\n" |phi (ints reshape,[inf 2] ) ints Table Flip in.closed \ transpose Reduce or sum
        \\ part2 =\ split.first,"\n\n" first ints reshape,[inf 2] sort.rows MapAccum,0 {[a b], m -> a m |> max rsub,b+1 max,0  } { second add,1 |delta max } sum
        \\ \ part1 ** part2
    , "[3 14]", @src());
}

test "day 6" {
    try expected_result(
        \\$ 123 328  51 64 
        \\$  45 64  387 23 
        \\$   6 98  215 314
        \\$ *   +   *   +  
    ,
        \\ parseops =\ (split,@\n last.row \ not_eq,@ |sig Partition eq,@* flatten )
        \\ parsep1 =\ ints2d transpose
        \\ parsep2 =\ split,@\n transpose \ eq,32 Reduce and not |sig Partition id \ ints squeeze
        \\ \ parsep1**parsep2 |phi parseops Switch (Reduce mul) (Reduce add) sum
    , "[4277556 3263827]", @src());
}

test "day 7" {
    try expected_result(
        \\$ .......S.......
        \\$ ...............
        \\$ .......^.......
        \\$ ...............
        \\$ ......^.^......
        \\$ ...............
        \\$ .....^.^.^.....
        \\$ ...............
        \\$ ....^.^...^....
        \\$ ...............
        \\$ ...^.^...^.^...
        \\$ ...............
        \\$ ..^...^.....^..
        \\$ ...............
        \\$ .^.^.^.^.^...^.
        \\$ ...............
    ,
        \\ Step =\\ mul convolve.same,[1 0 1] |phi1 { not |d mul } F
        \\ part1 =\\ Scan.exclusive.rows Step or |n mul
        \\ part2 =\\ Fold.rows Step add 
        \\ \ split,@\n stride.rows,2 not_eq,@. \ uncons.rows Unc Flip \\ part1 ** part2 total
    , "[21 40]", @src());
}

test "day 8" {
    const example =
        \\$ 162,817,812
        \\$ 57,618,57
        \\$ 906,360,560
        \\$ 592,479,940
        \\$ 352,342,300
        \\$ 466,668,158
        \\$ 542,29,236
        \\$ 431,825,988
        \\$ 739,650,466
        \\$ 52,470,668
        \\$ 216,146,977
        \\$ 819,987,18
        \\$ 117,168,530
        \\$ 805,96,715
        \\$ 346,949,466
        \\$ 970,615,88
        \\$ 941,993,340
        \\$ 862,61,35
        \\$ 984,92,344
        \\$ 425,690,689        
    ;
    const d8input = @embedFile("d8input.txt");
    _ = example;
    try expected_result(d8input,
        \\ all_edges =\ length iota combinations
        \\ \ ints2d \ all_edges |sig select Reduce.r3 distance rise take,1000 |phi all_edges Flip select adjacency_matrix \ transpose |s or \ shape eye |s or \ Fix.check mul.mat.or.and deduplicate.rows sum sort take,-3 Reduce mul
    , null, @src());
}
