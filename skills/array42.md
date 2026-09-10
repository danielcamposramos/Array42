---
name: array42
description: Use the Array42 exact-decimal calculator (ACIG tools array42_eval / array42_call) for numeric computation — arithmetic, trig, and matrix/vector math. Use when you need an exact number, a matrix inverse/determinant, a dot or cross product, or a quick calculation. NOT for symbolic algebra (simplify/derive/indefinite integrals) — that is SymPy/Wolfram territory.
scope: general
tags: calculator, decimal, arithmetic, trig, matrix, vector, determinant, inverse, dot-product, cross-product, exact-number, numeric
---

# Array42 — the exact-decimal calculator

Array42 is a fork of Free42 (the HP-42S simulator) ported to native Zig, with
DB48X-grade arrays and a 34-digit decimal128 core. It is a **calculator**, not a
computer-algebra system and not a tutor: it evaluates expressions and returns
**exact 34-digit decimal** results. It does not simplify, derive, show steps, or
explain — that is knowledge work for you and the human to do on top of the
answers.

## How to call it (ACIG tools)

| Tool | Purpose |
|---|---|
| `array42_eval(expression)` | Evaluate one expression, return the exact-decimal result. **Primary tool.** |
| `array42_call(method, arguments)` | Raw access to the full 7-tool surface: `eval`, `stack`, `store`, `recall`, `vars`, `clear`, `mode`. |

`array42_call` takes `arguments` as a JSON object string, e.g.
`'{"expression": "det([[1,2],[3,4]])"}'`. For a **stateful multi-step chain**
(store then recall, set angle mode then evaluate), pass `method="script"` with
`arguments` a JSON array of `{method, arguments}` objects — they run in one
process, in order:

```
array42_call("script", '[{"method":"store","arguments":{"name":"A","expression":"[[1,2],[3,4]]"}},{"method":"eval","arguments":{"expression":"det(A)"}}]')
```

Each `array42_call` spawns a fresh process, so named variables do **not** persist
across separate calls — chain them inside one `script` call.

## Expression language

`array42_eval` accepts algebraic notation, written as-is:

- **Arithmetic**: `+ - * / ^ !` with normal precedence (`^` is right-assoc).
- **Functions**: `sin cos tan asin acos atan sinh cosh tanh asinh acosh atanh
  ln log exp sqrt sq abs sign ip fp fact deg rad`.
- **Matrix/vector**: `det(A)` `inv(A)` `trans(A)` `dot(u,v)` `cross(u,v)`,
  and the operators `mod` and `pow`.
- **Literals**: numbers, `pi`, `e`, array literals `[1,2,3]` and matrices
  `[[1,2],[3,4]]`, and named variables.

## Key semantics (read before using)

1. **Exact decimal.** Results are 34-digit decimal128, not binary float.
   `array42_eval("0.1 + 0.2")` returns `0.3` exactly. Trust the digits.
2. **Angle mode defaults to DEGREES** (HP-42S default). For radians, set the
   mode first: `array42_call("script", '[{"method":"mode","arguments":{"angle":"rad"}},{"method":"eval","arguments":{"expression":"sin(pi/2)"}}]')`
   returns `1`; without the mode change `sin(pi/2)` is not `1`.
3. **Addressable arrays.** `store("A", "[[1,2],[3,4]]")` gives `A` a stable
   handle; reference it by name in later expressions: `det(A)`, `inv(A) * A`.
   Use `vars()` to see what is stored.
4. **Errors are not exceptions.** A failed call returns `isError: true` with a
   message (`"Divide by 0"`, `"Nonexistent"`, `"Syntax Error"`, `"Invalid
   Data"`). Read the message and correct the expression.
5. **Real mode.** `sqrt(-1)` returns `Invalid Data` (real-mode HP-42S
   behavior), not a complex result. There is no complex-mode toggle yet.

## Worked examples

```
array42_eval("1 + 2 * 3")                 → 7
array42_eval("0.1 + 0.2")                 → 0.3
array42_eval("det([[1,2],[3,4]])")        → -2.000…001  (LU rounding, ~33 correct digits)
array42_eval("dot([1,2,3],[4,5,6])")      → 32
array42_eval("450 * 9.80665 * ln(2000000/200000)")  → 10161.29…  (rocket Δv)
```

## When to use Array42 vs. something else

- **Use Array42** for: exact arithmetic, trig, matrix/vector math, a definite
  numeric answer, or chaining a multi-step computation across named variables.
- **Do not use Array42** for: symbolic simplification, derivatives, indefinite
  integrals, or solving for a formula. That is SymPy/Wolfram territory — the
  ceiling this tool deliberately sits below.
