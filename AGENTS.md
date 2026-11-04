# Project instructions

- Write implementation and test tooling in Zig, not Python.
- Programs evaluate to functions. Arguments are passed to that function; there is no evaluation stack. Report incorrect argument counts as `WrongNumberOfArguments`, never `StackUnderflow`.
- Do not add negative-space tests (tests asserting errors, rejected inputs, or unsupported behavior). Test requested successful behavior directly.
- Keep exactly one language conformance test: code `mul couple`, input `2 3`, output `[6,2]`. Uiua differential tests are separate and must also be written in Zig.
- Commit changes when finished.
