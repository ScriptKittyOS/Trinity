# Trinity — Project Plan Package

This directory is the **planning and accountability layer** for building Trinity: a personal AI agent on
Elixir/BEAM with Phoenix LiveView, shipped as a desktop app. It runs on your machine, remembers you, learns
procedures, acts through tools under a permission gate, and reaches you on any surface.

It is designed to be consumed by a coding agent with a human acting as product owner.

## How to use this package

1. Point git at the tracked hooks, before the first commit:

   ```
   git config core.hooksPath .githooks
   ```

   `.githooks/commit-msg` strips assistant attribution trailers from every message. It is the first step
   because a trailer that reaches a tag is permanent. `scripts/plan_check.sh` rule 8 checks the history
   itself, so an unconfigured hook fails the gate rather than passing quietly.
2. Create an empty git repo for the project.
3. Copy these files and directories into the repo root, and only these:
   - `CLAUDE.md` (the coding agent reads it automatically)
   - `ROADMAP.md`
   - `VERSIONS.md`
   - `docs/`
   - `templates/`
   - `slices/`
4. Commit: `chore: add project plan package` — this is commit #1, before any code.
5. Tell the coding agent: **"Start Slice 000."** Everything else is in `CLAUDE.md`.
6. After each slice, you review `slices/NNN-*/PROOF.md`, then say "approve slice NNN" or list changes.
   The agent does not begin the next slice without your approval (see `docs/04-slice-process.md`).

## What is in here

| Path | Purpose |
|---|---|
| `CLAUDE.md` | Operating rules for the coding agent. Non-negotiable process. |
| `ROADMAP.md` | Every slice, its phase, milestone, dependencies, and live status. |
| `VERSIONS.md` | Verified dependency versions + the re-verification procedure. |
| `docs/00-vision.md` | Goals, non-goals, principles, and the properties this design is meant to demonstrate. |
| `docs/01-architecture.md` | Supervision tree, module map, extension points, data flow. |
| `docs/02-tech-stack.md` | Library choices with justification and risk flags. |
| `docs/03-conventions.md` | Code style, branching, commits, tests, proof standard, Definition of Done. |
| `docs/04-slice-process.md` | The slice lifecycle and the gates a slice must pass. |
| `docs/05-data-model.md` | Ecto schemas and invariants. |
| `docs/06-risk-register.md` | Known risks, triggers, mitigations, owners. |
| `docs/07-security-model.md` | Trust boundaries, permission gate, secrets, injection defences. |
| `docs/08-standards.md` | Standards landscape (AAIF, MCP 2026-07-28, A2A, Agent Skills, AGENTS.md) and Trinity's posture. |
| `docs/adr/` | Architecture Decision Records. Add one whenever a decision changes. |
| `templates/` | SLICE, PROOF and ADR templates. |
| `slices/NNN-name/SLICE.md` | The spec for each slice (goal, scope, acceptance criteria, proof required). |
| `slices/NNN-name/PROOF.md` | Written by the agent when the slice is done. Evidence, not claims. |
| `slices/NNN-name/NOTES.md` | Optional. Deviations, decisions, follow-ups discovered during the slice. |

## Connecting Trinity to the platform

Trinity runs standalone, and it is also one component of **Sanction OS**, the platform formed by Requisition and
Ultraviolet.

**Requisition** is the authority layer. Point `TRINITY_AUTHORITY` at the adapter module and Trinity delegates every
catalogued effect to it: Trinity proposes, Requisition decides, and Trinity keeps no executor for those effects.
Trinity refuses to start if the module is absent or does not implement `Trinity.Authority`. See
`docs/adr/0008-authority-is-an-adapter.md` and `docs/adr/0010-authority-selection-at-boot.md`.

**Ultraviolet** is the purple-team tool. Add it to `config :trinity, :mcp_servers` like any other MCP server. Its
read tools return query-receipted results, its proposal tools return proposal ids rather than effects, and content
coming back from it is tagged untrusted like any other external content.

Both are optional. `TRINITY_AUTHORITY=local` with no MCP servers configured is a complete Trinity.

## Principles baked into this plan

- **Accountability by artifact.** A slice is done when `PROOF.md` shows the gate passed and the acceptance
  criteria are demonstrated with command output, not prose.
- **One slice → one merge → one tag.** History is the audit log.
- **De-risk early.** Slice 001 is a packaging spike, because desktop packaging is the biggest unknown.
- **Modular by construction.** Every pluggable thing (LLM provider, tool, gateway, memory store,
  skill loader) is a behaviour behind a registry, enforced with the `boundary` library.
- **Latest *stable* versions, verified, not assumed.** `VERSIONS.md` is re-verified at Slice 000 and at
  every phase boundary. Note the packaging-driven OTP pin (see `docs/adr/0005-*.md`).
- **Numbering gaps are intentional.** Slices are numbered 000, 001, 010, 011… so new slices can be inserted
  without renumbering.
