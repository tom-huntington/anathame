# Anathame

Requires Zig 0.17, Python 3, and (for differential tests) Uiua on PATH.

- `zig build test`: Zig unit tests and Markdown conformance cases.
- `zig build test-uiua`: generated Uiua differential tests (default seed 1729).
- `python tests/uiua_functions.py --seed 42 --cases 100`: reproduce or expand generated coverage after `zig build`.
- `zig build run -- "mul" 2 3`: evaluate a program.

Conformance cases live in `conformance.md`: description, code, input, output,
separated by `---`. Arguments use semicolons (`input: 2; 3`); arrays use brackets. Expected errors start with `error: `.
Every case prints input, code, expected output, and actual output. Tests fail
with a nonzero exit status and continue reporting other cases.

Adjacent primitives form an N train: `(f g)(x,y) = g(f(x,y),x)`.
Longer trains associate left: `f g h` means `h(g(f(x,y),x),x)`.
Thus `mul couple` with input `2 3` produces `[6 2]`. Inputs contain exactly
two separate scalar arguments, written `2; 3` in fixtures and `2 3` as two CLI
arguments. Array arguments are rejected for now. Array values are rectangular;
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
