# Anathame

Requires Zig 0.17.

`const` takes two arguments and returns its second argument unchanged.

`logshape` prints the input shape and returns the value unchanged.
`Logshape` wraps a function like `Log`, printing argument and result shapes.
Shapes are printed as dimension lists, such as `[2 3]` or `[]` for scalars.

`env` reads an environment variable as one language literal: `"num_closest" |> env`
returns the number `10` when its value is `10`. Arrays such as `[1 2 3]` and
quoted strings such as `"hello"` are also accepted. Plain unquoted text is not
a string literal. `parse` separately converts Unicode character data into a
single number (including decimals), rather than parsing general literals.

`innerproduct.op1.op2` contracts the last axis of its first argument with the
first axis of its second, combining pairs with `op2` and reducing with `op1`.
The contracted dimensions must match; remaining axes form the result shape.
Both operators accept `add`, `mul`, `min`, `max`, `and`, or `or`.
`mul.mat` aliases `innerproduct.add.mul`; `mul.mat.op1.op2` selects a real
semiring: `add.mul` (also the default), `or.and` for boolean reachability,
`min.add` for shortest-path costs, `max.add` for longest-path costs,
`min.max` for minimax paths, or `max.min` for maximum-capacity paths.
Each pair has a compile-time specialized kernel with contiguous column updates
and cache tiling, following [Fast MMM on CPU](https://siboehm.com/articles/22/Fast-MMM-on-CPU).
Use a release build (`zig build -Doptimize=ReleaseFast`) for performance.
Empty contractions use the reduction
identity (0, 1, positive infinity, or negative infinity as appropriate).
`innerproduct` also defaults to `add.mul`.

`mul.c` multiplies complex numbers represented by a trailing `[real imaginary]`
pair, broadcasting over matching leading axes like real multiplication.
`mul.c.mat` remains unimplemented.

Builtin implementations live in `src/builtins/`: `pervasives.zig` for
elementwise operations, `axial.zig` for axis-dependent operations,
`axis_agnostic.zig` for other value operations, and `hofs.zig` for
higher-order functions. Convolution and regex helpers have separate
modules there. `src/primitives.zig` registers builtin names, aliases, and arities.
Component suffixes describe the items being operated on. Scalar items are the
default, so no `.els` suffix is needed. `.rows` (or `.vec`) selects vector items
along axis -2; `.grids` (or `.mat`) selects matrix items along axis -3.
`.outer` selects the leading axis, regardless of rank. Earlier axes are processed
independently. Type suffixes such as `.c`, `.r3`, and `.c.rows` also work.

`where` and `unwhere` operate on the whole array, independently of axis selection,
following Uiua. `where` repeats each index by its nonnegative integer count:
`[0 2 1]` becomes `[1 1 2]`. For higher-rank arrays it returns coordinate rows
in leading-to-trailing axis order: `[0_2 1_0]` becomes `[0_1 0_1 1_0]`.
A scalar count produces that many zero indices.
`unwhere` counts scalar or vector indices, or rows of a coordinate matrix,
including duplicates and unsorted indices. Each result dimension is one greater
than the largest coordinate on that axis, so trailing zeros are not recovered
by a `where unwhere` round trip. Both reject negative or fractional inputs.

`first` and `last` alias `select.r,0` and `select.r,-1`, selecting the first or
last element of each trailing vector. `first.rows` and `last.rows` select whole
rows; `first.outer` and `last.outer` select along the leading axis.
`select` accepts the same component suffixes, for example `select.rows,1`.
Bare `select` and `second` (`select,1`) retain leading-axis selection.
Scalar selection also unwraps tuple elements. The legacy `last.row` remains
available and leaves scalars and vectors unchanged.

`uncons` splits each trailing vector into its first element and remaining elements.
For `[1_2_3 4_5_6]` it returns the pair `[1 4]` and `[2_3 5_6]`.
`uncons.rows` splits off a whole row; `uncons.outer` splits off a leading-axis item.

`indexin` retains its search-domain suffixes: the default, `.rows`, and `.vec`
search within trailing vectors. `.mat` searches within trailing matrices and
returns coordinate pairs, with the innermost axis first. For example, searching
`[1_2_3 4_5_6]` for `2` with `indexin.mat` returns `[1 0]`.
`.outer` searches the entire array. Earlier haystack dimensions are processed
independently. These suffixes describe the search domain, unlike the item
components used by `first`, `last`, `uncons`, and `sort`.

`split` splits a vector at every non-overlapping occurrence of its delimiter;
`split.first` splits only at the first. Delimiters can be scalars or nonempty
vectors, including strings. Matched delimiters are removed, and empty pieces
are preserved. Equal-length pieces stack into an array; unequal pieces form a
tuple. No match produces an array containing the original vector as one row.
For example, `split.first,"\n\n"` replaces the former `tuple.blankline` for
LF-separated text; use `"\r\n\r\n"` for CRLF-separated text.

- `zig build test`: Zig unit tests and combinator conformance tests.
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
`deduplicate` keeps the first occurrence of each value in each trailing-axis
vector, preserving order. For example, `[2_1_2 4_4_3]` becomes `[2_1 4_3]`.
Scalars and empty arrays are unchanged. NaNs compare equal, as do signed zeros.
Different unique counts across vectors report `ShapeMismatch`.
`deduplicate.rows` removes repeated whole rows along axis -2 in each outer cell.
For example, `[1_2 3_4 1_2]` becomes `[1_2 3_4]`. The general component and
axis selectors are supported, including `.c`, `.grids`, and `.outer`.

`stride,2` keeps every second element along the trailing axis, starting with
the first: `[1 2 3 4 5 6]` becomes `[1 3 5]`. `stride.rows,2` does the
same along axis -2 in each outer cell: `[1_2 3_4 5_6]` becomes `[1_2 5_6]`.
The step must be a positive integer scalar. Values without the selected axis
are unchanged; empty axes remain empty.
`rise` and `fall` return ascending and descending sort indices independently
for each trailing-axis vector, preserving the input shape. Equal values keep
their original index order. Scalars return `0`; empty arrays preserve their shape.
For example, `rise` on `[3_1_2 4_4_1]` gives `[1_2_0 2_0_1]`,
and `fall` gives `[0_2_1 0_1_2]`.

`flatten` (Uiua's `deshape`) turns any array into a vector in storage order:
`[1_2_3 4_5_6]` becomes `[1 2 3 4 5 6]`, and `7` becomes `[7]`.
`cartesian_pow` takes an array and a nonnegative integer scalar exponent, returning
all combinations of that many leading-axis cells. The last choice varies fastest:
`cartesian_pow,2` on `[1 2]` gives `[1_1 1_2 2_1 2_2]`.
For input shape `[m ...]`, the output shape is `[m^n n ...]`.
Exponent zero returns one empty combination; an empty input with a positive
exponent returns no combinations.
`squeeze` removes all length-one dimensions, preserving the data and other axes.
For example, shape `[1 2 1 3 1]` becomes `[2 3]`, and `[7]` becomes scalar `7`.
`shape` returns a vector of dimension sizes: `[1_2_3 4_5_6]` gives `[2 3]`,
and a scalar gives `[]`.
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

`eye` takes a shape and fills its main diagonal with ones and the rest with zeros.
For example, `eye` on `[2 3]` returns `[[1 0 0] [0 1 0]]`.
A scalar size requests a square matrix; `eye` on `3` returns the 3-by-3 identity.

`prepend` takes an array first and a row second, adding that row at the front.
For example, `prepend,50` maps `[1 2]` to `[50 1 2]`. For higher-rank arrays,
the row's shape must match the array's trailing dimensions.

`pad` extends the leading dimension of an array to a minimum size with a scalar
fill value. Its arguments are array, size, and fill; the fill must always be
partially applied first. `[1 2] |> pad,0,4` and `[1 2] 4 |> pad,0` both produce
`[1 2 0 0]`. Sizes must be nonnegative integer scalars. Arrays already at least
that size are unchanged; for matrices, padding adds rows of the fill value.

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

`sort` sorts each innermost vector in ascending order. Component suffixes
select the cells to compare lexicographically: `sort.rows` sorts rows,
`sort.r3` sorts three-element vectors, and `sort.outer` sorts the leading
axis. Scalar elements are the default. Any axes before the
selected axis are processed independently; the array shape is preserved.

`UnDer f g` applies `f`, then `g`, then the inverse of `f`. Currently only
`transpose` has a registered inverse (itself). For example,
`UnDer transpose sort` sorts each column of a matrix. A dyadic `g` receives
both inputs transformed by `f`; the result is transformed back once.

`Sort.by f` aliases `(f rise |sig select)`: `f` produces ascending keys
for the leading-axis rows, which are then reordered by those keys.
`Sort.with p` stably sorts leading-axis rows using a dyadic predicate:
`p(left, right)` must return scalar `1` when left comes before right,
or `0` otherwise. For example, `Sort.with less` sorts ascending and
`Sort.with greater` sorts descending. Equal items retain their input order.

`Reduce add` folds each innermost vector from left to right;
`[[1 2] [3 4]]` becomes `[3 7]`. Its operand must be dyadic and its input
must be non-empty. Scalars remain scalars.
`all` aliases `Fold,1 and` and `any` aliases `Fold,0 or`; empty inputs return `1` and `0`, respectively.
`Fold add` takes an array first and a scalar seed second: `[1 2 3]` with
seed `10` produces `16`. Each innermost vector starts from the seed;
empty vectors return the seed. `sum` aliases `Fold,0 add`, so empty sums return `0`. Both pass the accumulator first and the next
scalar second to their operand, which must return a scalar.

For all four operations, `f |d or` and `f |d and` skip `f` once the accumulator reaches `1` or `0`, respectively. Scans repeat that value for the remaining prefixes. Component-axis operations stop when every accumulator element has reached the absorbing value.

`Stencil,3 sum` applies `sum` to overlapping windows of three leading-axis
rows. With a unary operand, `Stencil` without a bound size is dyadic and
takes the array first and window size second. Sizes currently must be positive
integer scalars; multidimensional sizes, strides, padding, and fill are not
implemented. With a dyadic operand, `Stencil sub` applies `sub` to adjacent
rows without requiring a size. `Pairwise` expands to `Stencil,2`, so
`Pairwise sub` and `Pairwise sum` both operate on adjacent pairs.

`Tuples,2 less` selects increasing index pairs and applies `couple`
to the two selected elements. `Tuples op` is `TuplesWith op couple`.
`TuplesWith` takes two dyadic functions: an index
predicate followed by the function applied to each selected pair, like dyadic
Stencil. The result shape follows that function's output. Array selections
require size 2; scalar inputs retain selection-count behavior. Tuples uses the
trailing axis by default; `TuplesWith.r3,2 less sub` selects pairs of three-element rows from
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
When `f` is dyadic, each step uses the original input as its second argument:
`(Repeat,3 add)` on `2` produces `8` (`add(add(add(2,2),2),2)`).
For dyadic updates, `Repeat,n f g` takes two values and simultaneously updates
both using the previous pair: `{ Repeat,2 mul sub }` on `2 3` produces `[-6 7]`.
The final pair is combined with `couple`, which requires matching shapes.
`Fix f` repeatedly applies a function until consecutive results have
exactly equal shapes and elements (including tuple structure). A single dyadic
function keeps the original input as its second argument, as in `Repeat f`. `Fix f g` uses
the same simultaneous pair updates and stops when both values are unchanged.
Fix always applies its functions at least once; nonconverging functions do not
terminate. NaN elements do not compare equal.
`Fix.check` and `Repeat.check` log the completed iteration number to standard
output at powers of two (1, 2, 4, 8, ...), including the final iteration if it
is a power of two. They otherwise behave like `Fix` and `Repeat`.

`Table` takes a dyadic function and produces a dyadic function that applies it
to every pair of leading-axis rows. `\\ Table add` on `[1 2]` and `[10 20 30]`
returns `[[11 21 31] [12 22 32]]`. The first argument supplies the outer axis;
scalar arguments add no axis. Result cells must have matching shapes.

Lambdas name their arguments before `->`: `(x -> x |> add,1)` or
`{x, y -> x y |> add}`. The backslash scope forms accept the same headers.
Patterns destructure array rows or tuple elements, including nested patterns:
`{[a b], c -> a c |> couple tuple,b}` returns a tuple containing `[a c]` and `b`.
Use one starred name to capture the remaining rows or tuple elements:
`\[first *middle last] -> middle`. The remainder preserves its array shape
or tuple type and may be empty. Tuple values support the same bracket patterns,
including nested patterns.
`tuple` constructs a pair of arbitrary values; `second` selects the second
array row or tuple element.

An extractor `f` followed by a backtick and a pattern applies
the unary function `f` to the incoming value before binding that pattern.
For example, ``[3 2] |> \[sq`a b] -> [a b]`` returns `[9 2]`.
Extractors can nest and wrap array patterns, such as
``\reverse`[a b] -> [a b]``. Named unary functions work too.
The shorthand ``4 |> \sq`a`` returns `16`; an explicit body can use
``4 |> \sq`a -> a+1`` to return `17`.
The backtick marks an inverse in the pattern: binding applies `f` forward.

Arguments are written into one lookup table shared by calls within an evaluation.
Bindings are removed on return, so repeated calls can reuse the same parameters.
Nested calls can reference active outer arguments. Reusing an active name,
a declared name, or a primitive name fails with `shadowed names not allowed`.
Variable arguments to `|>` and partial applications such as `add,x` are resolved
when the lambda runs.

Lambda bodies can return a value directly, such as
`([[x y] [u v]] -> x<y && u<v)` or `([a b] -> [1 b])`, or pass
values to a function with `|>`. Function bodies declare their arity with
`\`, `(...)`, `\\`, or `{...}`. Within bracketed parameter patterns,
underscores construct strands: `[x_y u_v]` matches `[[x y] [u v]]`.
`[[x y] [u_v]]` has mismatched row structure and fails to match a rectangular
two-by-two array.

Value expressions support `<`, `>`, `&&`, `||`, `+`, `-`, `*`, and `/` with named lambda variables
and constants wherever a value is accepted, including partial arguments,
arrays, tuples, and strands. Precedence from highest to lowest is multiplication
and division, addition and subtraction, comparisons, `&&`, then `||`; equal
precedence associates left to right. Boolean operators apply the existing
elementwise `and` and `or` primitives and evaluate both operands. Use `*` for multiplication (`a*5` or `a * 5`); `***` separates literal choices.
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

`Each f` applies a monadic function to each tuple element and stacks the results
along a new leading axis. For example, `(Each sum)` on `tup([1 2], [3 4 5])`
returns `[3 12]`. Results must be arrays with identical shapes; unequal shapes
report `ShapeMismatch`, and tuple results report `ExpectedArray`. An empty tuple
produces `[]` without calling the function. The input must be a tuple.

`Each.fill,0 f` pads mapped results with `0` to the largest size along each
axis before stacking them. The scalar fill value must be partially applied.
For example, `Each.fill,0 id` on `tup([1 2], [3 4 5])` returns
`[1_2_0 3_4_5]`. Lower-rank results gain leading axes of size one, and
padding extends the end of each axis. Tuple results still report `ExpectedArray`.
