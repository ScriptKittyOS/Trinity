# Slice 023 — Context compaction + session lineage

| Field | Value |
|---|---|
| Phase | 2 Tools |
| Milestone | M2 Acts |
| Size | M |
| Depends on | 012 |

## Goal
Token-aware context management: measure prompt size per model, summarise the middle of long histories with the
LLM into a compaction message, preserve the always-on tier and recent turns verbatim, and record lineage
(`parent_id`) so nothing is destroyed. Plus a small eval harness so compaction quality is measured, not assumed.

## Why
Risk R7. Compression that quietly discards critical context is the failure to design against; ours has to be measurable and reversible.

## Scope
**In:**
- `Trinity.Memory.Tokens` — token estimation per model (provider tokenizer if req_llm exposes; else calibrated heuristic).
- `Trinity.Memory.Compactor` — strategy: keep system + last K turns; summarise older turns via `Trinity.LLM.generate_object/3` into `%{summary, open_threads, decisions, facts}`; write a `system`-role `compaction` message; mark compacted messages `parts.compacted_by`; optionally fork a child session (`parent_id`) when history exceeds a hard limit.
- Session integration: `compacting` state triggered when estimated prompt > threshold (per model) before a turn; prompt builder uses the compaction message + uncompacted tail.
- UI: "context: N / M tokens" indicator; compaction event shown as a collapsible card; "view original" link to the parent/compacted messages.
- Eval harness built to take suites beyond this one. Compaction is its first; tool selection, injection resistance
  and memory recall are the next, added by the slices that own them rather than here.
- Eval harness: `test/evals/compaction/*.exs` with 3 scripted long conversations and assertions that named facts survive (keyword presence) — run with `mix test --only eval` (excluded by default), results table saved to `proof/`.
**Out:**
- Semantic memory extraction (032) — compaction may *emit* candidate memories to a queue consumed there.

## Design notes
- Never delete messages. Compaction adds; lineage points back.
- Threshold defaults: soft at 70 % of model context, hard at 90 %.

## Deliverables
- `lib/trinity/memory/{tokens,compactor}.ex`, session/prompt changes, migration for `parts.compacted_by` (no schema change if map), UI indicator, eval tests, docs.

## Acceptance criteria
1. [auto] A 200-turn FakeProvider conversation triggers compaction at the soft threshold; the next prompt's estimated tokens drop below the threshold (test with numbers).
2. [auto] All 200 original messages remain in the DB; the compaction message references their `seq` range (test).
3. [auto] Killing the Session during `compacting` → restart → either compaction completed or cleanly retried; no duplicate compaction messages (crash test).
4. [manual] Eval harness: ≥ 90 % of tracked facts survive across the 3 scripted conversations with a real model (live/eval tag; table in proof).
5. [manual] UI shows the token indicator and compaction card (screenshot).
6. [auto] `parent_id` fork path: when the hard limit is hit, a child session is created with the compaction as its first message and the UI redirects (test).

## Proof required
- Tests, eval table, screenshot.

## Manual verification queue
Every `[manual]` criterion below needs a person. Listed here so the owner sees the queue at G1 rather
than at review time.
- **AC4** — Eval harness: ≥ 90 % of tracked facts survive across the 3 scripted conversations with a real model (live/eval tag; table in proof).
- **AC5** — UI shows the token indicator and compaction card (screenshot).

## Definition of Done
- [ ] gate green · [ ] AC1–6 proven · [ ] docs/05 synced · [ ] ROADMAP → done · [ ] commit + tag

## Commit & tag
`feat(s023): complete slice 023 — context compaction and lineage` · tag `slice/023`

## Risks / open questions
- Tokenizer accuracy per provider; calibrate against live `usage` numbers and record the error margin.

## Platform alignment (appended 2026-09-05)
- Compaction summaries inherit provenance taint (M1); the compaction message records the digests of the parts it
  summarised so a reader can trace an instruction back to its source.
