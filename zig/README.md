# array42 — Zig port of Free42

A native Zig port of [Free42](https://github.com/aswild/free42) (the HP-42S
calculator simulator), targeting the **cgm-zig** compiler (Zig 0.16.0 + the
EchoSystems patchset — same language, more robust frontend). Enhanced with
DB48X-grade array types and exposed as an MCP server + Claude Code skill.

## Status

**Step 6 (MCP + Skill) — done.** The calculator is exposed as an MCP server
(`array42-mcp`) with seven tools (`eval`, `stack`, `store`, `recall`, `vars`,
`clear`, `mode`), plus a Claude Code skill (`.claude/skills/array42/`). 59/59
tests pass.

## Roadmap

1. **Foundation** — `phloat` type (34-digit decimal128) — *done*
2. **RPN core** — stack, arithmetic, display, core commands — *done*
3. **Transcendentals** — sqrt/exp/log/trig/hyperbolic/pow/gamma — *done*
4. **Array enhancement** — DB48X-grade array types (matrix = vector of vectors) — *done*
5. **Equation Writer** — HP 50g Equation Writer equivalent, so AI partners can
   "throw" equations effortlessly (type them as written, without thinking about
   RPN math/operations) — *done*
6. **MCP + Skill** — expose the calculator as an MCP server + Claude Code skill — *done*

| Layer | File | Status |
|---|---|---|
| Decimal core | `vendor/decNumber/` (vendored C, ICU license) | done |
| Float abstraction | `src/phloat.zig` | done (transcendentals done) |
| Calculator core | `common/*.cc` → `src/` | done (steps 2–4) |
| Equation Writer | `src/equation.zig` | done (step 5) |
| Shell / MCP | `src/mcp.zig` → MCP server | done (step 6) |

## Build

```sh
zig build          # compile (array42 demo + array42-mcp server)
zig build run      # run the vertical-slice demo
zig build mcp      # run the MCP server (stdio JSON-RPC)
zig build test     # run all unit tests
```

## Using the MCP server

The server speaks JSON-RPC 2.0 over stdio. Register it with Claude Code:

```sh
# project-local (uses .mcp.json in the repo root)
zig build          # build the binary first
# then open Claude Code in this repo — it auto-loads .mcp.json

# or register globally
claude mcp add array42 -- zig/zig-out/bin/array42-mcp
```

The companion skill (`.claude/skills/array42/SKILL.md`) teaches Claude how to
use the tools. The tools are:

| Tool | Purpose |
|---|---|
| `eval(expression)` | Evaluate an algebraic expression, return the exact-decimal result |
| `stack()` | Read the current RPN stack |
| `store(name, expr)` | Evaluate + store under a name (addressable array), returns a handle |
| `recall(name)` | Recall a named variable |
| `vars()` | List all named variables |
| `clear()` | Clear the stack |
| `mode(angle)` | Set the angle mode (`deg`/`rad`/`grad`) |

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
Decimal's `bid128` precision exactly. The `shell.h` seam is realized as the
MCP server in `src/mcp.zig` — the same place a GUI frontend would plug in.

## License

The Zig port is GPL-2.0 (inherited from Free42). The vendored decNumber is
under the ICU license (`vendor/decNumber/ICU-license.html`).
