# Slice 031: NOTES

## Two facts measured 2026-09-20 before any code

**FTS5 is in the bundled SQLite.** exqlite 0.40.0 (the lock) carries SQLite 3.53.4 with `ENABLE_FTS3`,
`ENABLE_FTS4` and `ENABLE_FTS5` in `PRAGMA compile_options`; a `fts5(content, tokenize = 'porter unicode61')`
table creates, `snippet()` and `bm25()` answer. Whether the same holds in the Burrito binary is slice 100's
question, as SLICE.md's risk line says; this is the development and gate build.

**Porter does not reach "ran".** In that table, `MATCH 'running'` returns "running late" and "it runs" (porter
stems both to `run`) and not "we ran the tests": an irregular past tense is not a suffix, and no stemmer maps it.
`MATCH 'ran'` finds "ran" alone. AC2 says "running" finds "ran"/"runs": the test proves "runs" and asserts that
"ran" is not found, stating the tokenizer's limit rather than claiming it away. On Postgres, `to_tsvector('english')`
(Snowball) stems the same way, and the test documents it the same way. Deviation (a), stated before code.

## G1 plan, 2026-09-20

Tree at `d9ee12d` on `main` (024 approved, M2 reached); branch `slice/031-session-search-fts`; ROADMAP row 031
to `in_progress` in this commit. Each line names its test.

1. Migration `create_messages_fts`: on SQLite (branching on `repo().__adapter__()`), the virtual table
   `messages_fts(content, session_id UNINDEXED, message_id UNINDEXED, tokenize = 'porter unicode61')` and the
   three triggers (insert, update of `content`, delete) on `messages`, plus a backfill of the rows present; on
   Postgres, a generated `content_tsv tsvector` column on `messages` (`to_tsvector('english', coalesce(content,
   ''))`) with a GIN index. Test on both adapters (the postgres job): a message inserted through the Store is
   found at once (AC1); an updated content is re-found; a deleted one is gone.
2. `Trinity.Memory.Search.messages(query, opts)`: SQLite through `MATCH` with `bm25()` order and `snippet()`;
   Postgres through `plainto_tsquery` with `ts_rank` and `ts_headline`; hits as `%{message_id, session_id,
   session_title, seq, role, snippet, inserted_at, rank}`; options `limit:` (20, capped at 100), `role:`,
   `persona_id:`, `since:`, `until:`. The query text is bound as a parameter and never spliced; FTS5 syntax
   characters are quoted so a user's `"` or `*` is text, not an operator. Tests: stemming (AC2, both halves),
   filters, the empty query, an injection-shaped query.
3. `mix trinity.search.reindex` (SQLite: `INSERT INTO messages_fts(messages_fts) VALUES('rebuild')` after a
   delete-all and a refill from `messages`; Postgres: a no-op that says the column is generated) and
   `Trinity.Memory.Search.reindex/0` behind it. Test AC3: 10,000 generated messages, the incremental index's hit
   counts for ten queries equal the rebuilt index's; the time printed.
4. Tool `Trinity.Tools.SessionSearch` (`session_search`, risk `:read`, effect `:none`, schema `query` and
   `limit`), registered in `config :trinity, :tools` for every environment; the result is the hits as text the
   model reads (`session`, `when`, `snippet`), capped by `limit`. Test: the tool through the runner returns at
   most `limit` hits with snippets and is receipted as a read.
5. `/search` LiveView: a query box, results with the session title, the time, the role and the snippet, each
   linking to `/s/:id#message-<id>` (the chat's stream dom ids are `message-<id>`; SLICE.md's `#m-<seq>` is
   read as that anchor, deviation (b)); the chat's bar and the index page link to it. LiveView test.
6. docs/05 synced (the table as built), docs/01's Memory row mentions Search.

Manual verification queue (two items, for the owner at G4):
- **AC4**: the tool returns at most `limit` hits with snippets, and the agent answers "what did we decide about
  X last week" using it. I record a GIF under `proof/` from a real-provider run through
  `scripts/dev_chat_on_test_registry.sh`; the owner watches it.
- **AC5**: the search page renders results and deep-links. A screenshot under `proof/` from the same run; the
  owner opens the page.

Deviations stated before any code: (a) AC2's "ran" is asserted as not found, with the reason (above); (b) the
deep link anchors on the chat's existing dom id `message-<id>` rather than a new `m-<seq>`; (c) reindex on
Postgres is a documented no-op, because a generated column cannot be stale.

## Findings, 2026-09-20

1. **The type checker knows the adapter.** `Trinity.Repo.__adapter__()` is a compile-time constant, so a
   `case` over it is a "clause will never match" warning under `--warnings-as-errors`; the two databases'
   query shapes are compiled in with `if @adapter == ...` around the definitions, which is also the truth: the
   adapter is chosen at compile time (slice 010). The test's count helper reads the adapter from the application
   environment at run time for the same reason.
2. **Schemaless selects do not cast.** `inserted_at` came back as text on SQLite and `Calendar.strftime/2`
   refused it; the select casts it with `type/2`, as the ids are cast through `Trinity.UUID`.
3. **Tools now depends on Memory.** The `session_search` tool reads `Trinity.Memory.Search`; the boundary edge
   is new and one-way (Memory never depends on Tools), and docs/01's row says so.
4. **`~s(...)` cannot hold an unbalanced parenthesis**; the operator-shaped test query uses `~s|...|`.
5. **Ranking on short rows**: bm25 put this week's question above last week's answer for "launch date" on the
   screenshot; both are hits, and the page says which session each is. Ranking is not a criterion of this slice.
6. **The real-provider run** for AC4 went through `nvidia:nemotron` (the session's model, set at seed) with the
   owner's `.env`, on the dev database, the dev server on port 4031 through a wrapper script; the model called
   `session_search` unprompted beyond the question naming it, and answered from the hit. Killing the server by
   `pkill -f phx.server` took the shell with it (exit 144), as the 013 notes warned; kill by pid.
7. **AC3's time**: 32 ms and 46 ms for 10,000 rows on SQLite here (two runs; `optimize` included); 0 ms on
   Postgres because there is nothing to rebuild (a generated column), which the task and the test both say.

## Follow-ups
- 032 (semantic search) fuses with this index; the `rank` field is bm25's on SQLite and `ts_rank` on Postgres,
  not comparable across adapters, and 032 should normalise before fusing.
- The search page shows a scope of hits wholesale; a filter row (role, persona, dates) is a small addition when
  the persona slice (030) gives it something to filter by.
- The receipts page's "open the covered range" follow-up from 024 can reuse the deep link shape (`#message-<id>`).
