# array42 — Zig port of Free42

A native Zig port of [Free42](https://github.com/aswild/free42) (the HP-42S
calculator simulator), targeting the **cgm-zig** compiler (Zig 0.16.0 + the
EchoSystems patchset — same language, more robust frontend).

## Status

**Step 3 (transcendentals) — done.** `phloat.zig` implements sqrt, exp, log,
log10, trig, inverse trig, hyperbolic, pow, and gamma from argument reduction +
Taylor series to full 34-digit decQuad precision, and `commands2.zig` ports the
transcendental commands (SIN/COS/TAN/ASIN/ACOS/ATAN/LOG/LN/10^X/E^X/SQRT/X^2/
1/X/Y^X/→REC/→POL/RND/N!/SINH/COSH/TANH/ASINH/ACOSH/ATANH/LN1+X). All 31 tests
pass.

## Roadmap

1. **Foundation** — `phloat` type (34-digit decimal128) — *done*
2. **RPN core** — stack, arithmetic, display, core commands — *done*
3. **Transcendentals** — sqrt/exp/log/trig/hyperbolic/pow/gamma — *done*
4. **Array enhancement** — DB48X-grade array types (matrix = vector of vectors)
5. **Equation Writer** — HP 50g Equation Writer equivalent, so AI partners can
   "throw" equations effortlessly (type them as written, without thinking about
   RPN math/operations)
6. **MCP + Skill** — expose the calculator as an MCP server + Claude Code skill

| Layer | File | Status |
|---|---|---|
| Decimal core | `vendor/decNumber/` (vendored C, ICU license) | done |
| Float abstraction | `src/phloat.zig` | done (transcendentals done) |
| Calculator core | `common/*.cc` → `src/` | in progress (step 2–3) |
| Shell / MCP | `shell.h` → MCP server | pending (step 6) |

## Build

```sh
zig build          # compile
zig build run      # run the vertical-slice demo
zig build test     # run phloat unit tests
```

## Design

Free42's core is layered with two seams that make the port tractable:

```
[Platform frontends: gtk/ android/ iphone/ mac/ windows/]
        ↓  shell.h  (platform interface)
[Core: common/*.cc — calculator logic, ~49k lines]
        ↓  core_phloat  (float abstraction)
[Decimal math: Intel BID  →  we use decNumber's decQuad]
```

`phloat` is a 34-digit IEEE 754 decimal128 (`decQuad`), matching Free42
Decimal's `bid128` precision exactly. The transcendental functions (sin, cos,
tan, exp, ln, gamma, …) are deferred to step 3 — decNumber provides only the
core arithmetic, and the stubs panic loudly rather than return a wrong answer.

## License

The Zig port is GPL-2.0 (inherited from Free42). The vendored decNumber is
under the ICU license (`vendor/decNumber/ICU-license.html`).
