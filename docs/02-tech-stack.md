# 02: Tech stack

Versions live in `VERSIONS.md`. This file explains *why* each choice was made and what would change it.

| Concern | Choice | Why | What would change it |
|---|---|---|---|
| Runtime | Elixir 1.20 / OTP 28 | Latest Elixir with built-in type checking; OTP 28 is the newest ERTS Burrito precompiles | Burrito publishing OTP 29 ERTS → move to 29 (ADR-0005) |
| Web/UI | Phoenix 1.8 + LiveView 1.2 | Real-time streaming UI with server state; colocated hooks; scopes | none |
| HTTP server | Bandit | Pure Elixir, Phoenix default | none |
| DB (primary) | SQLite via ecto_sqlite3 | Zero-install desktop; FTS5 built in; sqlite_vec for vectors | Need for Oban Pro Workflows → Postgres (ADR-0002) |
| DB (secondary) | Postgres + pgvector | HNSW vectors, Oban Pro, multi-device server | none |
| Jobs/cron | Oban (Lite engine on SQLite) | Durable, retried, observable; free Oban Web | none |
| LLM | req_llm | 20+ providers, streaming, tools, structured output, usage; Req-based; active | If it stalls, LangChain-Elixir is the fallback (same behaviour) |
| MCP | decided by Slice 059 (fastest_mcp / gen_mcp / anubis_mcp / own server) | Target is 2026-07-28 with 2025-11-25 compat; anubis is ≤ 2025-11-25 and LGPL-3.0 | ADR-0007 finalised by measurement |
| Embeddings | Bumblebee + EXLA (all-MiniLM-L6-v2) | Local, private, 384-dim | If EXLA binary size is unacceptable on desktop → hosted embeddings via req_llm, or Ortex (risk: stalled) |
| Vector search | sqlite_vec (brute force) behind `VectorStore` behaviour | Fine to ~10^5 vectors; no extra process | Scale → hnswlib (pre-1.0) or pgvector HNSW |
| Shell tool | MuonTrap | Guaranteed child kill on process death; cgroups on Linux | none |
| Sandbox | Luerl (`sandbox` pkg) | In-VM, reduction-limited, no OS access | Untrusted native code → container/microVM (out of scope) |
| Modularity | `boundary` + behaviours + `Registry` | Compile-time enforcement of context deps | none |
| Config validation | nimble_options | Behaviour opts validated with docs generated | none |
| Desktop shell | ex_tauri (Tauri 2 + Burrito sidecar) | Modern webview, tray, notifications, updater, signing plumbing; small footprint | Windows unsupported by ex_tauri → elixir-desktop or plain Tauri sidecar (Slice 001 decides; ADR-0004) |
| Packaging | Burrito | Single binary with ERTS | none |
| Gateways | Telegex (Telegram), Nostrum (Discord) | Active, supervised | none |
| Markdown streaming | phoenix_streamdown | LLM-optimised; freezes completed blocks | Verify in 013; fallback to earmark + chunk buffering |
| Testing | ExUnit, Mox, LiveViewTest (lazy_html) | Standard | none |
| Quality | credo, mix_audit, sobelow, ex_doc, Elixir type checker | Gate | none |

## Explicitly not chosen (and why)

- **Umbrella apps**: isolation is enforced by `boundary` without the build/config overhead.
- **Jido**: *revised 2026-09-05:* reconsidered rather than rejected. Whether it expresses the action, directive and
  effect layer better than plain OTP is ADR-0009, decided by measurement at the Slice 012 checkpoint.
- **Mnesia**: split-brain and schema-management sharp edges; SQLite/CubDB are simpler for single-node.
- **Ortex**: stalled since Nov 2024. Bumblebee/EXLA instead.
- **Electron**: heavier than Tauri; no advantage for a LiveView app.
- **LiveView Native**: mobile-oriented; not a desktop path.
- **Code.eval_string for skills**: unsafe by construction. Skills are data (SKILL.md) or Luerl.
