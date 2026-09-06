# Slice 012 — Session process + agent loop

| Field | Value |
|---|---|
| Phase | 1 Core loop |
| Milestone | M1 Talks |
| Size | L |
| Depends on | 010, 011 |

## Goal
One supervised `gen_statem` per conversation implementing the turn loop (prompt build → stream → tool-call
dispatch stub → persist → idle), broadcasting events on PubSub, rehydrating from the DB on restart, and surviving
a kill mid-turn without data loss. This is the heart of the system and the first proof of the crash-safety property.

## Why
Vision goals 1 and 2. Silent process death and the one-agent-per-machine limitation are both answered here.

## Scope
**In:**
- `Trinity.Sessions.Supervisor` (DynamicSupervisor) + `Trinity.Registry` keyed by session id.
- `Trinity.Sessions.Session` gen_statem with states: `idle`, `thinking`, `tool_wait`, `approval_wait` (stub), `compacting` (stub), `error`.
- `Trinity.Sessions.start_session/1`, `ensure_started/1` (idempotent, rehydrates), `send_user_message/2`, `cancel_turn/1`, `state/1`, `subscribe/1`.
- Turn pipeline: `Trinity.Sessions.Prompt.build/2` (system = persona stub + memory stub + history) → `Trinity.LLM.stream_to/3` in a Task under the session's `Task.Supervisor` → event handling → persist assistant message (parts + usage) → broadcast → idle.
- Tool-call handling: parse tool calls into pending list; execution is a stub behaviour `Trinity.Sessions.ToolRunner` that 020 replaces (returns `{:error, :no_tools}` now) — the state machine path must be complete.
- Persistence-before-broadcast rule; partial assistant text persisted every N chunks or M ms as a draft message (`parts.draft: true`), finalised at done.
- Rehydrate: on init, load session + history; if a draft exists, mark it interrupted and broadcast `{:turn_interrupted, ...}`; do not auto-resume (a resume policy is a later slice).
- Idle timeout: hibernate after X min; stop after Y (config); `ensure_started/1` restarts on demand.
- Cancel: kills the streaming Task, persists partial text as interrupted.
- PubSub events on `session:<id>`: `{:user_message, m}`, `{:assistant_delta, text}`, `{:assistant_message, m}`, `{:tool_call, tc}`, `{:state, s}`, `{:turn_interrupted, m}`, `{:error, e}`.
- Backpressure: delta coalescing to ≤ 20 broadcasts/s.
**Out:**
- Real tools (020), permissions (021), compaction (023), persona/memory content (030), UI (013).

## Design notes
- Use `:gen_statem` with `handle_event_function`; state data is `%Trinity.Sessions.State{}`.
- Tasks are started with `Task.Supervisor.async_nolink`; the Session monitors them. A Task crash → `error` state with a persisted error message, then `idle`. A Session crash → supervisor restart → rehydrate.
- Never `GenServer.call` into the Session from inside its own Tasks; use messages.
- Keep `Prompt.build/2` pure and unit-tested; it grows in 030/040.

## Deliverables
- `lib/trinity/sessions/{supervisor,session,state,prompt,tool_runner,events}.ex`, `lib/trinity/sessions.ex` (extended), `lib/trinity/application.ex` tree updated, tests incl. crash tests, `docs/01-architecture.md` tree synced.

## Acceptance criteria
1. [auto] Send a message with FakeProvider streaming 50 deltas: subscriber receives coalesced deltas then `{:assistant_message, m}`; DB has user + assistant rows with correct `seq` and usage.
2. [auto] **Crash test A:** `Process.exit(session_pid, :kill)` mid-stream → supervisor restarts it; `ensure_started/1` returns a new pid; history from DB intact; a draft assistant message exists marked `interrupted`; `{:turn_interrupted, _}` broadcast. No other session affected (run two concurrently).
3. [auto] **Crash test B:** the streaming Task raises → Session enters `error`, persists an error message, returns to `idle`, and accepts the next message.
4. [auto] `cancel_turn/1` during streaming → partial text persisted as interrupted; Session idle within 100 ms.
5. [auto] 100 sessions started concurrently, each doing one turn with FakeProvider, complete with no supervisor restarts and gapless `seq` (extends the 010 stress test).
6. [auto] Tool-call path: FakeProvider emits a tool call → Session enters `tool_wait` → ToolRunner stub returns error → Session records a tool message with the error and continues to a final assistant message.
7. [auto] Backpressure: with a provider emitting 1,000 deltas in 1 s, subscriber receives ≤ ~25 delta broadcasts and the full text is intact.
8. [auto] Idle hibernation observable (`Process.info(pid, :current_function)` or memory drop) after the configured timeout in a test with a short timeout.
9. [auto] **Kill and reseed twice: exactly one live worker; `core_policy_hash` equal before and after; no grant, approval or pending tool call survives in process state.**

## Proof required
- Test names + output for each AC; a `:sys.get_state`-free assertion style except in crash tests; supervisor restart counts.

## Definition of Done
- [ ] gate green · [ ] AC1–9 proven · [ ] docs/01 tree updated · [ ] ROADMAP → done · [ ] commit + tag

## Commit & tag
`feat(s012): complete slice 012 — session process and agent loop` · tag `slice/012`

## Risks / open questions
- Draft-persistence write frequency vs SQLite single writer: measure; default every 500 ms or 2 KB.
- Decide whether `ensure_started/1` is called by UI on mount or lazily on first message (recommend: on mount).

## Platform alignment (appended 2026-09-05; see docs/09-platform-context.md)
- **M3, code-owned caps:** iteration, token and wall-clock caps are module attributes on the loop module; the loop
  function takes no cap argument (a test asserts the arity/signature and that no config key can raise them).
  Reaching a cap is a recorded, receipted outcome and a normal `idle` transition, never a crash.
- **M8, kill-and-reseed:** a reseeded Session is a new pid born from the immutable core policy hash
  (`Trinity.CorePolicy.hash/0`, a compile-time digest of the policy modules) and inherits no grant, approval,
  or pending tool call from process state; grants live only in the DB. This is AC9 in the list above.
- **Sentinel hook:** a `Trinity.Sessions.Sentinel` preflight on model output that flags "already executed" claims,
  boundary-bypass phrasing, and loop abuse; findings are recorded and can only tighten (deny/hold), never loosen.
- **ADR-0009 design checkpoint** lands in this slice's G1 plan: measure whether `Jido.Agent`/`Jido.Action` express
  the loop and the effect boundary; report the three measurements named in the ADR before coding.
