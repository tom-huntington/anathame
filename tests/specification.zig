const test_alias = @import("helpers.zig").test_alias;
const test_aliases = @import("helpers.zig").test_aliases;
const value_expression = @import("helpers.zig").value_expression;
const expect_output = @import("helpers.zig").expect_output;
const invalid_syntax = @import("helpers.zig").invalid_syntax;
const expected_result = @import("helpers.zig").expected_result;

test "part1 regex on the to_string output" {
    // Match each row of character codes independently.
    try expected_result("[49_49 49_50]",
        \\ \ re.Matches "^(\d+)\1$"
    , "[1 0]", @src());
}

test "N and Nu combinator" {
    // n combinator 22.2 (f,g) = x, y -> g(x, f(x,y))
    // nu combinator 22.2 (f,g) = x, y -> g(f(x,y), y)
    try expect_output("\\\\ mul |n couple", .{ "2", "3" }, "[2 6]"); // double backslash \\ starts new dyadic scope that closes only when the current scope ends
    try expect_output("{ mul |n couple }", .{ "2", "3" }, "[2 6]"); // curley braces denote dyadic scope

    try expect_output("\\\\ mul |n couple |b sq", .{ "2", "3" }, "[4 36]"); // combinators are infix. |x is placed after first argument
    try expect_output("\\\\ mul |n couple sq", .{ "2", "3" }, "[4 36]"); // |b combinator can be implicit
}

test "S and Sig combinators" {
    // s combinator 12.1 (f,g) = x -> g(f(x), x)
    try expect_output("\\ sq |s couple", .{"2"}, "[4 2]"); // backslash \ starts new monadic scope
    try expect_output("( sq |s couple )", .{"2"}, "[4 2]"); // parentheses denote monadic scope

    // sig combinator 12.1 (f,g) = x -> g(x, f(x))
    try expect_output("\\ sq |sig couple", .{"2"}, "[2 4]"); // backslash \ starts new monadic scope
}

test "Phi combinator" {
    // phi combinator 112.1 (f,g,h) = x -> h(f(x),g(x))
    try expect_output("\\ take,2 |phi drop,2 mul", .{"[1 2 3 4]"}, .{"[3 8]"});
    // if instead first argument returns 2-tuple (denoted 1²) we have
    // phi combinator 1²2.1 (f,g) = x -> g(*f(x))
    try expect_output("\\ id |phi mul", .{"tup([1 2], [3 4])"}, .{"[3 8]"});
    // phi combinator 1²112.1 (f,g,h,k) = x -> k(g(f(x)[0]), h(f(x)[1]))
    try expect_output("\\ id |phi add,1 sq couple", .{"tup([1 2], [3 4])"}, .{"[2_3 9_16]"});
}

test "Combinators" {
    try expect_output("\\ Join mul", .{"3"}, "9");
    try expect_output("\\ sq Join mul", .{"3"}, "81");
    // delta combinator 12.2 (f,g) = x,y -> g(f(x), y)
    // d combinator 12.2 (f,g) = x,y -> g(x, f(y))
    // psi combinator 12.2 (f,g) = x,y -> g(f(x), f(y))
    // d2 combinator 112.2 (f,g,h) = x,y -> h(f(x), g(y))
    // phi1 combinator 222.2 (f,g,h) = x,y -> h(f(x,y), g(x,y))
}

test "invalid syntax" {
    if (true) return error.SkipZigTest;
    try invalid_syntax("\\ mul");
    try invalid_syntax("\\ sq mul");
    try invalid_syntax("\\ Sort.by mul");
    try invalid_syntax("f =\\\\ Unc mul\n\\ Sort.by f");
    try invalid_syntax("\\\\ mul |s mul"); // the scope is declared dyadic by s produces a monad
    try invalid_syntax("mul |n couple"); // scope arity must be declared
    try invalid_syntax("f = sq\n\\ f"); // named function arity must be declared
}

test "character" {
    try value_expression("@a", "97");
    try value_expression("@ ", "32");
}

