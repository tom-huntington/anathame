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
Inputs contain one value for monadic scopes and two for dyadic
functions. Values can be numbers, rectangular arrays, characters (`@a`), or
quoted strings (`"ab"`). Characters are Unicode code point scalars; strings
are vectors of code points. Literals support escapes such as `\n`, `\t`,
`\\`, `\"`, and `\u{1F600}`. `id` returns its argument unchanged.
Separate input values with whitespace or semicolons outside literals.
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
