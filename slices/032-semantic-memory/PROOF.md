# Proof for slice 032: Embeddings, semantic memory, hybrid retrieval

Agent: Trinity · Coding Agent · Date: 2026-09-21 · Branch: slice/032-semantic-memory · Final commit: (the commit carrying this file; named in the closing correction)

## Summary
Local embeddings (all-MiniLM-L6-v2 through Bumblebee and EXLA, an explicit download, never a hosted fallback:
the owner's G0 decisions in NOTES.md), the vector on the memories row with the embedder that produced it,
brute-force search on SQLite (an EXLA product when the NIF is loaded, Elixir when not) and pgvector's HNSW on
Postgres, an observer that fills the semantic tier after each turn with a 0.92 dedupe, a retriever fusing
vector and full-text hits by reciprocal rank with recency decay and a cosine floor, the "Relevant memories"
block in the volatile tier under its own cap, a `recall` tool, and the memory page's Semantic tab. The first
live run found two defects older than the slice (a whitespace-only assistant row lost, the req_llm tool-call
encoding), both closed red-then-fix; the packaged binary showed that EXLA's NIF does not load in Burrito's
Linux ERTS, so exla is started on demand and the Linux bundle boots with the tier off and says why (AC7's
fallback clause). Sixteen findings and five follow-ups in NOTES.md.

## Gate
```
$ mix gate                                   (this machine, OTP 28.5.0.5, Elixir 1.20.4, under a 32 GiB cgroup, tree 732238c)
1841 mods/funs, found no issues.
... SCAN COMPLETE ...
No retired or security advisory packages found
No vulnerabilities found.
Result: 408 passed, 18 excluded
plan_check: PASS
exit=0
```
The Postgres leg on this machine, against `pgvector/pgvector:pg17` (pgvector 0.8.6) in a container, tree
732238c:
```
$ TRINITY_DB=postgres DATABASE_URL=postgres://trinity:trinity@localhost:5433/trinity_test MIX_ENV=test mix ecto.reset && mix test --exclude sqlite
AC1 store in force: Trinity.Memory.VectorStores.Pgvector
Result: 388 passed, 38 excluded
exit=0
```
CI: named in the closing correction (the run on the final tree). The runs along the way and what each
taught are in NOTES.md findings 2, 3, 5 and 10.

## Tests
```
$ mix test --cover                           (tree 732238c)
Result: 408 passed, 18 excluded
|      0.00% | Trinity.Memory.VectorStores.Pgvector   |   (the postgres job's; 0 on SQLite by construction)
|     30.77% | Trinity.Memory.Embedders.Hosted        |   (opt-in only; its embed path needs a provider)
|     46.51% | Trinity.Memory.Embedders.Bumblebee     |   (the serving and the download run under :local_model, below)
|     61.11% | Trinity.Memory.Supervisor              |
|     70.27% | Trinity.Smoke                          |
|     80.00% | TrinityWeb.MemoryLive                  |
|     85.42% | Trinity.Memory.Observer                |
|     87.18% | Trinity.Memory.Semantic                |
|    100.00% | Trinity.Memory.Embedder                |
|    100.00% | Trinity.Memory.Embedders.Fake          |
|    100.00% | Trinity.Memory.Retriever               |
|    100.00% | Trinity.Memory.VectorStore             |
|    100.00% | Trinity.Memory.VectorStores.Brute      |
|    100.00% | Trinity.Tools.Recall                   |
|     79.01% | Total                                  |
```
`coverage.tsv` row: `032  79.01  732238c  2026-09-21` (from 78.83 at 034).

The slice's tests by name (`mix test <the slice's files> --trace`, 89 passed, 1 excluded: the `:local_model`
one, run separately under AC2):
```
test/trinity/memory/vector_store_test.exs
  * test AC1: 1,000 vectors, search/3 returns the known nearest with correct ordering (555.3ms)
  * test the scope filter is required and binds: a row outside the named scopes is never a hit (M6)
  * test another persona's rows are not hits
  * test vectors of another model are never mixed in (decision 4)
  * test delete/1 clears the vector and the row stays; upsert on a missing row is an error
  * test the row records the embedder that produced its vector, float32 little-endian
  * test Semantic.smoke/0 (the packaged binary's vector check) passes on the store in force and leaves nothing behind
  * test the EXLA product and the Elixir cosine agree, and a row of another width scores 0.0 on both
test/trinity/memory/embedder_test.exs
  * test the fake is deterministic, unit length, 384 wide, and unrelated texts are near orthogonal
  * test #near: texts land above the dedupe threshold, plain texts do not
  * test to_binary/from_binary round-trip float32
  * test the suite runs on the fake and the tier is on
  * test with the local embedder and no model, the tier is off with :model_missing and never hosted (decision 2)
  * test the hosted embedder serves only when configured, and reports itself off without an embed model
  * test describe/1 names every reason
  * test the supervisor and the serving (G1 line 1) with the local embedder and no model, the supervisor starts without the serving and says why
  * test the supervisor and the serving (G1 line 1) with the fake, the supervisor starts the task supervisor alone and the tier is on
  * test the supervisor and the serving (G1 line 1) AC2: the real embedder through the serving … (excluded: :local_model)
test/trinity/memory/observer_test.exs
  * test AC3: facts from a scripted turn become semantic rows with provenance, confidence and a log row; a near-duplicate of an existing memory is dropped
  * test two near-duplicates in one answer keep only the first
  * test the dedupe threshold is configuration
  * test an empty answer inserts nothing; a model error is returned, not raised
  * test off without a persona, off by configuration, off when the tier is off: nothing is sent to any model
  * test a completed session turn hands its messages to the observer, which runs off the session's path
test/trinity/memory/retriever_test.exs
  * test AC4: an FTS-only hit (a past message) and a vector-only hit (a semantic memory) both appear, fused; the current session's own rows do not
  * test AC4: recency decay demotes an old identical memory below the recent one
  * test a memory below the cosine floor is not a hit: a question about nothing recalls nothing
  * test recall runs over the session's scope chain only (M6)
  * test with the tier off, recall is the full-text half alone
  * test AC5 (prompt half): the block sits in the volatile tier after the always-in-mind block and is cut at its own cap, reported as :recall
  * test AC5: a session's turn carries the block for its latest user message; a cut writes the receipt
test/trinity/tools/recall_test.exs
  * test registered as a core read tool in the memory toolset, the catalog untouched
  * test fused hits: the memory by meaning and the message by its words, as untrusted text, with a query receipt
  * test without a persona nothing is recalled; with the tier off the answer says so and carries the full-text half
test/trinity_web/live/semantic_tab_test.exs
  * test the tab lists the tier with the status line, recalls with provenance links, deletes and pins
  * test with the local model missing the tab says the tier is unavailable and offers the download; nothing is downloaded without the click
test/smoke_test.exs
  * test run/2 says whether the markdown renderer rendered, on its own line   (now the five lines)
  * test run/2 exits 4 when the vector search inside the binary fails; a failed EXLA line alone still exits 0
  * test run/2 the EXLA line on this machine (the NIF is compiled and loads here; the bundle's answer is AC7's)
test/trinity/sessions/session_test.exs
  * test the tool path (AC6) a turn whose only text is whitespace before its tool calls still persists its assistant row   (fix(s012), red first: 31a793b)
test/trinity/llm/mapping_test.exs
  * test the request's assistant tool calls reach req_llm's context as ToolCall structs with their ids   (fix(s011), red first: f6fc944)
test/trinity/receipts/chain_writer_test.exs
  * test AC5 at the writer: the key removed mid-run, the next signed receipt is refused, the alarm sounds, no row is written   (its tail: the alarm clears when the signer signs again)   (fix(s024) ab07781, red first: eda618f)
```

## Acceptance criteria evidence

### AC1 [auto]: Fake-embedder test: upsert 1,000 vectors, `search/3` returns the known nearest with correct ordering on SQLite and Postgres
`test/trinity/memory/vector_store_test.exs` "AC1: 1,000 vectors, search/3 returns the known nearest with
correct ordering": 1,000 semantic rows through `Semantic.add/2` with the fake's 384-wide deterministic
vectors, the expected order computed in the test by the same cosine, the store's top 10 equal to it by id and
by score (1.0e-5), the top hit the query's own text at cosine 1.0. The test prints the store in force:
```
$ mix test test/trinity/memory/vector_store_test.exs                       (SQLite, tree 732238c)
AC1 store in force: Trinity.Memory.VectorStores.Brute
Result: 8 passed

$ TRINITY_DB=postgres DATABASE_URL=… MIX_ENV=test mix test --exclude sqlite test/trinity/memory/vector_store_test.exs
AC1 store in force: Trinity.Memory.VectorStores.Pgvector
Result: 8 passed
```
On Postgres the fake's width (384) is the column's, so the `vector(384)` column and the HNSW index are what
answer (NOTES finding 6), with pgvector 0.8's iterative scan so a filtered query is never short (NOTES
finding 12, `fix(s032)` de55660). The same file holds the M6 scope filter, the other-persona and
other-model exclusions (decision 4), delete, and the float32 round trip.

### AC2 [manual]: Real Bumblebee embedder: `dim/0 == 384`; embedding "the cat sat" vs "a cat was sitting" cosine > 0.7; vs "quarterly tax filing" < 0.3
Measured at G1 with `scripts/embed_bench.exs` (NOTES.md, the local table: dim 384, 0.858, 0.062) and, at G3,
through the serving under `Trinity.Memory.Supervisor` by the `:local_model` test, on this machine:
```
$ TRINITY_LOCAL_MODEL_CACHE=<cache holding the model> mix test test/trinity/memory/embedder_test.exs --only local_model
AC2 on this machine: dim=384 cosine(related)=0.858 cosine(unrelated)=0.062 three embeds in 281 ms
Result: 1 passed, 9 excluded
```
For the owner: `TRINITY_LOCAL_MODEL_CACHE` names a cache that already holds all-MiniLM-L6-v2 (the memory
page's download puts it under `<data dir>/models`); the test asserts the three numbers and downloads nothing.
`scripts/embed_bench.exs` prints the fuller table.

### AC3 [auto]: Observer extracts memories from a scripted turn (FakeProvider returns facts) and dedupes a near-duplicate
`test/trinity/memory/observer_test.exs` "AC3: facts from a scripted turn…": the fake provider's object
answers three memories; the near-duplicate of a planted memory (`#near:coffee`, cosine over 0.92) is dropped,
the blank one is dropped, the fact is inserted as a `semantic` row with the persona scope, the assistant
message as provenance, confidence 0.8, the key `writes-elixir-<6 hex>`, the model id, and one `add` row in the
change log `by: "observer"`; the same wording again meets `:exists`, another wording of the same fact meets
the dedupe. Two near-duplicates in one answer keep the first; the threshold is configuration; an empty answer
inserts nothing; a model error is returned; off without a persona, off by configuration, off when the tier
is off. "a completed session turn hands its messages to the observer" drives a turn through a Session with
the fake and finds the row with the session id in its log entry.

### AC4 [auto]: Retriever: FTS-only hit and vector-only hit both appear in fused results; recency decay demoted an old identical memory
`test/trinity/memory/retriever_test.exs`: a past message (found by 031's full-text search, `found_by:
[:fts]`) and a semantic memory (found by the vector search, `[:vector]`) both in the fused list at `rrf(1)`,
the current session's own rows left out, the memory hit marked used; two memories with the same body, the one
last used 90 days ago below the one used now (`decay/2`: 1.0 now, 0.75 at 30 days, 0.5625 at 90, never under
0.5); recall over the session's scope chain only (M6); the tier off leaves the full-text half working; a
question about nothing recalls nothing (the cosine floor, NOTES finding 7).

### AC5 [auto]: Prompt contains a "Relevant memories" block bounded by the token cap (prompt snapshot test)
`test/trinity/memory/retriever_test.exs` "AC5 (prompt half)": the block sits after the always-in-mind block
and before the time line; a 200-line block is cut at `recall_tokens` (600) on a line boundary with the 030
marker, reported as `%{tier: :recall, dropped_tokens: n}`, and the kept part estimates under the cap. "AC5: a
session's turn carries the block…": through a Session, the fake's last request carries `## Relevant memories`
with the memory and the past message; with the cap at 45 tokens the cut writes the query receipt
`prompt:<session>:recall` with `dropped_tokens > 0`.

### AC6 [manual]: `recall` tool works end-to-end (manual GIF: teach a fact in one session, recall it in a new one)
`proof/ac6-recall.gif` (six frames, 3 s each; the stills beside it), the dev server on this machine with
`nvidia:nemotron` and the real local embedder, 2026-09-21 08:46 to 08:57 local:
1. `ac6-1-unavailable.png`: `/memory?tab=semantic` before the model is on disk: "semantic recall is
   unavailable: the local model is not downloaded. Full-text search still works." and the download button.
2. `ac6-2-downloading.png`: the explicit download with its progress (91 of 91 MB); `ac6-2b-model-on.png`: the
   flash and the status "semantic recall is on (bumblebee:sentence-transformers/all-MiniLM-L6-v2)".
3. `ac6-3-taught.png`: a new session, "Two things to remember: my dog is called Rex, and I moved to Lisbon
   last spring." The model called the `memory` tool twice on its own and answered.
4. `ac6-4-remembered.png`: the Semantic tab holds what the observer extracted from that turn: "The person moved
   to Lisbon last spring." and "The person's dog is called Rex." at confidence 0.95, each with its `source`
   link, and the change log with the observer's two `add` rows beside the tool's.
5. `ac6-5-recalled.png`: a new session, "What is my dog's name, and which city do I live in? Use the recall
   tool." Two `recall` calls (`dog name and city I live in`, `city I live in Lisbon`), each answered from the
   semantic tier, then "Your dog's name is **Rex**, and you live in **Lisbon** (you moved there last spring)."
The automatic half: `test/trinity/tools/recall_test.exs` (the tool through the runner in force, a read with a
query receipt, the tier-off wording). The run's first attempt found the two older defects in NOTES finding 1;
the GIF is from the run after both fixes.

### AC7 [auto]: Packaged Burrito binary loads `sqlite_vec` and passes a vec smoke test (log), or R4 fallback implemented and documented
The fallback clause is the one met (NOTES decision 1: no `sqlite_vec`, no loadable extension). The `--smoke`
path prints three more lines (`Trinity.Smoke`, `Trinity.Smoke.Probe`): a fake-vector search inside the binary
through the store in force, rolled back (binding, exit 4 on failure), whether the EXLA NIF loaded and ran,
and the tier's status. Package run 35604769356 (workflow_dispatch on this branch at a8fa7e9), all three jobs
green, from the jobs' logs:
```
linux x86_64:   TRINITY_SMOKE_PORT=44831
                TRINITY_SMOKE_MARKDOWN=ok
                TRINITY_SMOKE_EXLA=failed:{:error, {:exla, "{:shutdown, {:failed_to_start_child, EXLA.Logger, {:undef, [{EXLA.NIF, :start_log_sink, …
                TRINITY_SMOKE_VEC=ok:Trinity.Memory.VectorStores.Brute
                TRINITY_SMOKE_SEMANTIC=off:{:error, {:exla, "{:shutdown, …
macOS aarch64:  TRINITY_SMOKE_PORT=49653
                TRINITY_SMOKE_MARKDOWN=ok
                TRINITY_SMOKE_EXLA=ok
                TRINITY_SMOKE_VEC=ok:Trinity.Memory.VectorStores.Brute
                TRINITY_SMOKE_SEMANTIC=off::model_missing
windows x86_64: TRINITY_SMOKE_PORT=63536
                TRINITY_SMOKE_MARKDOWN=ok
                TRINITY_SMOKE_EXLA=failed:{:error, {:exla, "~c\"no such file or directory\""}}
                TRINITY_SMOKE_VEC=ok:Trinity.Memory.VectorStores.Brute
                TRINITY_SMOKE_SEMANTIC=off::no_local_backend
```
The vector search passes in all three bundles. The EXLA NIF loads in the macOS bundle and not in the Linux one
(Burrito's musl ERTS against a glibc `.so`: NOTES finding 2, a follow-up for a Linux backend), and a Windows
host does not declare exla; the two bundles boot with the tier off and say why. The commit after that run
(732238c) unwraps the reason to `{:exla, "the EXLA NIF did not load (EXLA.NIF.start_log_sink undefined)"}`;
the run on the final tree is named in the closing correction. The earlier runs 35600216451 (the probe before
the Repo; the Linux release crashing at boot) and 35603384655 (Mix refusing `exla: :load`) are the record of
how the design got here.

### AC8 [auto]: Perf table recorded (latency, binary size delta, RAM)
`docs/perf.md`: embedding latency (single 86.4 ms p50, batch of 32 at 2.71 ms per item, load 650 ms, first
embed 318 ms), RAM (587 MB RSS in the bench, 954,680 kB RSS for the dev server with the model loaded after the
AC6 run, peak 1,292,456 kB), binary size (XLA 463 MB on disk; the bundles +68.7 MB Linux, +45.4 MB macOS,
+2.1 MB Windows against slice 034's artifacts), the EXLA compile on the gate's three legs (41 s, 44 s, 70 s),
and vector search over 1,000 and 10,000 rows on both stores (`scripts/vector_bench.exs`).

## Manual verification for the reviewer
- **AC2**: on a machine with the model on disk, `TRINITY_LOCAL_MODEL_CACHE=<cache> mix test --only local_model`
  prints the three numbers; or `scripts/embed_bench.exs` for the fuller table. Expected: dim 384, the related
  pair over 0.7, the unrelated under 0.3.
- **AC6**: watch `proof/ac6-recall.gif`; or run the dev server with a real model, open `/memory?tab=semantic`,
  download the model, teach a fact in one session, ask for it in a new one with "use the recall tool".

## Deviations from SLICE.md
NOTES.md, the four stated before code (no `sqlite_vec`; the hosted embedder opt-in only; the download an
explicit action; the embedder recorded on the row), and three found building: exla declared `runtime: false`
and started on demand (finding 2), the fake embedder 384 wide (finding 6), a cosine floor on recall (finding
7). Three fixes outside the slice's scope, each red-then-fix, because this slice's runs met them: `fix(s012)`
and `fix(s011)` (finding 1, the first live run) and `fix(s024)` (finding 13, the fips leg). Two test flakes
closed at their source (finding 10).

## Versions touched
`VERSIONS.md` updated: yes (nx, exla, bumblebee, pgvector rows now locked and ✅; sqlite_vec recorded as not
used; hnswlib repinned to 0.1.10, still not a dependency). `mix versions.verify`: OK, 102 locked packages,
none disagreeing with 51 pins.

## Git
```
$ git log --oneline main..HEAD
(named in the closing correction, after the final commit)
```

## Closing correction, 2026-09-21

Supersedes "named in the closing correction" above. The tree the PR is merged from is `193800e`
(`fix(s032): the test pools queue instead of shedding under the stress tests`), three commits after the
`feat(s032): complete slice 032` commit `a954393` that carried this file first: `ab07781`'s successor
commits closed the smoke argument's race (finding 15) and the test pools' shedding (finding 14) after
the runs named there. On `193800e`:

- CI gate run 35612151947 (push) and 35612156858 (pull request): `gate` success (409 passed, 18
  excluded), `postgres` success (389 passed, 38 excluded), `fips-tag` and `fips` success (414 passed,
  13 excluded; the six FIPS tests by name).
- Package run 35610163163 on `a82bd4c` (the commit before, which differs from `193800e` only in
  `config/test.exs` and the two slice files): all three jobs green, the smoke lines as AC7 lists them
  with the Linux reason now `{:exla, "the EXLA NIF did not load (EXLA.NIF.start_log_sink undefined)"}`
  and the run asked for by `TRINITY_SMOKE=1`. Artifacts: `desktop_linux_x86_64` 92,556,709 bytes,
  `desktop_windows_x86_64.exe` 29,639,041 bytes, `desktop_macos_aarch64` (its job green; the size in
  docs/perf.md is run 35604769356's, 60,544,615).
- Coverage on `193800e`: `mix test --cover` prints `Result: 409 passed, 18 excluded` and `78.99% |
  Total` (two hundredths under 732238c's 79.01: the smoke module gained the variable branch and the
  chain writer its two clears). The `coverage.tsv` row is corrected to `032  78.99  193800e  2026-09-21`
  in the commit carrying this correction; the 732238c row above is superseded, not rewritten here.

```
$ git log --oneline main..HEAD
193800e fix(s032): the test pools queue instead of shedding under the stress tests
a82bd4c fix(s032): the smoke run asked for by TRINITY_SMOKE=1, so Kernel.CLI has no argument to mistake for a file
a954393 feat(s032): complete slice 032 (semantic memory and hybrid retrieval)
ab07781 fix(s024): a signer that signs again clears the signer alarm
eda618f test(s024): red: the signer alarm is not cleared when a signer signs again
732238c feat(s032): the exla reason unwrapped and summarised to the NIF's undef; package sizes in docs/perf.md
d9b2686 test(s032): the scoring-agreement test starts exla on demand like the store does
de55660 fix(s032): pgvector searches with an iterative HNSW scan so a filtered query is never short
53cb840 docs(s032): G3 findings and follow-ups in NOTES; the exla row says how it is carried
a8fa7e9 feat(s032): exla declared runtime: false so the release can carry it in :load mode
fa019cf test(s032): two flakes met on run 35603385277 closed at their source
372e05d test(s032): the supervisor's reason line is captured at info
352f55f test(s032): the supervisor without and with the serving; AC2 automated where the model is on disk (local_model tag)
8cfac84 docs(s032): docs/perf.md and scripts/vector_bench.exs; the AC6 proof shots
8bf06fb feat(s032): exla loaded on demand in the release, the smoke probe after the tree, EXLA scoring in the brute store
4f47964 fix(s011): encode assistant tool calls for req_llm as maps with name and arguments
f6fc944 test(s011): red: the adapter hands req_llm a tool-call tuple it refuses
87a8f53 fix(s012): persist the assistant row when its text is whitespace only
31a793b test(s012): red: a whitespace-only assistant text before tool calls loses the assistant row
062cb12 feat(s032): the smoke path reports EXLA, a vector search in the binary, and the tier's status; exla declared on Linux and macOS hosts only
6a6d5cf feat(s032): semantic memory: embedder, vector stores, observer, hybrid retriever, recall tool, memory page tab
e7b0c28 docs(s032): the owner's decisions at G0, the embedders and the vector store measured, the G1 plan, and the slice opens
```
