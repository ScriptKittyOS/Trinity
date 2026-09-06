# 01 — Architecture

## Shape

A **single Mix/Phoenix application** (`trinity`) organised into bounded contexts and enforced with the `boundary`
library. Not an umbrella (adds friction without isolation benefits here); not a monolith of free-floating modules
(boundary violations become compile errors). ADR-0001.

Two top-level namespaces: `Trinity` (core, no web deps) and `TrinityWeb` (Phoenix). `TrinityWeb` may depend on `Trinity`;
`Trinity` must never depend on `TrinityWeb`.

## Supervision tree (target state; slices build it incrementally)

```
Trinity.Application
├── Trinity.Repo                                  # Ecto (SQLite primary). Slice 010
├── {Phoenix.PubSub, name: Trinity.PubSub}        # all fan-out. Slice 010
├── Trinity.Telemetry                             # metrics + cost ledger. Slice 090
├── {Registry, keys: :unique, name: Trinity.Registry}
├── Trinity.LLM.Supervisor                        # provider clients, rate limiters. Slice 011
├── Trinity.Sessions.Supervisor (DynamicSupervisor) # one Trinity.Sessions.Session per conversation. Slice 012
│     └── Trinity.Sessions.Session (gen_statem)   # states: idle → thinking → tool_wait → approval_wait → compacting
│           └── Trinity.Sessions.TurnTaskSupervisor (Task.Supervisor, per session) # parallel tool calls
├── Trinity.Tools.Supervisor                      # tool runtime (ports, browsers). Slice 020/022
├── Trinity.Permissions.Gate                      # approval requests + allowlist cache. Slice 021
├── Trinity.Receipts.Supervisor                   # Slice 024
│     └── Trinity.Receipts.ChainWriter (one per chain_scope, :unique in Trinity.Registry; ADR-0013)
│           # serialises append per scope. prev_hash -> receipt_hash is a read-then-write, so
│           # concurrent sessions would otherwise race: SQLite's single writer serialises the
│           # INSERT but does not guarantee each row read the correct predecessor.
├── Trinity.Authority                             # the selected implementation, resolved once at boot. Slice 024
├── Trinity.Memory.Supervisor                     # Nx.Serving for embeddings, retrieval. Slice 032
├── Trinity.Skills.Registry                       # hot-loaded skills index. Slice 040
├── Oban                                        # cron + durable jobs. Slice 050
├── Trinity.MCP.Supervisor                        # MCP clients (one per server, lib per 059) + server. Slice 059-062
├── Trinity.Gateways.Supervisor                   # adapters (Telegram, Discord…). Slice 070+
├── Trinity.Subagents.Supervisor (DynamicSupervisor) # Slice 080
├── Trinity.Sandbox.Supervisor                    # Luerl workers. Slice 110
├── Trinity.Desktop                               # ex_tauri bridge (tray, notifications). Slice 100
└── TrinityWeb.Endpoint                           # LiveView. Slice 013
```

`Trinity.Effects` is a module rather than a process: it is the membrane every effectful call passes through, and
holds no state of its own. `Trinity.Authority` appears in the tree because the selection is resolved once at boot
and must not be re-resolvable afterwards.

Restart strategies: `Trinity.Sessions.Supervisor` is `:one_for_one` with `max_restarts: 10, max_seconds: 60`
per session; a Session that crashes rehydrates from the DB (`Trinity.Sessions.rehydrate/1`) and re-enters `idle`.
Tool tasks are linked to their Session but trapped; a tool crash is a tool error, not a session crash.

## Bounded contexts and dependency rules (enforced by `boundary`)

| Context (module) | Owns | May depend on |
|---|---|---|
| `Trinity.Sessions` | Session process, turn loop, message log | LLM, Tools, **Effects**, Permissions, Memory, Skills, Repo, PubSub |
| `Trinity.LLM` | Provider behaviour, req_llm adapter, model registry, streaming, usage | Repo (usage), Telemetry |
| `Trinity.Tools` | Tool behaviour, registry, execution runtime, core tools | Permissions, Sandbox, Repo |
| `Trinity.Permissions` | Policy, tier/1 (name-only), fingerprint-bound approvals, override adjudication | Repo, PubSub |
| `Trinity.Effects` | The membrane; compile-time effect catalog; query receipts for reads | **Tools**, Permissions, Authority, Receipts, Repo |
| `Trinity.Authority` | Behaviour; `Local` implementation; selection at boot; adapter responses | Receipts, Repo |
| `Trinity.Receipts` | Local chain (one supervised writer per scope, ADR-0013), Ed25519 signer, key registry | Repo |
| `Trinity.Memory` | Always-on tier, episodic FTS, semantic store, retrieval, compaction | LLM (summaries/embeddings), Repo |
| `Trinity.Skills` | SKILL.md parsing, registry, loader, manager, scanner | Repo, Permissions, **Effects**, **Receipts**, Sandbox |
| `Trinity.Scheduler` | Oban workers for agent tasks, delivery | Sessions, Gateways, **Repo** |
| `Trinity.MCP` | Client manager, tool bridge, server | Tools, **Effects**, **Permissions**, Memory |
| `Trinity.Gateways` | Adapter behaviour, router, allowlists, pairing | Sessions, **Permissions**, PubSub |
| `Trinity.Subagents` | Delegation, result collection | Sessions, Tools |
| `Trinity.Sandbox` | Luerl runners, resource limits | — |
| `Trinity.Desktop` | ex_tauri bridge | PubSub |
| `Trinity.Telemetry` | events, cost ledger, metrics | Repo |
| `TrinityWeb` | LiveViews, components, API | all `Trinity.*` public APIs |

