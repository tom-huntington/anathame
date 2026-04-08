const std = @import("std");

const MyMap = std.StaticStringMap([]const u8).initComptime(.{
    .{ "⇶", "Cases" },
    .{ "∫", "Scan" },
    .{ "∑", "Reduce" },
    .{ "§", "\\" },
    .{ "¶", "\\\\" },
    .{ "ϴ", "Partition" },
    .{ "⊞", "Outerproduct" },
});

const a =
    \\ inner prodct ⦿sum‿mul 
    \\ No spaces between Hof and argument
    \\ dotprod
    \\ϴ()
;

// 1. Circled Operators (Similar to ⊗)
// ⊕ U+2295: Circled Plus (Direct Sum)
// ⊖ U+2296: Circled Minus
// ⊘ U+2298: Circled Division Slash
// ⊙ U+2299: Circled Dot Operator (Hadamard product)
// ⊚ U+229A: Circled Ring Operator
// ⊛ U+229B: Circled Asterisk Operator
// ⦿ U+29BF: Circled Bullet
// ⦾ U+29BE: Circled White Bullet
// ⊝ U+229D: Circled Dash

// ∗ Asterisk Operator (U+2217)
// ⁎ Low Asterisk (U+204E)
// ✳ Eight Spoked Asterisk (U+2733)
// ✴ Eight Pointed Black Star (U+2734)
// ✱ U+2731 — Heavy Asterisk
