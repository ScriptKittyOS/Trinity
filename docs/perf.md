# Performance measurements

Numbers this tree is built on, each with the command or run that produced it and the date. A slice that
changes a number appends a dated row; nothing here is typed from memory (docs/03-conventions.md, rules of evidence).

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
its raw vectors do not separate at the thresholds this measurement uses.

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

## The static floor and its scorer (slice 133)

MEASURED on 2026-10-08 on the owner's machine: AMD RYZEN AI MAX+ 395 w/ Radeon 8060S, 32 logical CPUs, 125 GiB,
Linux 6.14.0-37-generic x86_64; OTP 28 (ERTS 16.4.0.5), Elixir 1.20.4, 32 schedulers; under a 24 GiB cgroup,
with other work on the machine (load average 4.7 to 5.8 on 32 CPUs during the run).

### Scoring at 10^4 x 256 int8 (AC13, D-scoring)

`TRINITY_STATIC_MODEL_DIR=<dir> MIX_ENV=test mix run --no-start scripts/scorer_bench.exs`: the static model's
own 256-dimension int8 embeddings of 10,000 generated memory-shaped sentences, 200 queries one at a time after
20 discarded, the script's output:

| scorer | p50 | p95 |
|---|---|---|
| sign bits by Hamming distance, then the exact int8 cosine over the 256 nearest (`Scorer.prefilter/4`) | 8.513 ms | 10.296 ms |
| the exact int8 cosine over every row (`Scorer.exact/3`) | 20.179 ms | 24.5 ms |
| deliberately unoptimised: every row decoded to floats per query (AC13's red) | 248.829 ms | 303.452 ms |

Preparing the index (norms and sign bits for 10,000 rows) took 43 ms, once per load. The prefilter's recall@10
against the exact search was 0.9995 over the 200 queries. The pre-set line was 50 ms p95: both real scorers are
under it, so no scoring crate is opened; the unoptimised one is over it by six times, which is what shows the
measurement can tell them apart. Slice 032's figure for the old path (the Elixir cosine over decoded float lists
at 10^4 x 384) was 390 ms.

### The store, end to end

`scripts/vector_bench.exs` (`TRINITY_BENCH_QUANT=int8`, fake vectors under an int8 space, one persona, SQLite),
after the store stopped reading every entry and reads only ids and vectors, then the k that rank:

| rows | int8 search p50 | max | float32 search p50 (EXLA product) | max |
|---|---|---|---|---|
| 1,000 | 4.571 ms | 5.704 ms | 5.678 ms | 7.812 ms |
| 10,000 | 71.959 ms | 87.604 ms | 50.033 ms | 53.817 ms |

At 10^4 the int8 path's time is mostly the database: the rows' load and the fit check that refuses a mixed
space. A cached, prepared index per space would let the store use the prefilter; it is a follow-up for past 10^4.

### The weights

| artifact | bytes | SHA-256 |
|---|---|---|
| upstream `0_StaticEmbedding/model.safetensors` at `f60985c706f192d45d218078e49e5a8b6f15283a` (30,522 x 1024 float32) | 125,018,208 | `164fc63ee9f9267be7378fcbd7df99d09788a2f45244c92aa99ae5a574925716` |
| `static-retrieval-mrl-en-v1-256-int8.tsw` (`mix trinity.static.build`) | 8,167,604 | `5990c1104963d8e2402854c80b9a8f8e3a490085c037f25ced63642f4578c520` |
| `static-retrieval-mrl-en-v1-1024-f32.tsw` | 125,249,996 | `c8e427cc6aa3d55755d9c4085f6ab7572e95a509ff9e665f352f7d231db66299` |

Sizes from `ls -la`, digests from `sha256sum` and the build task. The 256 int8 file is the matrix (7,813,632
bytes), a float32 scale per token row (122,088) and the vocabulary. Building it from the snapshot took under two
seconds, and rebuilding gave the same digest.

### A release without the neural group

`scripts/static_floor_release.sh` (`TRINITY_WITHOUT_ML=1`): the headless release assembled from a build that never
had nx, exla, xla, axon, bumblebee or tokenizers holds none of them in `lib/`, boots, writes two memories and
recalls one through the static space (slice 133, AC8). Slice 130 measured exla at 443 MB of a 522 MB release.

## The Tier 3 embedder and its gates (slice 134)

MEASURED on 2026-10-08 on the same machine as slice 133's figures above (AMD RYZEN AI MAX+ 395, 32 logical CPUs,
125 GiB, Linux 6.14.0-37), with other work on it (load average 9 to 16 during the throughput run). The service:
`ollama/ollama:0.40.0` (index digest `sha256:1bef639749741b375e9a1eb2c1346fb57ce52f5432de1f74846e44ccc18e1687`),
the upstream image at the version the hardened government image pinned that day, on the CPU, limited to 16 GiB.
**It is not that hardened image**, which these gates have yet to be run on. The model: `Qwen3-Embedding-0.6B-f16.gguf`
(SHA-256 `421a27e58d165478cc7acb984a688c2aa41404968b0203e7cd743ece44c54340`), imported through
`mix trinity.tier3.import`; the reference: sentence-transformers 6.1.0 over the same model's safetensors, float32.

| gate | result |
|---|---|
| 1, parity, 500 fixtures at `num_ctx` 2048 | PASS: minimum cosine 0.99968977, median 0.999875; every `prompt_eval_count` equal to the reference tokenizer's count |
| 1, red: `num_ctx` 256 with the service's default truncation | FAIL as intended: 60 of 500 under 0.999, minimum 0.95426396, all of them inputs over 255 tokens |
| 1, the same model quantized to Q8_0 | FAIL: minimum 0.99853698, 60 of 500 under 0.999 (not offered) |
| 2, truncation at `num_ctx` 512 and 2048 | PASS: 511 (2047) tokens answered, 512 (2048) refused with `truncate: false`; with `truncate: true` or omitted, a vector of the first 511 (2047) |
| 3, the digest pin, interval 2 s | PASS: OFF with `:model_digest_changed` 160 ms after the blob behind the tag was replaced; with the comparison removed, still on after 7.4 s |
| 4, offline | PASS: `--network none`, only `lo`; `/api/embed` answered from the verified directory; a pull failed for want of a network |

Throughput through Trinity's client (tokenizing, the request and the checks), 301 sentences of 7 to 200 tokens
(median 28) cycled, no pass mark:

| batch | calls | p50 | p95 | texts per second at p50 |
|---|---|---|---|---|
| 1 | 200 | 34.8 ms | 57.7 ms | 28.7 |
| 32 | 40 | 1227.8 ms | 1382.5 ms | 26.1 |

Batching does not raise throughput on this CPU path. The service held 5.31 GiB of its 16 GiB afterwards. Trinity's
own token count matches the reference tokenizer on 5,000 natural sentences and 1,221 hostile inputs, and reading
the tokenizer out of the 1.2 GB GGUF's header takes 337 ms.
