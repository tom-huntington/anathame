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
    const example =
        \\$ 987654321111111
        \\$ 811111111111119
        \\$ 234234234234278
        \\$ 818181911112111
    ;
    //_ = example;
    //const input = @embedFile("d3input.txt");
    try expected_result(example,
        \\ part1 =\ digits2d reverse combinations radix,10 Reduce max sum
        \\ fn =\\ remaining, numb  -> remaining |> drop,-numb Reduce max ~> |sig indexin add,1 |sig drop
        \\ part2 =\ digits2d Each.vec \ ({Flip Mapaccum {fn reverse} },reverse(iota(12)) ) reverse radix,10
        \\ \ part1 ** (part2 sum)
    , "[357 3121910778619]", @src());
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
    const example =
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
    ;
    //_ = example;
    //const input = @embedFile("day5input.txt");
    try expected_result(example,
        \\ part1 =\ split.first,"\n\n" |phi (ints reshape,[inf 2] ) ints Table Flip in.closed \ transpose Reduce or sum
        \\ part2 =\ split.first,"\n\n" first ints reshape,[inf 2] sort.vec MapAccum,0 {m, [a b] -> a m |> max rsub,b+1 max,0  } {m, [a b] -> b m |> add,1 |delta max } sum
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
        \\ part1 =\\ Scan.exclusive.vec Step or |n mul
        \\ part2 =\\ Fold.vec Step add
        \\ \ split,@\n stride.vec,2 not_eq,@. \ uncons.vec Unc Flip \\ part1 ** part2 total
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
    //_ = example;
    //const input_env = .{ @embedFile("d8input.txt"), "1000" };
    const input_env = .{ example, "10" };
    const environment = @import("anathame").environment;
    const allocator = @import("std").testing.allocator;
    try environment.set(allocator, "num_closest", input_env.@"1");
    defer environment.remove(allocator, "num_closest") catch unreachable;

    // if (true) return error.SkipZigTest;
    try expected_result(input_env.@"0",
        \\ all_edges =\ length iota combinations
        \\ num_closest = "num_closest" |> env
        \\ part1 =\ ints2d \ all_edges |sig select Reduce.r3 distance rise take,num_closest |phi all_edges Flip select adjacency_matrix \ transpose |s or \ shape eye |s or \ Fix mul.mat.or.and deduplicate.vec sum sort take,-3 Reduce mul
        \\ part2 =\ ints2d \ Join Table quadrance (Fix mul.mat.min.max flatten Reduce max |sig indexin.mat) |sig select first Unc mul
        \\ \ part1 ** part2
    , "[40 25272]", @src());
}

test "day 9" {
    const example =
        \\$ 7,1
        \\$ 11,1
        \\$ 11,7
        \\$ 9,7
        \\$ 9,5
        \\$ 2,5
        \\$ 2,3
        \\$ 7,3
    ;
    try expected_result(example,
        \\ area =\ Unc.vec {sub abs} add,1 Unc mul
        \\ part1 =\ ints2d combinations.vec area Reduce max
        \\ proj =\ area negate
        \\ normalize =\ UnDer transpose sort
        \\ optimize =\ Sort.by proj
        \\ part2 =\ ints2d \ first.vec |sig join \ Pairwise couple optimize normalize |phi (combinations.vec optimize normalize) \\ green ->\ Find.mat ([[p q] [r s]] -> green |> MapFold.mat and (([[x y] [u v]] -> p<u && q<v && r>x && s>y ) not)  ) area
        \\ \ part1 ** part2
    , "[50 24]", @src());
}

// incidence matrix
// Characteristic vector or indicator vector

test "day 10" {
    //if (true) return error.SkipZigTest;

    const example =
        \\$ [.##.] (3) (1,3) (2) (2,3) (0,2) (0,1) {3,5,4,7}
        \\$ [...#.] (0,2,3,4) (2,3) (0,4) (0,1,2) (1,2,3,4) {7,5,12,7,2}
        \\$ [.###.#] (0,1,2,3,4) (0,3,4) (0,1,2,4,5) (1,2) {10,11,11,5,10,5}
    ;
    const input = example;
    //_ = example;
    //const input = @embedFile("d10input.txt");
    try expected_result(input, //example,
        \\ p1 =\ eq,@# drop,1 drop,-1
        \\ compute =\ split,@ Unc \p1`diagram -> \ drop,-1 Each.fill,0 (ints unwhere) \ incidences -> [0 1] length(incidences) |> cartesian_pow Sort.by sum \ Find.vec (mul.mat,incidences mod,2 eq,diagram all) sum
        \\ part1 = \ split,@\n Each compute sum
        \\ p2 =\ ints
        \\ patterns = \\ b, A_ -> [0 1] length(A_) |> cartesian_pow Filter.vec (mul.mat,A_ \ {less_eq},b all |phi (sub,b mod,2 eq,0 all) and )
        \\ candidates = \\ state, matrix -> state |> patterns,matrix mul.mat,matrix state^sub div,2
        \\ compute2 =\ split,@ drop,1 Uny Flip \p2`joltages -> \ Each.fill,0 (ints unwhere) \ A -> joltages |> Recurse (eq,0 all index,[null 0]) (candidates,A) { (patterns,A Rows sum) |d2 mul,2 add Reduce min }
        \\ part2 =\ split,@\n Each compute2 sum
        \\ \ part1 ** part2
    , "[7 33]", @src());
}

test "day 11" {
    if (true) return error.SkipZigTest;

    const example =
        \\$ aaa: you hhh
        \\$ you: bbb ccc
        \\$ bbb: ddd eee
        \\$ ccc: ddd eee fff
        \\$ ddd: ggg
        \\$ eee: out
        \\$ fff: out
        \\$ ggg: out
        \\$ hhh: ccc fff iii
        \\$ iii: out
    ;
    try expected_result(example,
        \\ part1 =\ length
        \\ \ part1
    , null // "539"
        , @src());
}

test "2022 day 13" {
    const example =
        \\$ [1,1,3,1,1]
        \\$ [1,1,5,1,1]
        \\$ 
        \\$ [[1],[2,3,4]]
        \\$ [[1],4]
        \\$ 
        \\$ [9]
        \\$ [[8,7,6]]
        \\$ 
        \\$ [[4,4],4,4]
        \\$ [[4,4],4,4,4]
        \\$ 
        \\$ [7,7,7,7]
        \\$ [7,7,7]
        \\$ 
        \\$ []
        \\$ [3]
        \\$ 
        \\$ [[[]]]
        \\$ [[]]
        \\$ 
        \\$ [1,[2,[3,[4,[5,6,7]]]],8,9]
        \\$ [1,[2,[3,[4,[5,6,0]]]],8,9]
    ;
    try expected_result(example,
        \\ \ Split,"\n\n" (Split,@\n literal_eval.pad,0 Unc compare) eq,1 \ length iota add,1 |s mul sum
    , "13", @src());
}
