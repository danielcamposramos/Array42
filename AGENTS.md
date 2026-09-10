# AGENTS.md — Array42

Array42 is a native Zig port of Free42 (the HP-42S calculator) exposed as an
**MCP server** with seven tools. It is an **evaluator**, not a CAS: it returns
exact 34-digit decimal answers and does not simplify, derive, or explain.

When you need an exact number, a matrix inverse/determinant, or a quick
calculation, call the MCP tools directly — do not reimplement the math.

- **Tools:** `eval`, `stack`, `store`, `recall`, `vars`, `clear`, `mode`.
- **Full guidance:** `.claude/skills/array42/SKILL.md` (Claude Code),
  `.codex/skills/array42/SKILL.md` (Codex), `.cursor/rules/array42.mdc`
  (Cursor). Read the one for your harness before using the tools.

Key gotchas (the rest is in the skill):

1. **Exact decimal** — `eval("0.1 + 0.2")` → `0.3`, not `0.30000000000000004`.
2. **Angle mode defaults to DEGREES** — call `mode("rad")` before radian trig.
3. **Errors are `isError: true`**, not exceptions — read the message.
4. **Real mode only** — `sqrt(-1)` → `Invalid Data`, not a complex result.
5. **Not symbolic** — no simplification/derivatives/indefinite integrals; that
   is SymPy/Wolfram territory, the ceiling this tool deliberately sits below.
