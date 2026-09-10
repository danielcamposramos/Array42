# array42 — Zig port of Free42

A native Zig port of [Free42](https://github.com/aswild/free42) (the HP-42S
calculator simulator), targeting the **cgm-zig** compiler (Zig 0.16.0 + the
EchoSystems patchset — same language, more robust frontend).

## Status

**Step 1 (foundation) — done.** The `phloat` type is ported and verified.

| Layer | File | Status |
|---|---|---|
| Decimal core | `vendor/decNumber/` (vendored C, ICU license) | done |
| Float abstraction | `src/phloat.zig` | done (transcendentals stubbed) |
| Calculator core | `common/*.cc` → `src/` | pending (step 2) |
| Shell / MCP | `shell.h` → MCP server | pending (step 5) |

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
