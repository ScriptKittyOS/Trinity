# Performance measurements

Numbers this tree is built on, each with the command or run that produced it and the date. A slice that
changes a number appends a dated row; nothing here is typed from memory (CLAUDE.md section 8).

## Semantic memory (slice 032)

The local embedder is `sentence-transformers/all-MiniLM-L6-v2` through Bumblebee 0.7.1 and EXLA 0.13.1
(`Trinity.Memory.Embedders.Bumblebee`), 384 dimensions, sequence length 128, mean pooling, L2-normalised.
Measured 2026-09-21 on the owner's machine (AMD Ryzen AI MAX+ 395, CPU only through EXLA's host client)
with `scripts/embed_bench.exs` (`BUMBLEBEE_CACHE_DIR=<cache> MIX_ENV=test mix run --no-start
scripts/embed_bench.exs`) unless a row names another command.

### Embedding latency

| measure | value |
|---|---|
| model download (weights and tokenizer, one entry in the cache) | 91,359,935 bytes |
| model load | 650 ms |
| first embed (XLA compilation) | 318 ms |
| single embed | 86.4 ms p50, 90.9 ms max over 20 |
| batch of 32 | 86 ms, 2.71 ms per item |
| cosine("the cat sat", "a cat was sitting") | 0.858 (AC2 asks > 0.7) |
| cosine("the cat sat", "quarterly tax filing") | 0.062 (AC2 asks < 0.3) |
| without EXLA (`Nx.BinaryBackend`) | 15 s first, 23 s per sentence: unusable, which is why the tier is off wherever EXLA cannot load |

The hosted alternative (`nvidia:embed`, nemotron-3-embed-1b, opt-in only): 2048 dimensions, 208 ms p50 and
314 ms max over 5 single embeds, 627 ms for a batch of 32, and cosines 0.71 and 0.752 on the two pairs above:
its raw vectors do not separate at the slice's thresholds (slices/032-semantic-memory/NOTES.md).

### Memory

| measure | value | how |
|---|---|---|
| VM total / OS process RSS while embedding, in the bench script | 101 MB / 587 MB | `scripts/embed_bench.exs` |
| dev server RSS with the model loaded, idle after the AC6 run | 954,680 kB (peak 1,292,456 kB) | `ps -o rss= -p <pid>`; `/proc/<pid>/status` VmHWM, 2026-09-21 |

### Binary size

| measure | value |
|---|---|
| XLA shared library on disk (`deps/exla/cache/.../libxla_extension.so`) | 463,283,344 bytes; 106,037,350 gzip-compressed; the download archive 144,319,267 |
| EXLA NIF (`libexla.so`) | 659,856 bytes |
| tokenizers NIF | 6.9 MB |
| precompiled XLA targets | x86_64 and aarch64 Linux, x86_64 and aarch64 macOS; none for Windows |

Packaged binaries (the `package` workflow's artifacts, compressed by Burrito):

| target | slice 034 (run 35556497526) | slice 032 (run 35604769356) | delta |
|---|---|---|---|
| linux x86_64 | 23,933,053 | 92,597,767 | +68,664,714 (the XLA library and the NIF, which do not load in this ERTS: NOTES finding 2) |
| macOS aarch64 | 15,176,156 | 60,544,615 | +45,368,459 (the NIF loads: `TRINITY_SMOKE_EXLA=ok`) |
| windows x86_64 | 27,551,320 | 29,640,626 | +2,089,306 (nx, bumblebee, the tokenizers NIF; no exla on a Windows host) |

Sizes from `gh api repos/ScriptKittyOS/Trinity/actions/runs/<run>/artifacts`.

### CI: EXLA on the gate's legs

The first push with the dependency (run 35596759435, 2026-09-21), from the job logs' timestamps:

| leg | what happened | time |
|---|---|---|
| gate (ubuntu) | xla archive unpacked, the NIF compiled with g++ against it, cached | 11:57:36 to 11:58:17: 41 s |
| postgres (ubuntu) | the same | 11:57:54 to 11:58:38: 44 s |
| fips (the container, its own toolchain) | the same, from source for the NIF; the XLA archive is the precompiled one | 11:57:45 to 11:58:55: 70 s |

The XLA archive and the compiled NIF are cached by the runners' `actions/cache` keys, so later runs pay the
compile only when the cache misses.

### Vector search

`scripts/vector_bench.exs` (`MIX_ENV=test TRINITY_BENCH_DB=<scratch file> mix run --no-start
scripts/vector_bench.exs`): fake 384-dimension vectors, one persona, one scope, `Trinity.Memory.VectorStores.Brute`
on SQLite, 2026-09-21, the script's output:

| rows | insert and store the vector, one transaction | first search (8 hits) | search p50 | search max |
|---|---|---|---|---|
| 1,000 | 77 ms | 475 ms (the EXLA compile for that shape) | 8.9 ms | 10.8 ms |
| 10,000 | 665 ms | 435 ms | 99.6 ms | 104.3 ms |

The split at 10,000 rows, the same script: loading the rows from SQLite 74 ms; the cosines in Elixir over
decoded lists 390 ms; the EXLA product 27 ms first, 24 ms after. So the store scores with the EXLA product
when the NIF is loaded and falls back to the Elixir path (fine to about 10^4 rows) when it is not. An earlier
scratch run before the product was built measured the Elixir path at 531.7 ms p50 for 10,000 rows and
`Nx.dot` on `Nx.BinaryBackend` at 1,364 ms, which is why the binary backend is not the fallback.

A vector is 1,536 bytes on the row (384 float32); 10,000 rows add 15,360,000 bytes of vectors, and the
scratch database file measured 47,702,016 bytes with 10,000 rows in it (`pragma page_count * page_size`).
docs/02's "fine to about 10^5" is the EXLA product's line, not the Elixir path's; hnswlib 0.1.10 is the step
after either.

`Trinity.Memory.VectorStores.Pgvector` (Postgres 17 in the `pgvector/pgvector:pg17` image, the HNSW cosine
index, `<=>`), the same script against a local container on 2026-09-21:

| rows | insert and store the vector, in one transaction (two statements a row) | search p50 (8 hits) | search max |
|---|---|---|---|
| 1,000 | 921 ms | 4.2 ms | 5.5 ms |
| 10,000 | 13,402 ms | 1.9 ms | 2.3 ms |
