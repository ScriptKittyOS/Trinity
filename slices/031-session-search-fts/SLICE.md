# Slice 031 — Session search (FTS5)

| Field | Value |
|---|---|
| Phase | 3 Memory |
| Milestone | M3 Remembers |
| Size | S |
| Depends on | 010 |

## Goal
Full-text search over all messages: SQLite FTS5 virtual table kept in sync by triggers; Postgres `tsvector`
equivalent; `Trinity.Memory.Search.messages/2`; a `session_search` tool; a search UI.

## Why
"Did we discuss X?" is the most common recall question and the one a single index answers. Ours is rebuildable from the messages, so losing it costs a reindex rather than the memory.

## Scope
**In:**
- Migration: `messages_fts` (fts5, `content`, `session_id UNINDEXED`, `message_id UNINDEXED`, `tokenize='porter unicode61'`) + insert/update/delete triggers; Postgres branch with a generated `tsvector` column + GIN index.
- `Trinity.Memory.Search.messages(query, opts)` → ranked hits with snippet (`snippet()`/`ts_headline`), session title, timestamp; filters: persona, date range, role.
- `mix trinity.search.reindex` rebuilds the index from `messages`.
- Tool `session_search(query, limit)` risk `:read`.
- UI: `/search` page with results linking into sessions at the message (`/s/:id#m-<seq>`).
**Out:**
- Semantic search (032), hybrid fusion (032).

## Deliverables
- Migration(s), `lib/trinity/memory/search.ex`, tool, LiveView page, tests on both adapters.

## Acceptance criteria
1. [auto] Inserting a message makes it searchable immediately (trigger) on SQLite and Postgres (tests).
2. [auto] Query with stemming: "running" finds "ran"/"runs" via porter on SQLite; documented behaviour on Postgres (test).
3. [auto] `reindex` on a DB with 10k messages completes and yields identical hit counts to the incremental index (test with generated data; time recorded).
4. [manual] Tool returns ≤ `limit` hits with snippets; agent can answer "what did we decide about X last week" using it (manual GIF).
5. [manual] Search page renders results and deep-links (screenshot).

## Proof required
- Tests on both adapters, timing, screenshot, GIF.

## Definition of Done
- [ ] gate green · [ ] AC1–5 proven · [ ] docs/05 synced · [ ] ROADMAP → done · [ ] commit + tag

## Commit & tag
`feat(s031): complete slice 031 — session search (FTS5)` · tag `slice/031`

## Risks / open questions
- FTS5 must be compiled into the bundled SQLite (exqlite default builds include it — verify in the Burrito binary during 100).
