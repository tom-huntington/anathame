# Anathame

Requires Zig 0.17 and (for differential tests) Uiua on PATH.

- `zig build test`: Zig unit tests and combinator conformance tests.
- `zig build test-uiua`: generated Zig differential tests against Uiua (seed 1729, 30 cases per primitive).
- `zig build test-uiua -- 42 100`: reproduce or expand coverage with a seed and case count.
- `zig build run -- "mul" 2 3`: evaluate a binary function.

Conformance tests live in `tests/combinators.zig`. Each test calls
`try run_test(code, input, expected)`; the helper owns and frees its arena
and compares parsed output shapes and numbers. Expected arrays accept commas.

Adjacent primitives form an N train: `(f g)(x,y) = g(f(x,y),x)`.
Longer trains associate left: `f g h` means `h(g(f(x,y),x),x)`.
Thus `mul couple` with input `2 3` produces `[6 2]` (N combinator).
A unary first function forms `(f g)(x) = g(f(x),x)` (S combinator):
`sq couple` with input `2` produces `[4 2]`. `sq` squares each element,
equivalent to Uiua's self-multiply (`˙×`).
Inputs contain one scalar for `sq` or two for binary functions, written
`2 3` in the runtime and as separate CLI arguments.
Array arguments are rejected for now. Array values are rectangular;
`couple` returns an array. Code contains function
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
