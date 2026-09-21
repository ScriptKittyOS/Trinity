# Proof for slice 031: Session search (FTS5)

Agent: Trinity · Coding Agent · Date: 2026-09-20 · Branch: slice/031-session-search-fts · Final commit: (the commit carrying this file; named in the closing correction)

## Summary
Full-text search over every message: an FTS5 table with porter stemming kept by triggers on SQLite, a generated
`tsvector` column with a GIN index on Postgres, one `Trinity.Memory.Search.messages/2` over both with the query
bound as a parameter and FTS5 terms quoted, a reindex task, the `session_search` core read tool, and the `/search`
page whose hits deep-link into the session at the message. AC2's "ran" half is asserted as not found, because
no stemmer maps an irregular past tense (NOTES.md, fact 2). The real-provider run for AC4 went through
`nvidia:nemotron`, which called the tool and answered from last week's session; the GIF and the screenshots are
in `proof/`.

## Gate
```
$ mix gate                                   (this machine, OTP 28.5.0.5, Elixir 1.20.4, under a 32 GiB cgroup, tree 866dc3f)
1450 mods/funs, found no issues.
... SCAN COMPLETE ...
No retired or security advisory packages found
No vulnerabilities found.
Result: 326 passed, 17 excluded
trinity.coverage: 024 76.55% vs 003 75.39%: OK
plan_check: PASS
exit=0
```
CI, run 35545182679 on the tree at 866dc3f: `gate` success (326 passed, 17 excluded), `postgres` success
(318 passed, 25 excluded; the search tests included, `AC3: reindex of 10000 messages: generated_column, 0 ms`),
`fips-tag` and `fips` success.

## Tests
```
$ mix test --cover                           (tree 866dc3f)
Result: 326 passed, 17 excluded
|    100.00% | Trinity.Memory.Search                  |
|    100.00% | Trinity.Tools.SessionSearch            |
|     94.87% | TrinityWeb.SearchLive                  |
|     76.96% | Total                                  |
```
`coverage.tsv` row: `031  76.96  866dc3f  2026-09-20` (from 76.55 at 024).

The slice's nine tests (`--trace`):
```
* test a query in the URL renders its hits, marked, linking to the session at the message [L#20]
  * test a query in the URL renders its hits, marked, linking to the session at the message (82.9ms) [L#20]
  * test submitting the form patches the URL and searches; nothing matching says so (5.8ms) [L#33]
  * test the index and the chat link to the search page (18.2ms) [L#41]
  * test registered as a core read tool with the catalog untouched (1.6ms) [L#30]
  * test returns at most limit hits with snippets, names the session, and runs as a read with a query receipt (14.1ms) [L#38]
  * test AC1: a message is searchable the moment it is inserted; updated content is re-found; a deleted one is gone (2.5ms) [L#26]

  * test AC3: reindex over 10,000 messages yields the same hit counts as the incremental index, and the time is printed (176.0ms) [L#99]
  * test AC2: stemming: 'running' finds 'runs' (a suffix) and not 'ran' (irregular, no stemmer maps it) (1.8ms) [L#56]
  * test filters: role, persona, since and until; limit capped; empty and operator-shaped queries (2.7ms) [L#71]
Result: 9 passed
```

## Acceptance criteria evidence

### AC1 [auto]: inserting a message makes it searchable immediately (trigger) on SQLite and Postgres (tests)
`AC1: a message is searchable the moment it is inserted; updated content is re-found; a deleted one is gone`
(test/trinity/memory/search_test.exs), through `Trinity.Sessions.append_message/2` with no reindex between the
insert and the search; the same file on the postgres job (run 35545182679), where the generated column does
the same work.

### AC2 [auto]: query with stemming: "running" finds "ran"/"runs" via porter on SQLite; documented behaviour on Postgres (test)
`AC2: stemming: 'running' finds 'runs' (a suffix) and not 'ran' (irregular, no stemmer maps it)`: measured
before code (NOTES.md, fact 2) and asserted as measured on both adapters: `running` returns the "runs" and
"running" rows and not "ran"; `ran` returns "ran". The criterion's "ran" is a claim porter (and Snowball on
Postgres) cannot meet, stated rather than claimed away: deviation (a).