test "strings" {
    try value_expression(
        \\"ab"
    , "[97 98]");

    try expect_output("\\ not_eq,@a", .{
        \\"abac"
    }, "[0 1 0 1]");

    // multi line strings
    try value_expression(
        \\$ a
        \\$ b
        \\$ c
    , "[97 10 98 10 99]");
    try value_expression(
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
    try expect_output("\\ mul,2*5", .{"3"}, "30");
    try expect_output("\\ sub,2", .{"3"}, "1"); // partial application binds second argument
}

test "function application" {
    try value_expression("sq(2)", "4");

    try value_expression(
        \\ 2 3 |> mul |n couple
    , "[2 6]");

    // :> supplies defaults to an explicit function scope
    try expect_output(
        \\ 2 3 :> { mul |n couple }
    , .{ "5", "7" }, "[5 35]");
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
    try value_expression(
        \\ tup( 1, [2 3] )
    , .{ "1", "[2 3]" });
}

test "dyadic pervasives broadcast over trailing axes" {
    try expect_output("\\\\ add", .{ "[1_2_3 4_5_6]", "[10 20 30]" }, "[11_22_33 14_25_36]");
    try expect_output("\\\\ sub", .{ "[10 20 30]", "[1_2_3 4_5_6]" }, "[9_18_27 6_15_24]");
    // Equal leading and trailing dimensions must still use the trailing axis.
    try expect_output("\\\\ mul", .{ "[1_2 3_4]", "[10 20]" }, "[10_40 30_80]");
    try expect_output("\\\\ less", .{ "[1_2_3 4_5_6]", "[3 5 4]" }, "[1_1_1 0_0_0]");
    try expect_output("\\\\ add", .{ "[1_2_3 4_5_6]", "10" }, "[11_12_13 14_15_16]");
    try expect_output("\\\\ sub", .{ "10", "[1_2_3 4_5_6]" }, "[9_8_7 6_5_4]");
}

test "builtins" {
    try expect_output("\\\\ take", .{ "[8 3 9 2 0]", "3" }, "[8 3 9]");
    try expect_output("\\\\ split", .{ "[1 2 3 4 5 3 6 7]", "3" }, "[1_2 4_5 6_7]");
    try expect_output("\\ uncons", .{"[1 2 3 4]"}, .{ "1", "[2 3 4]" });

    try expect_output("\\ parse", .{"[49 49]"}, .{"11"});
    try expect_output("\\ parse", .{
        \\"11"
    }, .{"11"});
    try expect_output("\\ to_string", .{"11"}, .{"[49 49]"});
    try expect_output("\\ to_string", .{"[11 12]"}, "[49_49 49_50]");

    // inclusive range
    try expect_output("\\\\ range_inclusive", .{ "1", "3" }, "[1 2 3]");
    try expect_output("\\\\ in.closed", .{ "[0 1 2 3 4 5]", "[1 3]" }, "[0 1 1 1 0 0]");

    try expect_output("\\ stride,2", "[1 2 3 4 5 6]", "[1 3 5]");
    try expect_output("\\ stride.vec,2", "[1_2 3_4 5_6]", "[1_2 5_6]");

    try expect_output("\\\\ distance", .{ "[3 4]", "[0 0]" }, "5"); // trailing axis convention
    try expect_output("\\ unwhere", "[3_4 2_1 0_3]", "[0_0_0_1_0 0_0_0_0_0 0_1_0_0_0 0_0_0_0_1]");
}

test "Keywords" {
    // cases binds to 2D array literal on right
    try expect_output("\\ Cases [1_11 2_22 3_33]", .{"[1 2 3]"}, .{"[11 22 33]"});
}

test "Literal alternatives macro" {
    //  Cartesian array of compositions
    // *** separates alternative literals for inlining.
    // Run every composition on the same input
    try expect_output("\\ mul,2***3 mul,5***7", .{"1"}, .{"[10_15 14_21]"});

    // ** does the same but with functions
    try expect_output("\\ (sq ** mul,3) |b (mul,5 ** mul,7)", .{"2"}, .{"[20_28 30_42]"});
}

test "Aliases" {
    try test_alias("sum", "Fold,0 add");
    try test_alias("Pairwise add", "Stencil,2 add");
    // partial application to hof is done to hof result
    try test_alias("Stencil,2 add", "{Stencil add},2");
    try test_alias("total", "(flatten sum)");
    try test_alias("rsub", "{Flip sub}");
    try test_alias("Sort.by Unc mul", "(Unc mul rise |sig select)");
    try expect_output("\\ Sort.by Unc mul", .{"[1_5 1_3 1_2]"}, .{"[1_2 1_3 1_5]"});
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
    try test_alias("Filter mod,2", "(mod,2 |sig keep)"); // mod,2 is place holder for any predicate
    // Uiua is leading access conventions. We mostly prefer trailing axis conventions
    try expect_output("\\ Reduce mul", "[2_3_5_7 3_5_7_11]", "[210 1155]");

    // repeat with accepts 1 monadic argument or 2 dyadic arguments
    try expect_output(
        \\\\ Repeat sq
    , .{ "2", "3" }, "256");
    try expect_output(
        \\\ Repeat,3 sq
    , "2", "256");

    // our tacit composition model doesn't have triadic functions. So repeat must be partially applied
    try expect_output(
        \\\\ Repeat,2 mul sub
    , .{ "2", "3" }, "[-6 7]");

    try expect_output(
        \\\\ MapAccum couple mul
    , .{ "[2 3 5]", "7" }, "[7_2 14_3 42_5]");

    try expect_output("\\\\ sub", .{ "1", "2" }, "-1");
    try expect_output("\\\\ Flip sub", .{ "1", "2" }, "1");
    try expect_output("\\ Join mul", "2", "4");

    try expect_output("\\\\ Switch sq add,1", .{ "[1 2 3]", "[1 0 1]" }, "[1 3 9]");

    try expect_output("\\\\ Scan.exclusive add", .{ "[1 2 3 4]", "0" }, "[0 1 3 6]");
}

test "tuples" {
    try expect_output("\\\\ TuplesWith less couple", .{ "[0 1 2 3]", "2" }, "[0_1 0_2 0_3 1_2 1_3 2_3]");
    try expect_output("\\\\ TuplesWith less couple", .{ "[0_1_2_3 4_5_6_7]", "2" }, "[[0_1 0_2 0_3 1_2 1_3 2_3] [4_5 4_6 4_7 5_6 5_7 6_7]]"); // trailing axis convention
    try test_aliases(&.{ "combinations", "Tuples,2 less", "TuplesWith,2 less couple", "{TuplesWith less couple},2" });
    try test_aliases(&.{ "combinations.vec", "Tuples.vec,2 less" });
}

test "fill and full" {
    // same as uiua reshape
    try expect_output("\\\\ fill", .{ "[2 2]", "0" }, "[0_0 0_0]");
    try value_expression("[2 2] 0 |> fill", "[0_0 0_0]");
    try expect_output("\\\\ fill", .{ "0", "[2 2]" }, "[0_0 0_0]");
    try value_expression("0 [2 2] |> full", "[0_0 0_0]"); // arguments reversed
}

test "lambdas" {
    try expect_output("{[a b], c -> a c |> couple tuple,b }", .{ "[1 2]", "3" }, .{ "[1 3]", "2" });
    try expect_output("\\\\[a b], c -> a c |> couple tuple,b ", .{ "[1 2]", "3" }, .{ "[1 3]", "2" });
    try expect_output("([a b] -> b a |> couple )", "[2 1]", "[1 2]");
    try expect_output("([a b] -> b*5 a |> couple )", "[2 3]", "[15 2]");
    try expect_output("([a b] -> a |> sq mul,b*5 )", "[2 3]", "60");
    try expect_output(
        \\  \\ a -> \ id
    , .{ "2", "3" }, "3");
    try expect_output(
        \\ {Flip \\ b -> \ id}
    , .{ "2", "3" }, "2");
    try expect_output(
        \\ \[diagram *buttons joltage] -> diagram joltage |> couple
    , "[1 2 3 4]", "[1 4]");
}

test "explicit axis" {
    // Component selectors
    // operation.type.axis
    // the type and axis is a mirage. the are merely component shape
    // storage shape = mdarray shape ++ component shape
    // dim type + dim axis = dim component
    // scalar types: c complex shape [2]. future possibilities q quaternions shape [4]
    // r2 is length 2 vectors of reals; shape [2]. c3 is length 3 vectors of complex; shape [3 2]. c22 is a 2x2 matrix of complex; shape [2 2]
    // vec is vector of reals; rank 1. c.vec vector of complex shape [n 2]. q.vec is a vector of quaternions (unimplemented); shape [n 4]. mat is a matrix of reals; rank 2. mat matrix of complex; shape [n m 2]
    // for rank N, block is a component of rank N-1 (vector of blocks). for rank N, cell is a compoent of rank N-2 (matrix of cells)

    try expect_output("\\ uncons.vec", "[1_2 3_4 5_6]", .{ "[1 2]", "[3_4 5_6]" });

    try expect_output("\\ uncons.c", "[1_2 3_4 5_6]", .{ "[1 2]", "[3_4 5_6]" }); // 1 scalar dimension
    try expect_output("\\ uncons.c.vec", "[[1_2 3_4] [5_6 7_8]]", .{ "[1_2 3_4]", "[[5_6 7_8]]" });
    try expect_output("\\ uncons.block", "[[1_2 3_4] [5_6 7_8]]", .{ "[1_2 3_4]", "[[5_6 7_8]]" });
    try expect_output("\\ uncons.c", "[[1_2 3_4 9_9] [5_6 7_8 0_0]]", .{ "[1_2 5_6]", "[[3_4 9_9] [7_8 0_0]]" });

    try expect_output("\\ Reduce.vec add", "[1_2_3 4_5_6]", "[5 7 9]");
    try expect_output("\\ Reduce.c add", "[1_2 3_4]", "[4 6]");
    try expect_output("\\ Reduce.c.vec add", "[[1_2 3_4] [1_2 3_4]]", "[2_4 6_8]");
    try expect_output("\\ Reduce add", "[1_2_3 4_5_6]", "[6 15]");

    try expect_output("\\ Partials.vec add", "[1_2_3 4_5_6]", "[1_2_3 5_7_9]");
    try expect_output("\\\\ Scan.vec add", .{ "[1_2_3 4_5_6]", "[1 1 1]" }, "[1_1_1 2_3_4 6_8_10]");
    try expect_output("\\\\ Fold.vec add", .{ "[1_2_3 4_5_6]", "[1 1 1]" }, "[6 8 10]");
    try expect_output("\\\\ indexin.vec", .{ "[1 2 3]", "3" }, "2");
    try expect_output("\\\\ indexin", .{ "[1 2 3]", "2" }, "1"); // rows is the default axis
    try expect_output("\\\\ indexin.mat", .{ "[1_2_3 4_5_6]", "2" }, "[1 0]");
}

test "types" {
    try expect_output("\\\\ mul.c", .{ "[0 1]", "[1 1]" }, "[-1 1]");
    //try expect_output("\\ mul.c.mat", .{ "[[2_1 1_-2] [0_3 -1_1]]", "[1_1 2_-1]" }, "[1_-2 -4_6]");
    try expect_output("\\\\ mul.mat", .{ "[2_3 4_-1]", "[5 2]" }, "[16 18]"); // mat vec mul
    try expect_output("\\\\ mul.mat", .{ "[2_3 4_-1]", "[5_2 3_4]" }, "[19_16 17_4]"); // mat mat mul
    // only for real
    // mul.mat.or.and Reachability, transitive closure
    // mul.mat.min.add Shortest paths
    // mul.mat.max.add Longest paths, scheduling
    // mul.mat.min.max Minimax paths
    // mul.mat.max.min Maximum-capacity paths
    // mul.mat.add.mul Counting walks same as mul.mat
}

test "syntax" {
    // default arguments
    try expect_output(
        \\ 1 2 :>
        \\ \\ couple
    , .{ "3", "4" }, "[3 4]");
    try expect_output(
        \\ 1 2 :>
        \\ \\ couple
    , .{"3"}, "[3 2]");
    try expect_output(
        \\ 1 2 :>
        \\ \\ couple
    , .{}, "[1 2]");

    // yeild macro
    try expect_output(
        \\ \ add,1 ~> |s couple
    , "1", .{ "2", "[2 1]" });

    try expect_output(
        \\ \ add,1 ~> |s couple |s mul
    , "2", .{ "3", "[6 4]" });

    try expect_output(
        \\ \ add,1 ~> |sig couple
    , "1", .{ "2", "[1 2]" });
    try expect_output(
        \\ \\ mul ~> |phi1 sub couple
    , .{ "2", "3" }, .{ "6", "[6 -1]" });
}
