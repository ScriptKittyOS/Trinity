# 01: Architecture

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
├── {Registry, keys: :unique, name: Trinity.Registry}   # Slice 012, as built
├── {Task.Supervisor, name: Trinity.LLM.TaskSupervisor}  # Slice 011, as built: stream_to/3 runs here.
│                                                 # Trinity.LLM.Supervisor (rate limiters) is not built:
│                                                 # nothing needs a process yet (011 NOTES, follow-up)
├── Trinity.Sessions.Supervisor (DynamicSupervisor) # one Trinity.Sessions.Session per conversation. Slice 012, as built
│     └── Trinity.Sessions.Session (gen_statem)   # states: idle → thinking → tool_wait → approval_wait → compacting → error
│           └── Task.Supervisor (started by the Session, linked, unnamed) # the model call and the tool calls of one turn
├── Trinity.Tools.Supervisor                      # Slice 020, as built: Trinity.Tools.TaskSupervisor (every tool
│     │                                         # call of a turn runs under it) and Trinity.Tools.Registry
│     │                                         # (GenServer over ETS). 022 adds the stateful runtimes beside them
├── Trinity.Permissions.Gate                      # Slice 021, as built: approval requests (rows, then broadcasts),
│                                                 # decisions, expiries; pending rows reloaded with their timers
├── Trinity.Authority.Selection                   # Slice 024, as built: a transient Task right after the data
│                                                 # directory lock; reads TRINITY_AUTHORITY once, refuses the boot
│                                                 # by name (ADR-0010). Placed early in the list, before the Repo.
├── Trinity.Repo.Receipts                         # Slice 024, as built: the receipts chain's own SQLite file,
│                                                 # synchronous full (ADR-0013), its own migrations
├── Trinity.Receipts.Supervisor                   # Slice 024, as built: KeyCustody.boot!/1 in its init (the
│     │                                         # signer and its key, once), then
│     └── Trinity.Receipts.WriterSupervisor (DynamicSupervisor)
│           └── Trinity.Receipts.ChainWriter (one per chain_scope, :unique in Trinity.Registry, temporary; ADR-0013)
│                 # serialises append per scope. prev_hash -> receipt_hash is a read-then-write, so
│                 # concurrent sessions would otherwise race: SQLite's single writer serialises the
│                 # INSERT but does not guarantee each row read the correct predecessor.
├── Trinity.Effects.Boot                          # Slice 024, as built: a transient Task writing the boot receipt
│                                                 # once the signer and the authority are known
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
holds no state of its own. `Trinity.Authority` is a behaviour with the selection resolved once at boot by the
`Selection` child and must not be re-resolvable afterwards; as built at slice 024 the selected module is read
from `:persistent_term` by `Trinity.Authority.impl/0`.

Restart strategies: `Trinity.Sessions.Supervisor` is `:one_for_one` with `max_restarts: 10, max_seconds: 60`
per session; a Session that crashes rehydrates from the DB (`Trinity.Sessions.rehydrate/1`) and re-enters `idle`.
Tool tasks are linked to their Session but trapped; a tool crash is a tool error, not a session crash.

## Bounded contexts and dependency rules (enforced by `boundary`)

**`boundary` enforces this table only under `--warnings-as-errors`.** Measured at slice 000: it
reports a violation as a *warning*, so `mix compile --force` with a planted `Trinity → TrinityWeb`
call exits **0**. Every rule below is advisory unless the gate's compile step carries that flag,
which `test/gate_alias_test.exs` asserts. Drop the flag and this table stops being enforced
without anything failing.

| Context (module) | Owns | May depend on |
|---|---|---|
| `Trinity.Sessions` | Session process, turn loop, message log; the persona row and its store (since 010; `Trinity.Personas` is the context over them, as built at 030) | LLM, Tools, **Effects**, Permissions, Memory, Skills, Repo, PubSub, Receipts (as built at 030: the prompt truncation receipt), Context (as built at 033: AGENTS.md every turn) |
| `Trinity.Context` | What the project tells the prompt: `AgentsMd` (033); the skills index joins it at 040 | none beyond the core |
| `Trinity.LLM` | Provider behaviour, req_llm adapter, model registry, streaming, usage | Repo (usage), Telemetry |
| `Trinity.Tools` | Tool behaviour, registry, execution runtime, core tools, and (as built at 024) the compile-time effect catalog `Trinity.Tools.Catalog`, because the registry reads it and Effects depends on Tools | Permissions, Sandbox, Repo, **Memory** (as built at 031: `session_search` reads the index; Memory never depends on Tools) |
| `Trinity.Permissions` | Policy, tier/1 (name-only), fingerprint-bound approvals, override adjudication | Repo, PubSub |
| `Trinity.Effects` | The membrane; the runner in force (`Effects.Runner`, the executor `Tools.Runner` takes as a function); decision and query receipts; the boot receipt | **Tools**, Permissions, Authority, Receipts, Repo |
| `Trinity.Authority` | Behaviour; `Local` implementation (the one caller of `execute/2` for effectful tools); selection at boot; `Staged` | Receipts, Repo |
| `Trinity.Receipts` | Local chain (one supervised writer per scope, ADR-0013), the signer seam (Ed25519, P-384, ML-DSA-87), key custody and the registry, checkpoints, the verifier, the alarm | Repo (`Repo.Receipts`) |
| `Trinity.Memory` | Always-on tiers with their budget and consolidator (030), search (031), semantic store and retrieval (032), compaction (023) | LLM (summaries/embeddings), Repo |
| `Trinity.Skills` | SKILL.md parsing, registry, loader, manager, scanner | Repo, Permissions, **Effects**, **Receipts**, Sandbox |
| `Trinity.Scheduler` | Oban workers for agent tasks, delivery | Sessions, Gateways, **Repo** |
| `Trinity.MCP` | Client manager, tool bridge, server | Tools, **Effects**, **Permissions**, Memory |
| `Trinity.Gateways` | Adapter behaviour, router, allowlists, pairing | Sessions, **Permissions**, PubSub |
| `Trinity.Subagents` | Delegation, result collection | Sessions, Tools |
| `Trinity.Sandbox` | Luerl runners, resource limits | none |
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

