# Anathame

Requires Zig 0.17 and (for differential tests) Uiua on PATH.

`tuple.blankline` splits a Unicode character vector at the first blank line
(`\n\n` or `\r\n\r\n`) into a tuple of two character vectors, removing the
separator. Later blank lines are preserved. Without a blank line, the tuple
contains the original vector and an empty vector.

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
`convolve.same`, `convolve.valid`, and `convolve.full` take the input first
and a nonempty 1D or 2D kernel second. They perform convolution (flipping
the kernel) on the trailing kernel-rank axes, independently for each leading
slice. The input must have at least as many axes as the kernel.
`same` preserves the input shape; `valid` includes only complete overlaps
(an axis is empty if the kernel is larger); `full` includes all partial
overlaps with zero padding. Empty input axes remain empty in all modes.
`same` crops the full result starting at floor((kernel size - 1) / 2) per axis.
For example, `{ convolve.full }` on `[1 2 3]` and `[1 2]` gives `[1 4 7 6]`.
`reverse` reverses the trailing axis: `[1_2_3 4_5_6]` becomes
`[3_2_1 6_5_4]`. Scalars and empty arrays are unchanged.
`stride,2` keeps every second element along the trailing axis, starting with
the first: `[1 2 3 4 5 6]` becomes `[1 3 5]`. `stride.rows,2` does the
same along axis -2 in each outer cell: `[1_2 3_4 5_6]` becomes `[1_2 5_6]`.
The step must be a positive integer scalar. Values without the selected axis
are unchanged; empty axes remain empty.
`flatten` (Uiua's `deshape`) turns any array into a vector in storage order:
`[1_2_3 4_5_6]` becomes `[1 2 3 4 5 6]`, and `7` becomes `[7]`.
`squeeze` removes all length-one dimensions, preserving the data and other axes.
For example, shape `[1 2 1 3 1]` becomes `[2 3]`, and `[7]` becomes scalar `7`.
`reshape` takes data first and a shape second. A scalar shape repeats the whole
array along a new leading axis; a shape list cycles or truncates the flat data.
For example, `reshape,[2 3]` on `[1 2 3]` gives `[1_2_3 1_2_3]`.
One `inf` dimension is inferred by rounding down; negative dimensions reverse
their axes. Scalar `inf` preserves the array, and scalar `-inf` reverses its rows.
`inf` and `-inf` are f64 infinity literals.
`base` converts numbers to digits with the least significant digit first;
the value is the first argument and the scalar base or mixed-radix list is second.
It adds a trailing digit axis and pads shorter results with zeros.
`radix` performs Uiua's anti-base operation, collapsing the trailing digit axis.
`base10` and `radix10` are monadic aliases for `base,10` and `radix,10`.
For example, `base10` on `123` gives `[3 2 1]`, and `radix10` converts it back.
The Psi combinator applies the preceding composition to both inputs before
combining them: `{ sq |psi add }` on `2 3` produces `13`, following
`(f |psi g)(x,y) = g(f(x),f(y))`. Its combining function must be dyadic.
`{ f |d2 g h }` computes `h(f(x),g(y))`, with monadic `f` and `g`.
`{ f |phi1 g h }` computes `h(f(x,y),g(x,y))`, with dyadic `f` and `g`.
Both combinators require a dyadic combining function `h`.
Inputs contain one value for monadic scopes and two for dyadic
functions. Values can be numbers, rectangular arrays, characters (`@a`), or
quoted strings (`"ab"`). Characters are Unicode code point scalars; strings
are vectors of code points. Literals support escapes such as `\n`, `\t`,
`\\`, `\"`, and `\u{1F600}`. `id` returns its argument unchanged.
`log` prints its argument to stdout followed by a newline and returns it unchanged.
`log.str` does the same, interpreting numbers as Unicode code points: vectors
print as quoted strings, scalars as `@` characters, and higher-rank arrays as
grids of quoted rows, like Uiua character arrays. Tuples are formatted recursively.
Invalid Unicode scalar values are rejected.
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
marker runs and applies `id` to each group. `Partials add` computes inclusive
prefix sums along the innermost dimension independently: `[[1 2 3] [4 5 6]]`
becomes `[[1 3 6] [4 9 15]]`. Partials passes the accumulator first and the next
scalar second to its binary function, which must return a scalar. Scalars
keep their shape; Partials requires non-empty input.
`Scan add` takes an array and a scalar seed: `[1 2 3]` with seed `10`
produces `[11 13 16]`. It preserves the input shape, including empty arrays,
and starts each innermost vector from the seed.

`prepend` takes an array first and a row second, adding that row at the front.
For example, `prepend,50` maps `[1 2]` to `[50 1 2]`. For higher-rank arrays,
the row's shape must match the array's trailing dimensions.

Named constants can be literal values or evaluated pipelines: `a = 2 |> sq`
binds `a` to `4`. For example, `ker = [3 3] 1 |> fill` constructs a constant
array. Constants can reference earlier definitions and be used as partial
application arguments, such as `convolve.same,ker`.
Array-producing pipelines can also be inlined inside brackets, such as
`convolve.same,[[3 3] 1 |> fill]`. The pipeline is evaluated when parsed,
and its array result is used directly without adding an extra dimension.

Partial applications accept literal choices separated by `***`. A scope runs
every combination of choices on the same input and stacks the results into
a Cartesian array. The first choice varies fastest; later choices add outer
axes, followed by the result's own dimensions. For example,
`\ mul,2***3 mul,5***7` on `1` produces `[10_15 14_21]`: the four
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

`Reduce add` folds each innermost vector from left to right;
`[[1 2] [3 4]]` becomes `[3 7]`. Its operand must be dyadic and its input
must be non-empty. Scalars remain scalars.
`Fold add` takes an array first and a scalar seed second: `[1 2 3]` with
seed `10` produces `16`. Each innermost vector starts from the seed;
empty vectors return the seed. `sum` aliases `Fold,0 add`, so empty sums return `0`. Both pass the accumulator first and the next
scalar second to their operand, which must return a scalar.

`Stencil,3 sum` applies `sum` to overlapping windows of three leading-axis
rows. With a unary operand, `Stencil` without a bound size is dyadic and
takes the array first and window size second. Sizes currently must be positive
integer scalars; multidimensional sizes, strides, padding, and fill are not
implemented. With a dyadic operand, `Stencil sub` applies `sub` to adjacent
rows without requiring a size. `Pairwise` expands to `Stencil,2`, so
`Pairwise sub` and `Pairwise sum` both operate on adjacent pairs.

`Tuples,2 less couple` selects increasing index pairs and applies `couple`
to the two selected elements. Tuples takes two dyadic functions: an index
predicate followed by the function applied to each selected pair, like dyadic
Stencil. The result shape follows that function's output. Array selections
require size 2; scalar inputs retain selection-count behavior. Tuples uses the
trailing axis by default; `Tuples.r3,2 less sub` selects pairs of three-element rows from
a matrix.

`try test_alias("sum", "Fold,0 add")` compares parsed instruction trees
recursively, including HOF operands and literal contents. It checks structural
equivalence rather than equality on sample inputs. `test_hof_alias` does the
same with several primitive, scoped, and nested-HOF operands appended.

Named functions are defined before the main scope with `name = body`:

```text
part1 = \ mod,100 count,0
part2 = \ sub,1 |s {(div,100 floor Pairwise sub abs sum) |psi add} |b div,2
\ prepend,50 Partials add part1 ** part2
```

Definitions end at a newline outside parentheses, braces, and arrays. Names
start with a letter and may contain letters, digits, and underscores. They
can reference earlier definitions and be used in nested scopes, alternatives,
and as higher-order operands. Primitive names cannot be redefined; duplicate
names are rejected. Recursion and forward references are not supported.
Function definitions must explicitly declare their arity: use `\` or parentheses
for a monadic function, and `\\` or braces for a dyadic function. For example,
`double = \ mul,2` and `combine = { add sq }`. Bare primitive aliases and
unscoped compositions are rejected.

`Log f` preserves the arity and behavior of `f`, printing its arguments to
stdout before each call. For example, `Log add` prints both arguments and
returns their sum; `Log sq` prints one argument and returns its square.
`Log,7 add` binds the second argument to `7` and logs both arguments.

`MapAccum f g` takes an array and an initial accumulator. For each leading-axis
row, it collects `f row accumulator`, then uses `g row accumulator` as the
accumulator for the next row. For example, `{ MapAccum couple mul }` on
`[2 3 5] 7` produces `[2_7 3_14 5_42]`. `MapAccum,7 f g` binds the initial
accumulator.

`Repeat f` takes a value and a nonnegative integer scalar count; `Repeat,n f`
binds the count and takes one value. For example, `{ Repeat sq }` on `2 3`
and `(Repeat,3 sq)` on `2` both produce `256`. A zero count returns the input.
For dyadic updates, `Repeat,n f g` takes two values and simultaneously updates
both using the previous pair: `{ Repeat,2 mul sub }` on `2 3` produces `[-6 7]`.
The final pair is combined with `couple`, which requires matching shapes.
`Fix f` repeatedly applies a monadic function until consecutive results have
exactly equal shapes and elements (including tuple structure). `Fix f g` uses
the same simultaneous pair updates and stops when both values are unchanged.
Fix always applies its functions at least once; nonconverging functions do not
terminate. NaN elements do not compare equal.

`Table` takes a dyadic function and produces a dyadic function that applies it
to every pair of leading-axis rows. `\\ Table add` on `[1 2]` and `[10 20 30]`
returns `[[11 21 31] [12 22 32]]`. The first argument supplies the outer axis;
scalar arguments add no axis. Result cells must have matching shapes.

Lambdas name their arguments before `->`: `(x -> x |> add,1)` or
`{x, y -> x y |> add}`. The backslash scope forms accept the same headers.
Patterns destructure array rows or tuple elements, including nested patterns:
`{[a b], c -> a c |> couple tuple,b}` returns a tuple containing `[a c]` and `b`.
`tuple` constructs a pair of arbitrary values; `second` selects the second
array row or tuple element.

Arguments are written into one lookup table shared by calls within an evaluation.
Bindings are removed on return, so repeated calls can reuse the same parameters.
Nested calls can reference active outer arguments. Reusing an active name,
a declared name, or a primitive name fails with `shadowed names not allowed`.
Variable arguments to `|>` and partial applications such as `add,x` are resolved
when the lambda runs.

Value expressions support `+`, `-`, `*`, and `/` with named lambda variables
and constants wherever a value is accepted, including partial arguments,
arrays, tuples, and strands. Multiplication and division bind before addition
and subtraction; equal precedence associates left to right. Use `*` for multiplication (`a*5` or `a * 5`); `***` separates literal choices.
For example, `([a b] -> b*5 a+1 |> couple)` on `[2 3]` returns `[15 3]`.

User definitions appear before the main expression, one per line. Value functions
and constants use `snake_case`; higher-order functions use `TitleCase` (no
underscores). `F` and `G` are reserved function placeholders and cannot be
definition names or value parameters. A TitleCase definition must use `F`; using
`G` makes it consume two function operands, in `F`, `G` order. Snake-case
definitions cannot use either placeholder.

HOFs expand like macros at parse time, using definitions visible where they were
declared. They retain the explicit value arity syntax of ordinary functions.
Operands may be primitives, named functions, grouped functions, or other HOF
applications. Placeholders can occur repeatedly and inside nested scopes:

```text
Twice =\ F F
Compose =\ F G
increment =\ add,1
\ Compose (Twice increment) sq
```

On input `3`, this returns `25`. A dyadic HOF can be declared with `\\` or
braces, for example `Combine = { F |phi1 G add }`.
