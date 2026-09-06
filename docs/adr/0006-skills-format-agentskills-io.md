# ADR-0006 — Skills use the agentskills.io SKILL.md format
Status: accepted · Date: 2026-09-05

## Context
Claude Code, Codex, goose and others converge on a `SKILL.md` (YAML frontmatter + markdown body + optional
`references/` and `scripts/`) format. Interoperability lets users import existing skills.

## Decision
Skills are directories with `SKILL.md` per the agentskills.io spec, plus Trinity-specific optional frontmatter keys
under `trinity:` (e.g. `requires_tools`, `risk`, `lua_entry`). Filesystem is canonical; DB indexes it.

## Consequences
- Skills written for other agents in this format can be dropped in; Trinity skills can be shared out.
- Executable skill logic (Slice 110) is Lua under `scripts/` referenced by `trinity.lua_entry`, never Elixir eval.
