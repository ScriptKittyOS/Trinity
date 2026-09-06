# Slice 033 — Project context: AGENTS.md

| Field | Value |
|---|---|
| Phase | 3 Memory |
| Milestone | M3 Remembers |
| Size | S |
| Depends on | 030, 022 |

## Goal
Load `AGENTS.md` (AAIF founding project convention) from the session's project root(s) into the context tier
with precedence (nearest root wins), a size cap, provenance taint `untrusted` (it is repository content), and
live reload; expose "project root" as a first-class session setting used by FS allowlists and skill discovery.

## Acceptance criteria
1. [auto] A fixture repo with `AGENTS.md` → its content appears in the prompt's context tier, tagged untrusted (snapshot test).
2. [auto] Nested `AGENTS.md` precedence works (test); cap truncation states what was cut (test).
3. [auto] An instruction inside AGENTS.md to disable approvals does not change gate behaviour (test).

## Scope
**In:**
- `AGENTS.md` discovery from the session's project root(s), nearest-root-wins precedence.
- Load into the prompt's context tier with a size cap; truncation states what was cut.
- Provenance taint `untrusted`: it is repository content, not owner-authored config.
- Live reload on change.
- "Project root" becomes a first-class session setting, consumed by the FS allowlist and skill discovery.
**Out:**
- Editing `AGENTS.md` from Trinity; other agents' project-context conventions.

## Deliverables
- `lib/trinity/context/agents_md.ex`, prompt-builder change, session setting + migration if needed, fixture repos under `test/support/fixtures/`, tests.

## Proof required
- For each acceptance criterion: the command and its output, or a test name and its result, or a screenshot under `proof/`. A sentence is not proof.

## Definition of Done
- [ ] `mix gate` green · [ ] AC1–3 proven · [ ] docs/ADR/VERSIONS updated if affected · [ ] ROADMAP status → done · [ ] final commit + tag

## Commit & tag
`feat(s033): complete slice 033 — AGENTS.md project context` · tag `slice/033`
