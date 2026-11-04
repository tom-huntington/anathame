# Conformance

`input:` is an argument list separated by semicolons. `[a b]` is one array
value, never an argument list. Inputs currently accept scalars only; array
outputs must be rectangular. Adjacent functions use the N combinator.

---
description: N combinator
code: mul couple
input: 2; 3
output: [6 2]
---
description: scalar multiplication
code: mul
input: 2; 3
output: 6
---
description: couple preserves argument order
code: couple
input: 2; 3
output: [2 3]
---
description: negative fractional arguments
code: mul
input: -1.5; 4
output: -6
---
description: zero multiplication
code: mul
input: 0; 3
output: 0
---
description: known but unimplemented
code: add
input: 2; 3
output: error: UnimplementedPrimitive
---
description: unknown primitive
code: nonsense
input: 2; 3
output: error: UnknownPrimitive
---
description: insufficient arguments
code: mul
input: 2
output: error: StackUnderflow
---
description: arrays are not argument lists
code: mul
input: [2 3]; 4
output: error: ArrayArgumentsNotSupported
---
description: extra arguments
code: mul
input: 1; 2; 3
output: error: InvalidInput
