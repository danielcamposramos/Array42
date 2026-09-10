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
zig build gen      # generate MR (comment-stripped) + HR (docs) from src/
zig build mr-build # compile array42-mcp from the MR sources
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

## Harness skills

The MCP server is harness-agnostic; each AI harness gets a companion skill
that teaches it the tools and the key semantics (exact decimal, degrees-by-
default angle mode, addressable arrays, real-mode only). All share the same
body, adapted to each harness's format:

| Harness | Skill | MCP registration |
|---|---|---|
| Claude Code | `.claude/skills/array42/SKILL.md` | `.mcp.json` |
| Codex (OpenAI) | `.codex/skills/array42/SKILL.md` | `.codex/config.toml` |
| Cursor | `.cursor/rules/array42.mdc` | `.cursor/mcp.json` |
| Aider | — (reads the shared skill via `AGENTS.md`) | `.aider.conf.yml` → `.mcp.json` |
| Gemini CLI | `GEMINI.md` | `~/.gemini/settings.json` |
| Any AGENTS.md harness | `AGENTS.md` (repo root) | — |

## SOURCE / MR / HR

The Zig source tree follows the EchoSystems SOURCE/MR/HR doctrine. Partners
edit the SOURCE only; the MR and HR siblings are generated, never hand-edited:

- **SOURCE** — `src/*.zig`, canonical truth (comments + implementation).
- **MR** — `zig-out/mr/*.zig`, machine runtime: comment-stripped, what the
  Zig compiler consumes (`zig build mr-build` compiles the MCP server from it).
- **HR** — `zig-out/hr/*.zig.md`, human-readable projection: the doc comments
  (`///` and `//!`) extracted into markdown.

The compiler is `tools/hrmr.zig` (built as the `hrmr` executable). `zig build
gen` runs it; `zig build mr-build` regenerates the MR and compiles from it.
The MR pass is a lexical scan that strips line and nested block comments while
preserving string, char, and multiline-string literals verbatim.

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
