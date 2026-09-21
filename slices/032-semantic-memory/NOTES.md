# Slice 032: NOTES

## Decisions before code (the owner, 2026-09-21, at G0)

SLICE.md leaves R3 and R4 to this slice and VERSIONS.md says to decide the vector store's fallback before it
starts. Measured facts (below) were put to the owner; the decisions, verbatim in substance:

1. **Vector store: brute force in Elixir, and pgvector on the Postgres job.** `sqlite_vec` is out: its only
   release (0.1.0, 2024-11-19, 7,325 downloads) requires `nx ~> 0.9` and cannot sit in a tree with a current
   Nx. Vectors are a column on `memories`, cosine search runs in Elixir over the persona's semantic rows
   (docs/02's own statement: fine to about 10^5), `Pgvector` serves the Postgres job, and `hnswlib` (0.1.10,
   2026-09-17, active) is the scale option when a slice needs it. AC7's clause "or R4 fallback implemented and
   documented" is the one this slice meets; there is no loadable extension for Burrito to break.
2. **Embedder: local first, hosted never automatic.** The default is all-MiniLM-L6-v2 through Bumblebee and
   EXLA on Linux and macOS. The hosted embedder (`nvidia:embed`) is a configured alternative only
   (`config :trinity, :memory, embedder: :hosted`) and is never the silent fallback when the model is missing,
   the download fails, or the OS is Windows.
3. **When local cannot run, semantic memory is off**, not "send the memories to the cloud": full-text search
   (031) still works, the observer and the retriever stand down, and the UI says semantic recall is
   unavailable, not broken. Windows and machines whose download failed get that mode until a local Windows
   backend exists (ONNX or similar, a later slice; 032 is not blocked on it).
4. **Every vector records which embedder produced it** (`embedding_model`, the dimension), and the store never
   mixes models: a search runs only over vectors of the embedder in force, and a change of embedder is a
   re-embed, never a silent blend.
5. **No memory text, session text or persona text goes to a hosted embed API unless the operator opted in.**
   That is the DoD/healthcare posture, and it holds for the observer's extraction call too (which goes to the
   session's own model, the one the operator already chose for the conversation).

## Measured 2026-09-21 before any code