### AC3 [auto]: `reindex` on a DB with 10k messages completes and yields identical hit counts to the incremental index (test with generated data; time recorded)
`AC3: reindex over 10,000 messages yields the same hit counts as the incremental index, and the time is printed`:
10,000 generated rows through `insert_all` (so the triggers index them), ten queries counted over the index
before and after `Search.reindex/0`, equal. Time printed by the test: `rebuilt, 32 ms` and `46 ms` on two runs
here; `generated_column, 0 ms` on the postgres job (nothing to rebuild). `mix trinity.search.reindex` prints the
same line.

### AC4 [manual]: tool returns ≤ `limit` hits with snippets; agent can answer "what did we decide about X last week" using it (manual GIF)
Automatic half: `returns at most limit hits with snippets, names the session, and runs as a read with a query
receipt` (test/trinity/tools/session_search_test.exs): `limit: 3` gives three lines, each naming last week's
session and carrying `[friday]`; `hits` and `limit` in the meta; the decision and query receipts; the no-hit
text; a limit past the schema refused. Manual half, recorded for the owner: `proof/ac4-session-search.gif` (64
frames at four a second, 827 KB) and `proof/ac4-answer.png`: the dev server on `nvidia:nemotron` with the
owner's keys, a session seeded a week earlier with "We decided: the launch date is October 21st", a new session
asked "What did we decide about the launch date last week? Use session_search."; the model called
`session_search` (the tool row, `ok`) and answered "Last week the team agreed to set the Trinity 1.0 release
launch date for October 21st." The owner watches the GIF.

### AC5 [manual]: search page renders results and deep-links (screenshot)
Automatic half (test/trinity_web/live/search_live_test.exs): `a query in the URL renders its hits, marked,
linking to the session at the message` (`<mark>decided</mark>`, `href="/s/<id>#message-<id>"`), `submitting the
form patches the URL and searches; nothing matching says so`, `the index and the chat link to the search page`.
Manual half: `proof/ac5-search.png` (`/search?q=launch date`: five hits across two sessions, the words marked,
each hit naming its session, time, role and seq) and `proof/ac5-deeplink.png` (the "Launch planning" hit
followed: the older session opens at the message). The owner opens the page.

## Manual verification for the reviewer
- AC4: open `proof/ac4-session-search.gif`; or run `set -a; . ./.env; set +a; PORT=4031 mix phx.server` and ask a
  new session what was decided about the launch date last week.
- AC5: open `proof/ac5-search.png` and `proof/ac5-deeplink.png`; or open `/search?q=launch date` on the same server.

## Deviations from SLICE.md
(a) AC2's "ran" is asserted as not found, with the reason; (b) the deep link anchors on the chat's dom id
`message-<id>` rather than a new `m-<seq>`; (c) reindex on Postgres is a documented no-op. All three stated in
NOTES.md before code. Found during the build: the Tools boundary gains Memory (NOTES finding 3, docs/01 as built).

## Versions touched
`VERSIONS.md` updated: no. No dependency changed; FTS5 is in the locked exqlite's SQLite (NOTES.md, fact 1).

## Git
```
$ git log --oneline main..HEAD
866dc3f feat(s031): session_search in a memory toolset; the registry test lists it
cd3d952 feat(s031): the /search page with deep links into sessions; docs/05 as built
b8e6704 feat(s031): the session_search tool, a core read; Tools may depend on Memory
24dfa2a feat(s031): the FTS5 table and triggers (tsvector on Postgres), Trinity.Memory.Search, the reindex task
602d6ee docs(s031): G1 plan with FTS5 and the porter limit measured, and the slice opens
```

## Closing correction, 2026-09-20
Supersedes the header's "Final commit" placeholder: the closing commit is `d642688` (`feat(s031): complete
slice 031 (session search, FTS5)`), and this correction rides on the commit after it.
