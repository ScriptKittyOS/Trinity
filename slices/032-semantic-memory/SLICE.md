# Slice 032: Embeddings, semantic memory, hybrid retrieval

| Field | Value |
|---|---|
| Phase | 3 Memory |
| Milestone | M3 Remembers |
| Size | L |
| Depends on | 031 |

## Goal
Local embeddings (Bumblebee `all-MiniLM-L6-v2`, 384-dim) served by a supervised `Nx.Serving`; a `VectorStore`
behaviour with a `sqlite_vec` implementation (and a pgvector one in the CI matrix); the semantic memory tier
(`tier: "semantic"`) populated by an async observer after each turn and by compaction candidates; hybrid
retrieval (FTS + vector, reciprocal-rank fusion) injected into the prompt as "relevant memories"; a `recall` tool.

## Why
Vision goal 3, second half. The unbounded tier that makes the always-on tier's small budget acceptable.

## Scope
**In:**
- `Trinity.Memory.Embedder` behaviour: `embed/1`, `dim/0`; `Bumblebee` impl with `Nx.Serving` under `Trinity.Memory.Supervisor` (batch size, timeout); `ReqLLM` impl (hosted) as fallback; config switch.
- `Trinity.Memory.VectorStore` behaviour: `upsert/2`, `search/3`, `delete/1`, `count/0`; `SqliteVec` impl (virtual table `memories_vec`, loadable extension from `priv/`); `Pgvector` impl.
- Observer: after each completed turn, an Oban-less async Task (Oban arrives in 050; a supervised `Task` queue here) asks the LLM (`generate_object`) for 0–3 durable facts/preferences/decisions from the turn → inserted as semantic memories with provenance and confidence; dedupe by cosine > 0.92.
- Retrieval: `Trinity.Memory.Retriever.relevant(session, query, k)` = RRF(FTS hits, vector hits) with recency decay; result block rendered into the volatile prompt tier under a token cap.
- `recall(query, k)` tool, risk `:read`.
- UI: memory panel gains a "semantic" tab with search, provenance links, delete/pin (pin = promote to always_on).
- Measurements: embed latency (single/batched), EXLA/Bumblebee binary size impact, RAM at idle and during embed, recorded in `docs/perf.md` (new).
**Out:**
- Knowledge-graph memory, reranking models, project-scoped indexes (follow-ups).

## Design notes
- Model weights cached under the data dir (`BUMBLEBEE_CACHE_DIR`); first-run download with UI progress; offline fallback = hosted embedder or disabled semantic tier (never crash).
- `sqlite_vec` extension load happens in a Repo `after_connect` hook; verify it survives Burrito packaging (R4): do the check in this slice by building a Burrito binary and running the vec test inside it.

## Deliverables
- `lib/trinity/memory/{embedder,embedders/*,vector_store,vector_stores/*,observer,retriever}.ex`, migrations (vec table; pgvector column), tool, UI tab, `docs/perf.md`, tests with a tiny fake embedder (deterministic vectors).

## Acceptance criteria
1. [auto] Fake-embedder test: upsert 1,000 vectors, `search/3` returns the known nearest with correct ordering on SQLite and Postgres.
2. [manual] Real Bumblebee embedder: `dim/0 == 384`; embedding "the cat sat" vs "a cat was sitting" cosine > 0.7; vs "quarterly tax filing" < 0.3 (live/slow tag; numbers in proof).
3. [auto] Observer extracts memories from a scripted turn (FakeProvider returns facts) and dedupes a near-duplicate (test).
4. [auto] Retriever: FTS-only hit and vector-only hit both appear in fused results; recency decay demoted an old identical memory (test with controlled data).
5. [auto] Prompt contains a "Relevant memories" block bounded by the token cap (prompt snapshot test).
6. [manual] `recall` tool works end-to-end (manual GIF: teach a fact in one session, recall it in a new one).
7. [auto] Packaged Burrito binary loads `sqlite_vec` and passes a vec smoke test (log), or R4 fallback implemented and documented.
8. [auto] Perf table recorded (latency, binary size delta, RAM).

## Proof required
- Tests, live numbers, GIF, packaged-binary log, perf table.

## Manual verification queue
Every `[manual]` criterion below needs a person. Listed here so the owner sees the queue at G1 rather
than at review time.
- **AC2**: Real Bumblebee embedder: `dim/0 == 384`; embedding "the cat sat" vs "a cat was sitting" cosine > 0.7; vs "quarterly tax filing" < 0.3 (live/slow….
- **AC6**: `recall` tool works end-to-end (manual GIF: teach a fact in one session, recall it in a new one).

## Definition of Done
- [ ] gate green · [ ] AC1–8 proven · [ ] docs/05, docs/perf.md, VERSIONS (bumblebee, nx, exla, sqlite_vec ✅) · [ ] ROADMAP → done · [ ] commit + tag

## Commit & tag
`feat(s032): complete slice 032 (semantic memory and hybrid retrieval)` · tag `slice/032`

## Risks / open questions
- R3/R4 are decided here. If EXLA is too heavy, ship with hosted embeddings default and local as opt-in.

## Platform alignment (appended 2026-09-05)
- Scope enforcement at read time for the semantic tier (M6); the vector search takes the scope filter as a
  required argument, not an option.
