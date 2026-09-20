# Slice 030: Persona (SOUL) + always-on memory tier

| Field | Value |
|---|---|
| Phase | 3 Memory |
| Milestone | M3 Remembers |
| Size | M |
| Depends on | 012 |

## Goal
Personas with a SOUL document and default model; the always-on memory tier (`profile` and `always_on`) injected
as a frozen snapshot into the system prompt at session start; a `memory` tool the agent uses to add/replace/remove
entries; a budget that triggers consolidation rather than truncation; UI panels to view/edit both.

## Why
Vision goal 3, first half. A small always-on tier with a budget that consolidates instead of clipping.

## Scope
**In:**
- `Trinity.Personas` context: CRUD, `priv/personas/default/SOUL.md` seeded on first run; `sessions.persona_id`; persona picker in UI; `/personality`-style quick edits stored as persona settings.
- `Trinity.Memory` context (always-on part): `memories` table (`tier`, `scope`, `key`, `body`); `Trinity.Memory.AlwaysOn.snapshot/1` renders a deterministic block for the prompt (sorted, sized).
- `memory` tool: `add(tier, key, body)`, `replace(key, body)`, `remove(key)`, `list()`: risk `:write` with a persona-level default rule "allow" (memory writes are low risk but auditable); every change logged.
- Budget: per persona (default 8 KB total for profile + always_on). When exceeded, `Trinity.Memory.Consolidator` asks the LLM to merge/condense entries into a proposal; the proposal is applied automatically if under budget, else queued for user review (UI list).
- Prompt builder ordering: stable (SOUL, tool guidance) → context (skills index placeholder) → volatile (memory snapshot, time, session facts), mirroring the caching-friendly tiering.
- UI: persona editor (SOUL markdown), memory panel (profile / always-on lists with inline edit and delete), consolidation review.
**Out:**
- Semantic/retrievable memory (032), FTS (031), project-scoped memory files (`AGENTS.md`-style: noted as follow-up).

## Design notes
- Snapshot is computed once per session start and on explicit refresh; the Session stores it in state so mid-session edits do not silently change behaviour (documented UX: "takes effect next session or on refresh").

## Deliverables
- `lib/trinity/personas/*`, `lib/trinity/memory/{always_on,budget,consolidator}.ex`, `lib/trinity/memory.ex`, `lib/trinity/tools/memory.ex`, migrations, UI, tests, `priv/personas/default/SOUL.md`.

## Acceptance criteria
1. [auto] New install seeds the default persona; a session uses its SOUL in the system prompt (prompt snapshot test).
2. [auto] Agent calls `memory.add("always_on", "editor", "prefers neovim")` → row exists → next session's prompt contains it (test).
3. [auto] Budget exceeded → Consolidator produces a smaller set; totals ≤ budget; no entry silently dropped without appearing in the consolidation log (test with FakeProvider returning a scripted merge).
4. [auto] Two personas with different SOULs run concurrent sessions; prompts differ accordingly (test).
5. [manual] UI: edit SOUL, add/delete memory entries (screenshots); changes persist.
6. [auto] Memory tool writes appear in the permissions audit as allowed-by-rule (test).
7. [auto] **A memory written in session A is not retrievable in unrelated session B unless promoted (test).**

## Proof required
- Tests, prompt snapshot diff, screenshots.

## Manual verification queue
Every `[manual]` criterion below needs a person. Listed here so the owner sees the queue at G1 rather
than at review time.
- **AC5**: UI: edit SOUL, add/delete memory entries (screenshots); changes persist.

## Definition of Done
- [ ] gate green · [ ] AC1–7 proven · [ ] docs/05 synced · [ ] ROADMAP → done · [ ] commit + tag

## Commit & tag
`feat(s030): complete slice 030 (persona and always-on memory)` · tag `slice/030`

## Risks / open questions
- Auto-applying consolidation may surprise users; default to "auto if under budget, else review" and make it configurable.

## Platform alignment (appended 2026-09-05)
- **M6 scope tag on every memory row:** `scope ∈ {session:<id>, project:<path>, account:<id>, global}`. Retrieval
  filters by the calling session's scope chain; cross-scope promotion (e.g. session → global) is an `:artifact`
  effect through the gate with a receipt. This is AC7 in the list above.
