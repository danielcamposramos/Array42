---
name: array42
description: Use the Array42 calculator (MCP tools) for exact-decimal numeric computation — arithmetic, trig, and matrix/vector math. Use when the user needs an exact number, a matrix inverse/determinant, or a quick calculation. NOT for symbolic algebra (simplify/derive/indefinite integrals) — that is SymPy/Wolfram territory.
---

# Array42 — the exact-decimal calculator

Array42 is a **calculator**, not a computer-algebra system and not a tutor. It
evaluates expressions and returns **exact 34-digit decimal** results. It does
not simplify, derive, show steps, or explain — that is knowledge work for you
and the human to do on top of the answers.

It is exposed as MCP tools. Call them directly; do not reimplement the math
yourself.

## The tools

| Tool | Purpose |
|---|---|
| `eval(expression)` | Evaluate an algebraic expression, return the exact-decimal result. **Primary tool.** |
| `store(name, expression)` | Evaluate and store under a name (an addressable array/variable). Returns a stable handle. |
| `recall(name)` | Recall a named variable's value and handle. |
| `vars()` | List all named variables. |
| `stack()` | Read the current RPN stack (X first, then Y, Z, T). |
| `clear()` | Clear the stack (named variables are preserved). |
| `mode(angle)` | Set the angle mode: `"deg"`, `"rad"`, or `"grad"`. |

## Expression language

`eval` accepts algebraic notation, written as-is:

- **Arithmetic**: `+ - * / ^ !` with normal precedence (`^` is right-assoc).
- **Functions**: `sin cos tan asin acos atan sinh cosh tanh asinh acosh atanh
  ln log exp sqrt sq abs sign ip fp fact deg rad`.
- **Matrix/vector**: `det(A)` `inv(A)` `trans(A)` `dot(u,v)` `cross(u,v)`,
  and the operators `mod` and `pow`.
- **Literals**: numbers, `pi`, `e`, array literals `[1,2,3]` and matrices
  `[[1,2],[3,4]]`, and named variables.

## Key semantics (read before using)

1. **Exact decimal.** Results are 34-digit decimal128, not binary float.
   `eval("0.1 + 0.2")` returns `0.3` exactly. Trust the digits.
2. **Angle mode defaults to DEGREES** (HP-42S default). For radians, call
   `mode("rad")` first. `eval("sin(pi/2)")` is `1` only after `mode("rad")`.
3. **Addressable arrays.** `store("A", "[[1,2],[3,4]]")` gives `A` a stable
   handle; reference it by name in later expressions: `eval("det(A)")`,
   `eval("inv(A) * A")`. Use `vars()` to see what is stored.
4. **Errors are not exceptions.** A failed call returns `isError: true` with a
   message (`"Divide by 0"`, `"Nonexistent"`, `"Syntax Error"`, `"Invalid
   Data"`). Read the message and correct the expression.
5. **Real mode.** `sqrt(-1)` returns `Invalid Data` (real-mode HP-42S
   behavior), not a complex result. There is no complex-mode toggle yet.

## Worked examples

```
eval("1 + 2 * 3")                 → 7
eval("0.1 + 0.2")                 → 0.3
mode("rad"); eval("sin(pi/2)")    → 1
store("A", "[[1,2],[3,4]]")       → stored A (handle 1) = [[1, 2], [3, 4]]
eval("det(A)")                    → -2
eval("inv(A)")                    → [[-2, 1], [1.5, -0.5]]
eval("dot([1,2,3],[4,5,6])")      → 32
```

## When to use Array42 vs. something else

- **Use Array42** for: exact arithmetic, trig, matrix/vector math, a definite
  numeric answer, or chaining a multi-step computation across named variables.
- **Do not use Array42** for: symbolic simplification, derivatives, indefinite
  integrals, or solving for a formula. That is SymPy/Wolfram territory — the
  ceiling this tool deliberately sits below.
