# Anathame

Requires Zig 0.17 and (for differential tests) Uiua on PATH.

- `zig build test`: Zig unit tests and combinator conformance tests.
- `zig build test-uiua`: generated Zig differential tests against Uiua (seed 1729, 30 cases per primitive).
- `zig build test-uiua -- 42 100`: reproduce or expand coverage with a seed and case count.
- `zig build run -- eval "{ mul }" 2 3`: evaluate a binary function.
- `zig build run -- test "{ mul |n couple }" 2 3 "[6, 2]"`: compare the result with the final expected-output argument. Success is silent; a mismatch reports `OutputMismatch`, prints the actual output, and exits with status 1.

Conformance tests live in `tests/specification.zig`. Each test calls
`try run_test(code, input, expected)`; the helper owns and frees its arena
and compares parsed output shapes and numbers. Expected arrays accept commas.

Scopes declare arity: `\` or parentheses for monadic functions, and `\\`
or braces for dyadic functions. Combinators are infix and associate left.
`{ mul |n couple }` with input `2 3` produces `[6 2]`:
`(f |n g)(x,y) = g(f(x,y),x)`. Likewise, `(sq |s couple)` with
input `2` produces `[4 2]`: `(f |s g)(x) = g(f(x),x)`.
B composes the result into the next function and can be omitted:
`{ mul |n couple |b sq }` and `{ mul |n couple sq }` both produce `[36 4]`.
`sq` squares each element.
The Psi combinator applies the preceding composition to both inputs before
combining them: `{ sq |psi add }` on `2 3` produces `13`, following
`(f |psi g)(x,y) = g(f(x),f(y))`. Its combining function must be dyadic.
Inputs contain one value for monadic scopes and two for dyadic
functions. Values can be numbers, rectangular arrays, characters (`@a`), or
quoted strings (`"ab"`). Characters are Unicode code point scalars; strings
are vectors of code points. Literals support escapes such as `\n`, `\t`,
`\\`, `\"`, and `\u{1F600}`. `id` returns its argument unchanged.
`log` prints its argument to stderr followed by a newline and returns it unchanged.
Separate input values with whitespace or semicolons outside literals.

`(re.Matches "^\d+$")` returns `1` when the input string matches and `0`
otherwise. The `re.` prefix groups regex functions, and each function binds
tightly to its right-hand pattern literal. Quoted regex patterns preserve
backslashes for the regex engine. Strings are converted from numeric Unicode
codepoints to UTF-8. Matching uses [zig-regex](https://github.com/zig-utils/zig-regex),
including backreferences such as `\1`.

`(re.Findall "(\d+)-(\d+)")` returns numeric capture rows, for example
`[11_22 95_115]` for `"11-22,95-115"`. Matches do not overlap. Without
capture groups it parses each whole match; one capture group produces a
vector, and multiple groups produce a matrix with one row per match.
No matches produces an empty array with the same column count. Nonnumeric
or empty matches/captures return `InvalidInput`.

Reverse application supplies one or two literal arguments before `|>`:
`2 3 |> \ mul |n couple` produces `[6 2]`. The supplied argument count determines
the application's arity. At the top level these are default arguments;
explicit input such as `5 7` overrides them and produces `[35 5]`.
For example, `zig build run -- eval "2 3 |> \ mul |n couple"` needs no input arguments.
Code contains function
names. Individual primitives follow Uiua argument order and array semantics;
Anathame composition intentionally differs from Uiua stack execution.

Values are immutable and results allocate fresh storage. Multiplication uses
prefix-shape scalar extension; couple requires equal shapes. The primitive
name snapshot comes from `../uiua/site/primitives.json`; recognized names
without implementations report an explicit error. Implementations register
through comptime reflection.

`src/reserved_bump_allocator.zig` vendors the reserve/commit allocator directly.
Each evaluation reserves 64 MiB of address space and commits pages as needed.
`src/memory.zig` implements `ReturnImpl`: snapshot the result, rewind the frame,
and copy back only the result. This prioritizes simple lifetime rules over
copy avoidance. No input mutation or ownership flags are used.

Higher-order functions start with capitals: `Partition id` groups positive
marker runs and applies `id` to each group. `Scan add` computes inclusive
prefix sums along the innermost dimension independently: `[[1 2 3] [4 5 6]]`
becomes `[[1 3 6] [4 9 15]]`. Scan passes the accumulator first and the next
scalar second to its binary function, which must return a scalar. Scalars
and empty arrays keep their shape.

`prepend` takes an array first and a row second, adding that row at the front.
For example, `prepend,50` maps `[1 2]` to `[50 1 2]`. For higher-rank arrays,
the row's shape must match the array's trailing dimensions.

Partial applications accept literal choices separated by `*`. A scope runs
every combination of choices on the same input and stacks the results into
a Cartesian array. The first choice varies fastest; later choices add outer
axes, followed by the result's own dimensions. For example,
`\ mul,2*3 mul,5*7` on `1` produces `[10_15 14_21]`: the four
compositions multiply by (2,5), (3,5), (2,7), and (3,7).
Each alternative may be a scalar, strand, or array literal. Branch results
must be arrays with matching shapes.

`**` separates function alternatives. Parentheses group compositions, and
alternatives expand through those groups into the enclosing composition.
Function choices run in source order, with the last choice varying fastest:
`\ (sq ** mul,3) |b (mul,5 ** mul,7)` on `2` produces
`[20_28 30_42]`. Use a scope around a multi-function alternative, such as
`(sq add,1) ** (mul,3 sub,2)`. Every branch receives the same original inputs;
its complete composition runs before the results are stacked.

`Reduce add` (alias `sum`) folds leading-axis rows from left to right;
`[[1 2] [3 4]]` becomes `[4 6]`. Its operand must be dyadic. Empty arrays
use the operand's identity for `add`, `sub`, `mul`, `div`, `min`, and `max`;
other operands report `NoReductionIdentity`.

`Stencil,3 sum` applies `sum` to overlapping windows of three leading-axis
rows. With a unary operand, `Stencil` without a bound size is dyadic and
takes the array first and window size second. Sizes currently must be positive
integer scalars; multidimensional sizes, strides, padding, and fill are not
implemented. With a dyadic operand, `Stencil sub` applies `sub` to adjacent
rows without requiring a size. `Pairwise` expands to `Stencil,2`, so
`Pairwise sub` and `Pairwise sum` both operate on adjacent pairs.

`try test_alias("sum", "Reduce add")` compares parsed instruction trees
recursively, including HOF operands and literal contents. It checks structural
equivalence rather than equality on sample inputs. `test_hof_alias` does the
same with several primitive, scoped, and nested-HOF operands appended.

Named functions are defined before the main scope with `name = body`:

```text
part1 = \ mod,100 count,0
part2 = \ sub,1 |s {(div,100 floor Pairwise sub abs sum) |psi add} |b div,2
\ prepend,50 Scan add part1 ** part2
```

Definitions end at a newline outside parentheses, braces, and arrays. Names
start with a letter and may contain letters, digits, and underscores. They
can reference earlier definitions and be used in nested scopes, alternatives,
and as higher-order operands. Primitive names cannot be redefined; duplicate
names are rejected. Recursion and forward references are not supported.
Every definition must explicitly declare its arity: use `\` or parentheses
for a monadic function, and `\\` or braces for a dyadic function. For example,
`double = \ mul,2` and `combine = { add sq }`. Bare primitive aliases and
unscoped compositions are rejected.