**The dependency line.** bumblebee 0.7.1 (2026-07-22) accepts `nx ~> 0.12 or ~> 0.13`; nx and exla 1.0.0
shipped 2026-09-10 and bumblebee has no release for them, so the tree takes nx 0.13.1, exla 0.13.1, xla 0.10.0,
axon 0.8.1, tokenizers 0.5.1 (a Rust NIF, precompiled), pgvector 0.4.1. `fine` (exla's NIF helper) bakes its
include path at compile time and had been compiled at the repository's old location; `mix deps.compile fine
--force` fixed the first build.

**Local embeddings** (this machine: AMD Ryzen AI MAX+ 395, CPU only through EXLA's host client), all-MiniLM-L6-v2,
sequence length 128, batch size 32, mean pooling, L2-normalised:

| measure | value |
|---|---|
| model download | 91,359,935 bytes (one entry in the cache) |
| load | 650 ms; first embed (compilation) 318 ms |
| single embed | 86.4 ms p50, 90.9 ms max over 20 |
| batch of 32 | 86 ms, 2.71 ms per item |
| dimension | 384 |
| cosine("the cat sat", "a cat was sitting") | 0.858 (AC2 asks > 0.7) |
| cosine("the cat sat", "quarterly tax filing") | 0.062 (AC2 asks < 0.3) |
| VM total / process RSS while embedding | 101 MB / 587 MB |
| XLA shared library on disk | 463,283,344 bytes (the bundle's cost); 106,037,350 gzip-compressed; the archive 144,319,267 |
| EXLA NIF / tokenizer NIF | 659,856 bytes / 6.9 MB |
| precompiled XLA targets | x86_64 and aarch64 linux, x86_64 and aarch64 darwin; none for Windows |
| without EXLA (Nx.BinaryBackend) | 15 s first, 23 s per sentence: unusable |

**Hosted embeddings** (`nvidia:embed`, nemotron-3-embed-1b through req_llm, the owner's key, live):

| measure | value |
|---|---|
| dimension | 2048 |
| single embed | 208 ms p50, 314 ms max over 5 (network) |
| batch of 32 | 627 ms |
| cosine("the cat sat", "a cat was sitting") | 0.71 |
| cosine("the cat sat", "quarterly tax filing") | 0.752: the unrelated pair scores as the related one; raw vectors from this model do not separate at the slice's thresholds, and a dedupe at 0.92 would be meaningless; the model's own query/passage prompting would have to be measured before it could serve |

**Archive size** (slice 034's open line): a 384-float vector is 1,536 bytes as float32; 10,000 memories add
15 MB before compression. Measured once vectors exist, at G3.

## G1 plan, 2026-09-21

Tree at `190d206` on `main` (033 and 034 approved); branch `slice/032-semantic-memory`; ROADMAP row 032 to
`in_progress` in this commit. Each line names its test.

1. Deps (above) in mix.exs and VERSIONS.md rows; the EXLA/XLA compile on the gate's three legs (the FIPS leg
   compiles EXLA from source against its own OpenSSL-free toolchain: the C++ compile takes minutes; measured on
   the first push). Test: `Nx.Serving` starts under `Trinity.Memory.Supervisor` when the embedder is local and
   the model is present; otherwise the supervisor starts with the tier off and says why.
2. `Trinity.Memory.Embedder` behaviour (`embed/1`, `dim/0`, `model_id/0`, `available?/0`) with
   `Embedders.Bumblebee` (the serving; model cache under the data directory, `BUMBLEBEE_CACHE_DIR` honoured;
   `offline: true` unless `config :trinity, :memory, model_download: true`, the first-run download an explicit
   action on the memory page with progress), `Embedders.Hosted` (`Trinity.LLM.embed/2` with the configured
   model; only when `embedder: :hosted`), `Embedders.Fake` (deterministic vectors from a text's digest, for the
   suite). `Trinity.Memory.Semantic.status/0`: `:on | {:off, reason}`. Tests: the fake's determinism; the
   status by configuration; the hosted embedder is never selected without the configuration (a test with the
   model absent and `embedder: :local` gets `{:off, :model_missing}`, never hosted).
3. Migration: `memories` gains `embedding` (binary, float32 little-endian, nullable), `embedding_model`
   (string), `embedding_dim` (integer); on Postgres `embedding_vector vector(384)` through pgvector with a
   partial index on `tier = 'semantic'`. `Trinity.Memory.VectorStore` behaviour (`upsert/2`, `search/3`,
   `delete/1`, `count/1`; the scope filter a required argument, M6) with `VectorStores.Brute` (SQLite: the
   persona's semantic rows of the embedder in force loaded and scored in Elixir) and `VectorStores.Pgvector`.
   Test AC1: 1,000 fake vectors, the known nearest in order, on both adapters (the postgres job).
4. `Trinity.Memory.Observer`: after a completed turn the Session hands the turn's rows to a supervised
   `Task` (`Trinity.Memory.TaskSupervisor`) that asks the session's model for 0 to 3 durable facts,
   preferences or decisions (`generate_object/3`, the compactor's shape), embeds them, drops one whose cosine
   to an existing memory of the scope is over 0.92, and inserts the rest as `tier: "semantic"` rows with
   `source_message_id`, `confidence`, the scope chain's persona scope, and the change log. Off when the tier
   is off. Test AC3 with the fake provider's scripted facts and a planted near-duplicate.
5. `Trinity.Memory.Retriever.relevant(persona_id, session_id, query, k)`: FTS hits (031's search over the
   persona's sessions) and vector hits fused by reciprocal rank (k = 60), recency decay (half-life 30 days on
   `last_used_at` or the row's insert), scoped to the session's chain; the block "## Relevant memories" rendered
   into the volatile tier under its own cap (`config :trinity, :memory, recall_tokens: 600`, measured against
   the volatile budget of 030). Tests AC4 (an FTS-only and a vector-only hit both fused; an old identical memory
   demoted) and AC5 (the block in the prompt, cut at the cap with the 030 receipt).
6. The `recall` tool (risk `:read`, effect `:none`, `query`, `k`): the retriever's hits as text; the fake
   test through the runner; the manual GIF for AC6 with the real model on this machine.
7. UI: the memory page gains a "Semantic" tab: search, provenance link to the source message, delete, pin
   (promote to `always_on`, logged), the model download action and the tier's status line. LiveView tests.
8. `docs/perf.md` (new) with the tables above and the gate legs' EXLA compile times; docs/05 (the columns),
   docs/01 (the supervisor as built), VERSIONS.md (the rows, ✅). AC7: the Burrito package run on this branch
   (`package` workflow dispatched) proves the bundle starts with EXLA in it and the vec smoke (a fake-vector
   search inside the binary) passes, or records the failure by name (R4's fallback is the design here, so a
   failure is about EXLA in Burrito, not about an extension).

Manual verification queue (two items, for the owner at G4):
- **AC2**: the real embedder's numbers are in the table above, measured today; the owner may re-run
  `scripts/embed_bench.exs` (added this slice) to see them on their machine.
- **AC6**: the `recall` tool end to end: a fact taught in one session, recalled in a new one, on the real model.
  A GIF under `proof/` from a run on this machine; the owner watches it.

Deviations stated before any code: (a) no `sqlite_vec`, brute force and pgvector instead (decision 1); (b) the
hosted embedder is opt-in only and never a fallback (decision 2), so SLICE.md's "offline fallback = hosted
embedder or disabled semantic tier" is read as "disabled semantic tier"; (c) the model download is an explicit
action, not an automatic first-run download, because a download is a network egress the operator should see
happen (the design note's "first-run download with UI progress" is kept as that action); (d) the embedder that
produced each vector is recorded on the row (decision 4).

## Findings at G3, 2026-09-21

1. **Two defects older than this slice, found by AC6's first live run** (nvidia:nemotron, the dev server,
   the flow in `proof/ac6-recall.gif`). (a) The model streamed one `"\n"` and then its tool calls;
   `validate_required` counts whitespace as blank, so the assistant row with the calls was refused
   ("could not persist the assistant message") and the tool rows followed a call the history never showed.
   Red `test/trinity/sessions/session_test.exs` ("a turn whose only text is whitespace…"), then `fix(s012)`:
   `String.trim` before the `(no text)` substitution. (b) The turn after a tool result raised
   `invalid tool_call: {"call-…", "recall", %{…}}` inside req_llm 1.24.0: the adapter handed
   `ReqLLM.Context.assistant/2` a `{id, name, args}` tuple, and `normalize_tool_call/1` takes `{name, input}`,
   `{name, input, opts}` or a map with `name` and `arguments`. Every live turn after a tool call had failed this
   way since 011; the fake provider builds no context, so the suite never saw it. Red
   `test/trinity/llm/mapping_test.exs` ("the request's assistant tool calls reach req_llm's context…"), then
   `fix(s011)`: maps with `id`, `name`, `arguments`. With both in, the run completed: two `memory` tool calls,
   a final answer, then in a new session two `recall` calls and "Your dog's name is **Rex**, and you live in
   **Lisbon** (you moved there last spring)."
2. **EXLA inside the Burrito bundle.** Package run 35600216451, the first with exla: on Linux the NIF does
   not load in Burrito's musl ERTS (`Error relocating …/libexla.so: __libc_single_threaded: symbol not
   found`, NOTES finding 13 of slice 013's shape), and because exla's application start loads the NIF, the
   whole release failed to boot (exit 1). On macOS the NIF loaded (`TRINITY_SMOKE_EXLA=ok`). On Windows exla
   is not declared (xla ships no Windows archive; `exla_deps/0` in mix.exs). Closed by declaring exla
   `runtime: false` (compiled, on the code path, not in `applications`), carrying it in the release in
   `:load` mode (Mix refuses `:load` while an application depends on it: run 35603384655), and starting it
   on demand in `Trinity.Memory.Embedders.Bumblebee.exla/0`, whose failure is remembered for the run and is
   the tier's reason (`{:off, {:exla, "…"}}`). The Linux bundle therefore boots with the tier off and says
   why; a local backend for the Linux bundle is a follow-up (below), not this slice's.
3. **The smoke probe ran before the Repo.** The 032 smoke lines were first computed in `Smoke.children/1`,
   inside `Application.start/2` before the tree (where the markdown line lives for its own race); the vector
   check answered "could not lookup Ecto repo Trinity.Repo because it was not started" on all three OSes. It
   is now `Trinity.Smoke.Probe`, a child placed after the sessions supervisor and before the endpoint whose
   `start_link/0` does the work and answers `:ignore`.
4. **Brute force in Elixir is fine to 10^4, not 10^5.** Over 10,000 rows the Elixir cosine took 531.7 ms
   p50, of which decoding the float32 binaries to lists was 323 ms; `Nx.dot` on `Nx.BinaryBackend` was worse
   (1,364 ms). One EXLA product over the same bytes: 102 ms the first time (the compile for that shape), 6 ms
   after. `Brute.search/3` now scores with the product when the NIF is loaded and with the Elixir path when it
   is not (the hosted embedder on a machine without EXLA), a test holding the two to the same numbers; as
   built, 10,000 rows search in 99.6 ms p50 through `scripts/vector_bench.exs`, the rows' load from SQLite
   being most of it. docs/perf.md carries the tables; docs/02's line is amended.
5. **Postgrex needs the `vector` type registered.** Found on a local `pgvector/pgvector:pg17` container
   before the postgres job ran: `type vector can not be handled by the types module Postgrex.DefaultTypes`.
   `Trinity.Repo.PostgrexTypes` (defined only when the Postgres adapter is compiled in) and `types:` on the
   repo in the Postgres branch of config; vectors bound as `Pgvector.new/1` structs, never as text literals.
6. **The fake embedder is 384 wide**, twelve counted SHA-256s per text, so the postgres job's AC1 exercises
   the `vector(384)` column and its HNSW index rather than the brute fallback for another width. Its
   `#near:<key>` prefix is two words to the full-text index, which is why the retriever tests' past messages
   carry the words "near" and the key: 031's search is "all these words".
7. **A recall floor.** The first recall tool test asked for "zzz" and got the dog memory back: a vector search
   always has `k` nearest rows, however far. `recall_min_cosine:` (0.3, the slice's own "unrelated" line: the
   unrelated pair measures 0.062 on the local model) gates the vector list; the full-text list needs no floor.
8. **The observer on the real model** extracted "The person's dog is called Rex." and "The person moved to
   Lisbon last spring." at confidence 0.95 from one turn; the same turn's model had also called the `memory`
   tool twice on its own, so the always-on tier held the facts as well. nemotron answered each call in about
   75 s that hour (`proof/ac6-3-taught.png` and `ac6-5-recalled.png` carry the timestamps).
9. **The archive-size line from G1 answered.** A vector is 1,536 bytes on the row; 10,000 rows add
   15,360,000 bytes of vectors and the scratch database measured 47,702,016 bytes with 10,000 rows in it
   (docs/perf.md).
10. **Two flakes met on run 35603385277, closed at their source.** `Fake.fail(10, …)` in
    `test/trinity/llm/llm_test.exs` left failures behind for the next test that did not clear first (the memory
    page's consolidation test got `{:exhausted, 3, :down}`); llm_test and `Trinity.SessionCase` now clear on
    exit too. And the boot receipt's Task raced the sandbox's switch to manual mode on the postgres job (the
    024 boot-receipt tests failed with an OwnershipError); `test/test_helper.exs` waits for the Task before the
    switch. Neither is 032's code; both are in this branch because this branch met them.
11. **AC2 is automated where the model is on disk.** `TRINITY_LOCAL_MODEL_CACHE=<cache> mix test --only
    local_model` runs the real serving under `Trinity.Memory.Supervisor` and asserts the dimension and the two
    cosines; excluded by tag elsewhere, never a silent skip when the variable is set and the model is absent.
    On this machine: dim 384, 0.858, 0.062, three embeds in 281 ms. The owner's manual queue keeps AC2 all the
    same, on their machine.

12. **An HNSW scan with a WHERE clause can come back short.** The postgres job (run 35604770525) answered two
    of three rows for the smoke's vector check: pgvector's HNSW scan hands back its `ef_search` (40) nearest
    index entries and the filter (persona, scope, model) is applied after; the index held other personas'
    entries and dead tuples from rolled-back inserts, so a small persona's rows fell outside the candidates.
    Reproduced locally one run in three; closed by `SET LOCAL hnsw.iterative_scan = strict_order` inside the
    search's own transaction (pgvector 0.8, `fix(s032)` de55660), which walks on until the LIMIT is met with the
    order exact. Four runs of the three memory files on the container after: 21 passed each.

13. **The signer alarm never cleared.** The fips leg (run 35606884798) failed its receipts test on
    `refute Alarm.set?()` after a successful effect: `Trinity.Receipts.Alarm`'s doc has said since 024 that the
    alarm clears "once a signer signs again", and nothing called `clear/0` outside tests, so an alarm any
    earlier test raised stayed up for the run. Red in `test/trinity/receipts/chain_writer_test.exs` (the
    alarm test's tail), then `fix(s024)`: a successful signature in `ChainWriter` clears a set alarm. The
    postgres job's `sessions_stress_test.exs:20` pool-starvation flake (run 35606463533) is the known one
    from earlier slices (the fix(s010) candidate), not touched here.

14. **The sandbox's shared connection sheds load under the stress tests.** With the retriever running on
    every turn, the postgres job's 100-session and 20-writer tests refused checkouts ("could not checkout the
    connection owned by …", runs 35610164189 and 35610171809): DBConnection drops requests once its queue
    stays over `queue_target` (50 ms) for `queue_interval` (1 s), and the sandbox funnels every process of a
    test through one connection. The tests queue hard on purpose; `config/test.exs` now sets `queue_target:
    5_000, queue_interval: 30_000` on the test pools so the queue waits instead. This is the flake the memory
    file called the fix(s010) candidate; it is closed here because 032 made it frequent.
15. **The smoke argument lost to Kernel.CLI on macOS** (package run 35608084951: "No file named --smoke",
    exit 1, between the fourth line and the fifth). The run is now asked for with `TRINITY_SMOKE=1`, which the
    CLI has no reason to read; `--smoke` still works where the race is won. Package run 35610163163 on the
    variable: all three jobs green.

## Follow-ups

- **A local embedding backend for the Linux bundle and for Windows.** The Linux bundle boots with the tier
  off (finding 2); Windows has no EXLA at all. Candidates: a glibc-linked ERTS for Burrito's Linux target (the
  mdex NIF is already built for musl by hand, slice 013, and XLA cannot be), or an ONNX runtime NIF (ortex)
  with the same model exported to ONNX, which would serve all three targets. Owner: the slice that takes it;
  lift condition: `TRINITY_SMOKE_EXLA=ok` (or its ONNX equivalent) on the linux and windows package jobs.
- **hnswlib past 10^4 rows** on machines without EXLA, past 10^5 with it (finding 4).
- **The persona's memory rule and the observer.** The observer writes semantic rows whenever the tier is on;
  the `memory` tool's `permissions.memory` rule on the persona does not gate it. Decide at 040 or when a
  persona needs a read-only memory.
- **Hosted embedder prompting.** nvidia:embed's raw vectors do not separate at the slice's thresholds
  (G1); its query/passage instruction prefixes would have to be measured before `embedder: :hosted` is
  recommended to anyone.