The six rows in bold were corrected on 2026-09-05. As written, the table forbade the effect path drawn in the
"Core data flow" section below: `Trinity.Effects` could not call `Trinity.Tools`, and `Trinity.Sessions` could not
reach `Trinity.Effects` at all. `boundary` enforces this at compile time and the gate treats its warnings as
errors, so each row was a slice that would not have compiled. Slice 024 hits it first.

Public API of each context is the context module (`Trinity.Sessions`, `Trinity.Tools`, …). Cross-context calls go
through those modules only. `boundary` `exports:` lists enforce this.

## Extension points (behaviours)

| Behaviour | Callbacks (sketch) | Registered via |
|---|---|---|
| `Trinity.LLM.Provider` | `stream/3`, `generate/3`, `embed/2`, `models/0`, `capabilities/1` | config `:providers` list |
| `Trinity.Tools.Tool` | `name/0`, `description/0`, `schema/0`, `risk/0`, `execute/2` | config `:tools` list + MCP dynamic registration |
| `Trinity.Gateways.Adapter` | `child_spec/1`, `deliver/2`, `capabilities/0` | config `:gateways` list |
| `Trinity.Memory.VectorStore` | `upsert/2`, `search/3`, `delete/1` | config `:vector_store` (`SqliteVec` \| `Pgvector` \| `Hnswlib`) |
| `Trinity.Skills.Loader` | `load/1`, `validate/1` | config `:skill_loaders` |
| `Trinity.Permissions.Policy` | `decide/3` → `:allow | :deny | {:ask, prompt}` | config |

Adding any of these = new module + config entry. No core edits. A test in Slice 020 asserts this
("a tool module in `test/support` appears in the registry with zero core changes").

## Core data flow: one turn

```
UI/Gateway ──user_message──▶ Session(gen_statem)
  Session: append message → build prompt (persona + always-on memory + skills index + history[compacted])
          → LLM.stream/3 ──chunks──▶ PubSub "session:<id>" ──▶ LiveView + gateways
          → on tool_call: Permissions.decide → (ask → approval_wait) → Tools.execute in Task → result appended
          → loop until final text → persist → Memory.observe(turn) (async) → idle
```

Every state transition is persisted before it is broadcast. A crash between persist and broadcast is safe
(rehydrate re-broadcasts the last state).

**Effect path (Slice 024):** `Session → Permissions.decide → Effects.execute → Authority → tool.execute/2 (local) or a proposal (external adapter) → Receipts.append`. `Effects` is the only caller of `execute/2` for effectful tools; a census test enforces it. Reads emit query receipts.

## Storage

- Primary: **SQLite** via `ecto_sqlite3`, single file under the OS data dir, WAL mode, one writer (the Repo pool
  is size 1 for writes; reads may use a second pool). FTS5 virtual table for message search. `sqlite_vec` for vectors.
- Secondary: **Postgres + pgvector**, selected by `TRINITY_DB=postgres`. Enables Oban Pro Workflows later. Kept
  compiling and tested in CI (matrix), not default.
- Durable settings/secrets: OS keychain via `Trinity.Secrets` (Slice 100); before that, env vars.

## Concurrency and state rules

- Session state = `%Session.State{}` struct, rebuilt from DB on init; in-memory only for the active turn.
- Never block a Session on I/O: LLM streaming, tool execution, embedding happen in Tasks; Session receives messages.
- PubSub topics: `session:<id>` (turn events), `approvals:<id>`, `gateway:<adapter>`, `system`.
- Backpressure: stream chunks are coalesced to ≤ 20 broadcasts/sec per session (Slice 013).

## Directory layout

```
lib/trinity/                 core contexts (one dir per context)
lib/trinity_web/             Phoenix
priv/repo/migrations/
priv/skills/               bundled skills (SKILL.md)
priv/personas/             default SOUL.md
test/support/              Mox definitions, factories, fake tools/providers
slices/                    this plan's per-slice specs and proofs
docs/                      this plan's docs and ADRs
tauri/                     desktop shell (Slice 001+)
```
