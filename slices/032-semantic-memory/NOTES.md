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
