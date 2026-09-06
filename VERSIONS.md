# VERSIONS — verified stack

**Rule:** the coding agent uses these versions. Newer versions are proposed in a slice's `NOTES.md`, approved by
the human, then recorded here with a new "verified" date. `mix versions.verify` (Slice 000) diffs `mix.lock`
against this file.

**Verification legend:** ✅ verified against hex.pm on the date in the row; 🔍 from prior research, re-verify at
Slice 000; ⚠️ constraint or risk.

**Correction, 2026-09-05.** The ✅ marks in the first version of this file were not all measured. Two were wrong
on the packages the OTP pin rests on. Every ✅ below was re-derived on 2026-09-05 by:

```
$ curl -s https://hex.pm/api/packages/<name>
```

A ✅ means that command was run and its answer is in the row, with the date. Nothing else earns one.

## Toolchain

| Component | Pin | Latest seen | Notes |
|---|---|---|---|
| Erlang/OTP | **28.5.0.5** | 28.5.0.6 released, 29.0.6 (2026-09-01) ✅ | Measured at Slice 000, not read from a README: Burrito 1.6.0's ERTS resolver names one artifact source per target, and 28.5.0.5 is the newest OTP returning 200 on all four (macOS universal, Linux x86_64, Linux aarch64, Windows). 28.5.0.6 is released but its macOS and Linux artifacts are unbuilt (404). OTP 29 is 404 on macOS and both Linux arches. ⚠️ Windows tracks OTP releases immediately while the other three lag a third-party CDN's build queue, so re-probe at every phase boundary. See ADR-0005's second correction. |
| Elixir | **1.20.4-otp-28** | 1.20.4 ✅ | Confirmed at Slice 000: `elixir --version` reports Elixir 1.20.4 on Erlang/OTP 28, erts-16.4.0.5. Built-in type checker is part of the gate. `boundary` 0.10.4 compiles and enforces on this pair, measured at Slice 000 (H7). |
| asdf | v0.18.0 | — | `.tool-versions` committed in Slice 000. `mise` is absent on the build machine; measured at Slice 000 G1 with `which mise asdf`. |
| Rust + Tauri CLI | stable | Tauri 2.10.x ✅ | Only needed for desktop slices (001, 100, 101). |
| Zig | version required by Burrito | — | Only for cross-target Burrito builds. |

## Core libraries

| Library | Pin | Latest seen | Status |
|---|---|---|---|
| phoenix | ~> 1.8.13 | 1.8.13 (2026-08-25) ✅ | |
| phoenix_live_view | ~> 1.2.11 | 1.2.11 (2026-08-27) ✅ | 1.2 line; earlier 1.2.x flagged vulnerable on hex, do not pin lower. |
| phoenix_pubsub | ~> 2.1 | — | |
| bandit | ~> 1.x | — 🔍 | HTTP server. |
| ecto_sql | ~> 3.13 | — 🔍 | |
| ecto_sqlite3 | ~> 0.24 | 0.24.1 🔍 | Primary DB. FTS5 available. |
| postgrex + pgvector | optional, ~> 0.3 | 0.3.x 🔍 | Secondary DB path. Not in default deps; behind `TRINITY_DB=postgres`. |
| oban | ~> 2.24 | 2.24.1 (2026-09-03) ✅ | Uses `Oban.Engines.Lite` on SQLite. ⚠️ Oban Pro Workflows/Smart engine are Postgres-only. |
| req | ~> 0.5 | — 🔍 | HTTP client. |
| req_llm | ~> 1.22 | 1.22.0 (2026-09-04) ✅ | Provider layer (streaming, tools, structured output, usage). ⚠️ The pin was `~> 1.10` against a recorded latest of 1.10.0; the real latest was twelve minors ahead. Check event shapes against the current version at Slice 011, not against this file's prose. |
| MCP library | **decided by Slice 059** | — | Candidates verified 2026-09-05: **anubis_mcp** 2.0.x (hex updated 2026-08-07, **LGPL-3.0**, spec ≤ 2025-11-25, no 2026-07-28 seen) ✅; **fastest_mcp** 0.3.2 (2026-08-28, Apache-2.0, claims 2026-07-28 + 2025-11-25 client+server, OAuth, Tasks, MCP Apps; very new, ~400 total downloads) ✅; **gen_mcp** 2.0.0 (2026-07-30, server-only stateless 2026-07-28 + compat plug; license 🔍) ✅. ⚠️ None speaks 2024-11-05, which is obsolete and not a target. |
| jido | ~> 2.3 (pending ADR-0009) | 2.3.3 (2026-08-10) ✅ | Actions, directives and the effect boundary, if the Slice 012 checkpoint adopts it. |
| jason | ~> 1.4 | — | |
| boundary | ~> 0.10 | 0.10.4 (2024-09-25) ✅ | Compile-time module dependency enforcement. ⚠️ No release in roughly two years and unverified on Elixir 1.20. ADR-0001, docs/01, CLAUDE.md §5 and Slice 000 AC4 all rest on it. Probe it first in Slice 000. |
| nimble_options | ~> 1.1 | — | Config validation for behaviours. |