**Tool calls (Slice 020):** at `{:done, :tool_calls}` the Session hands the turn's calls to
`Trinity.Sessions.ToolRunner.run_all/2`, the seam whose implementation in force is `Trinity.Tools.Runner`
(config, so a test can put the stub back). The runner runs every call at once under
`Trinity.Tools.TaskSupervisor`, each with its tool's timeout: lookup, `jsv` validation of the arguments
(refused, never repaired), `Trinity.Permissions.decide/3` once, `execute/2`, the result cap. A crash, a timeout
and an unknown name are error results the model reads; the Session writes one `tool` row per answer with the
tool's definition digest. Each turn's request carries the declared surface (`Trinity.Tools.to_llm_tools/0`) and
the assistant row records it (`provider_meta.tool_surface`); `Trinity.Tools.surface_diff/1` over a history names
the calls a turn made outside it. Sessions depends on Tools; Tools depends on Permissions and never on Sessions
(the runner implements the seam's functions without naming the behaviour, which would close a cycle).

**Compaction (Slice 023):** before a model call the Session estimates the request (`Trinity.Memory.Tokens`,
bytes over three plus four per message, calibrated high) against the model's window (`context_tokens` on the
registry entry, 32,768 when absent); over the soft threshold (70 %) it enters `compacting`, runs
`Trinity.Memory.Compactor` in a Task (the structured call, with a plain-text fallback when the provider answers
no object) and writes the compaction row itself; over the hard threshold (90 %) after that it forks: a child
session with `parent_id`, the compaction first, the user's message second, the child's turn started, the parent
closed with a row naming the child and `{:forked, child_id}` broadcast. Memory depends on LLM and the core,
never on Sessions.

**Effect path (Slice 024, as built):** `Session → ToolRunner seam → Effects.Runner (executor) → Tools.Runner.decide (the gate, once) → decision receipt → Effects.execute (the membrane: decision, effect class and catalog, fingerprint re-derived, idempotency by session and call id) → Authority.stage → decide → admission receipt → Authority.Local.execute → tool.execute/2 → outcome receipt`. `Authority.Local` is the only caller of `execute/2` for effectful tools; `Tools.Runner.call_tool/3` runs `effect: :none` tools directly and refuses the rest by name; a census over `git ls-files` with a planted bypass holds both. Reads emit query receipts, chained unsigned and checkpointed. A decision that cannot be receipted (no signer) refuses the call, reads included.

**The page (Slice 013):** `TrinityWeb.SessionLive.Show` subscribes to `session:<id>` on mount, calls
`Trinity.Sessions.ensure_started/1`, loads the history from the database into a LiveView stream and the turn in
flight from `Trinity.Sessions.state/1` (the state name and the draft text), and drops the delta broadcasts that
were already queued when that reply arrived, because the reply's text contains them. Completed messages render
once through `TrinityWeb.Markdown` (mdex); the in-progress text is one assign replaced per coalesced delta. Tool
rows are written without an event of their own, so the page reads what the database has past its last seen
`seq` whenever a final or interrupted message arrives. A user message's send goes through `Trinity.Sessions`,
never to the process directly. The `Trinity.LLM.Providers.Fake` provider lives in `lib/` and runs the chat in
development under `TRINITY_FAKE_PROVIDER=1`.

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
- Backpressure: stream chunks are coalesced to ≤ 20 broadcasts/sec per session (built at Slice 012: a 50 ms timer in the Session, so 013 receives coalesced deltas).

## Directory layout

```
lib/trinity/                 core contexts (one dir per context)
lib/trinity_web/             Phoenix: live/session_live (the chat, 013), components/chat_components.ex
                             (the component vocabulary), markdown.ex (the one renderer), plugs/ (the CSP)
priv/repo/migrations/
priv/skills/               bundled skills (SKILL.md)
priv/personas/             default SOUL.md
test/support/              Mox definitions, factories, fake tools/providers
slices/                    this plan's per-slice specs and proofs
docs/                      this plan's docs and ADRs
tauri/                     desktop shell (Slice 001+)
```