## Memory / ML

| Library | Pin | Latest seen | Status |
|---|---|---|---|
| nx, exla | latest stable | — 🔍 | Local embeddings. EXLA binary size matters for desktop — measure in 032. |
| bumblebee | ~> 0.7 | 0.7.0 (2026-05-15) 🔍 | `all-MiniLM-L6-v2` embeddings; Whisper later. |
| sqlite_vec | ~> 0.1 | 0.1.0 (2024-11-19) ✅ | Vectors in SQLite. Verify the loadable extension works inside the Burrito bundle (Slice 032). ⚠️ Pre-1.0, no release in roughly 22 months, 6,938 downloads all-time. R11's trigger already fires. Decide the fallback before Slice 032 starts. |
| hnswlib | ~> 0.1.7 | 0.1.7 🔍 | ⚠️ Pre-1.0. Optional accelerator; not on the critical path. |

## Tools / sandbox / desktop

| Library | Pin | Latest seen | Status |
|---|---|---|---|
| muontrap | ~> 2.0 | 2.0.0 (2026-08-13) ✅ | Shell tool. Linux cgroups optional. ⚠️ The pin was `~> 1.8`, which cannot resolve the current major. A major bump is an API review, not a version bump: re-read the child-kill guarantee against 2.0 before Slice 022. |
| floki | ~> 0.38 | — 🔍 | HTML parsing. |
| luerl (+ sandbox) | latest | sandbox 0.5 🔍 | Slice 110 only. |
| burrito | ~> 1.6 | 1.6.0 (2026-07-24) 🔍 | ⚠️ ERTS availability drives the OTP pin. Corrected 2026-09-05: this row previously read `~> 1.5 / 1.5.0 ✅`; the ✅ was not measured. Re-verify the ERTS set at Slice 001. |
| ex_tauri | ~> 0.2 | 0.2.0 (2026-07-12) 🔍 | ⚠️ Windows unverified; Slice 001 tests it. ⚠️ 439 downloads all-time, so the ADR-0004 fallback matrix carries real weight. Corrected 2026-09-05: this row previously read `~> 0.1 / 0.1.x ✅`; the ✅ was not measured. |
| nostrum | ~> 0.10 | 0.10.4 (2025-03-02) ✅ | Discord. ⚠️ No release in roughly 18 months. R11's trigger already fires. Check intents and components against the current gateway before Slice 072. |
| telegex | **not pinned** | 1.9.0-rc.0 (2024-09-18) ✅ | Telegram. ⚠️ The latest release on hex is a release candidate, roughly two years old, and this file's own rule forbids pinning an `-rc`. Alternative: ex_gram. Slice 071 decides with the measurement. |
| phoenix_streamdown | **not pinned** | 1.0.0-beta.4 (2026-05-03) ✅ | Streaming markdown renderer for LiveView. ⚠️ Pre-release, and this file's own rule forbids pinning an `-rc`; a beta is the same category. Verify at Slice 013; fallback: earmark or mdex with chunk buffering. |

## Dev / quality

| Library | Pin | Notes |
|---|---|---|
| credo | ~> 1.7 | `--strict` in gate |
| mox | ~> 1.2 | mocks for all behaviours |
| mix_audit | ~> 2.1 | `mix deps.audit` |
| sobelow | ~> 0.15 | 0.15.0 (2026-08-05). Phoenix security lint. Blocking in the gate with a committed `--skip` list (M5) |
| ex_doc | ~> 0.38 | docs |
| lazy_html | (transitive via LiveView test) | |

## Re-verification procedure (run at Slice 000 and at every phase boundary)

```
mix hex.info <package>            # latest stable + retired flags
mix hex.outdated                  # what moved since the pin
mix hex.audit                     # retired packages in lock
mix deps.audit                    # known vulnerabilities
```
Record the output in the slice's PROOF.md and update this file's "Latest seen" column with the date.
Rules: prefer the newest stable that satisfies the packaging chain (Burrito/ex_tauri); never pin an `-rc`;
never pin a version hex marks as retired or vulnerable.
