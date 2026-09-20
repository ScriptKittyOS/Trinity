# Slice 012: NOTES

## The ADR-0009 design checkpoint, measured 2026-09-20 before any code

Packages read from their Hex tarballs in a scratch directory, never added to the tree: `jido` 2.3.3, `jido_action`
2.3.2, `jido_signal` 2.2.0 (`mix hex.package fetch <name> <version> --unpack`).

| Measurement the ADR names | Result | Derived by |
|---|---|---|
| (a) M3 and M4 assertable as tests against Jido's structures | M4 yes: a `Jido.Action` is a compile-time module with a param schema and `run/2`, so a compile-time catalog is a list of modules. M3 only with a census: `Jido.Exec.run/4` takes `timeout` and `max_retries` as call-site options, so "the loop takes no cap argument" holds only if Trinity's wrapper is `Jido.Exec`'s sole caller | `grep -n 'def run(' jido_action/lib/jido_action/exec.ex` → `run(action, params, context, opts)`; `grep -n '@callback' jido_action/lib/jido_action.ex` |
| (b) what `Jido.Agent` adds over the `gen_statem` | Sensors, a cron scheduler, signal routing, worker pools, and an `AgentServer` executing `RunInstruction` directives through `Jido.Exec`: a second execution path for tools beside `Trinity.Effects`, the bypass shape 024's census flags. Nothing the Session's six states, persist-before-broadcast rule or rehydrate need | `ls jido/lib/jido` (sensor, scheduler, agent_server, pod); `grep -n 'defmodule ' jido/lib/jido/agent/directive.ex` (Emit, Spawn, SpawnAgent, AdoptChild, StopChild, StartSensor, StopSensor, Schedule, RunInstruction, Stop, Error) |
| (c) dependency weight | `jido`: 29,820 lines, ten runtime dependencies (`jido_action`, `jido_signal`, `poolboy`, `crontab`, `time_zone_info`, `telemetry_metrics`, `nimble_options`, `splode`, `telemetry`; `jido_signal` adds `msgpax`, `memento`, `fuse`, `uniq`, `phoenix_pubsub`, `zoi`). `jido_action`: six (`jason`, `nimble_options`, `telemetry`, `zoi`, `splode`, `multigraph`), two of which the tree carries already | `find lib -name '*.ex' \| xargs cat \| wc -l`; `grep '{:' mix.exs` in each |

**Outcome: actions only**, one of the three the ADR permits. `jido_action` enters at slice 020 as the base of the
tool behaviour (schema, `run/2`, lifecycle hooks), with a census at 024 that `Trinity.Effects` is `Jido.Exec`'s
only caller for effectful tools. `jido` (the agent runtime) is not adopted: the Session stays an OTP
`gen_statem`, PubSub is the broadcast, Oban (050) is the scheduler, gateways (070) are the sensors. Slice 012
adds no Jido dependency; nothing in it is an action. Recorded as an appended decision on ADR-0009 in this
slice's docs commit, with the VERSIONS row moved from `jido` to `jido_action`. The owner may veto at G1.

## G1 plan, 2026-09-20

Tree at `ada3031` on `main` (010 and 011 approved); branch `slice/012-session-process-agent-loop`; ROADMAP row
012 set to `in_progress` in this commit. Each line names its test; the order is the build order.

1. `Trinity.Sessions.State` struct (session id, persona, history cursor, current turn: draft text, pending tool
   calls, task ref, usage) rebuilt from the DB on init; `Trinity.Sessions.Events` naming the seven PubSub event
   shapes on `session:<id>`; `Trinity.Sessions.subscribe/1`. Test: every broadcast shape is one of the seven.
2. `Trinity.Sessions.Supervisor` (DynamicSupervisor, `:one_for_one`, `max_restarts: 10, max_seconds: 60`),
   `Trinity.Registry` (`:unique`, keyed by session id), both in the application tree; `start_session/1`,
   `ensure_started/1` (idempotent, rehydrates), `state/1`, `whereis/1`. Test: two `ensure_started` calls return
   one pid; a stopped session restarts on demand.
3. `Trinity.Sessions.Prompt.build/2`, pure: system (persona stub, memory stub) plus history in seq order into a
   `Trinity.LLM.Request`. Test: a fixed history builds a fixed request; the function has no side effect.
4. `Trinity.Sessions.Session` `gen_statem` (`handle_event_function`): `idle`, `thinking`, `tool_wait`,
   `approval_wait` (stub, unreachable until 021), `compacting` (stub), `error`. A user message is persisted
   (`Sessions.append_message/2`), broadcast, then the turn starts: `Trinity.LLM.stream_to/3` under the
   session's own `Task.Supervisor` (`Trinity.Sessions.TurnTaskSupervisor`, per session, monitored; never a call
   into the Session from its Task). Events fold into the draft; `{:llm_done, ref, {:ok, usage}}` persists the
   assistant message with usage and broadcasts it, persist before broadcast; then `idle`. Test (AC1): 50 fake
   deltas, coalesced broadcasts then `{:assistant_message, m}`, DB rows with seq 1 and 2 and usage.
5. Draft persistence: partial text written as a draft message (`parts.draft = true`) every 500 ms or 2 KB,
   whichever first, and finalised at done (the same row updated: the one edit the append-only rule allows,
   stated in docs/05 as a draft becoming final). Rehydrate: a draft left behind is marked `interrupted` and
   `{:turn_interrupted, m}` broadcast; no auto-resume. Test (AC2, crash test A): kill the Session mid-stream,
   supervisor restarts it, `ensure_started/1` returns a new pid, history intact, the draft interrupted, the
   event received; a second session running at the same time is unaffected.
6. Task failure: the streaming Task raises, the Session enters `error`, persists an error message, returns to
   `idle`, accepts the next message (AC3). `cancel_turn/1`: kills the Task, persists the partial text as
   interrupted, idle within 100 ms (AC4).
7. Tool-call path: `{:tool_call_end, id, args}` events collect into pending calls; at `{:done, :tool_calls}` the
   Session enters `tool_wait` and runs `Trinity.Sessions.ToolRunner` (a behaviour with one stub implementation
   returning `{:error, :no_tools}`; 020 replaces it) in a Task; each result is a `tool` message (seq, content,
   tool_call_id); then a second turn for the final assistant text (AC6). One follow-up turn at this slice; the
   loop cap is line 9.
8. Backpressure: deltas coalesced by a 50 ms timer into at most 20 broadcasts a second; the full text intact
   (AC7 with 1,000 deltas in a second).
9. M3, code-owned caps: `Trinity.Sessions.Caps` with `@max_turns_per_message`, `@max_tokens_per_message` and
   `@max_wall_ms` as module attributes; the loop function takes no cap argument (a test asserts the signature
   and that no config key exists to raise them); reaching a cap is a normal transition to `idle` with a
   recorded outcome (a query-receipt placeholder until 024: a `provider_meta.cap_reached` on the message).
10. Idle: hibernate after `idle_hibernate_ms`, stop after `idle_stop_ms` (config, short in test); `ensure_started/1`
    restarts on demand (AC8, observed through `Process.info(pid, :current_function)` and a memory drop).
11. `Trinity.CorePolicy.hash/0`: a digest over the object code of the policy modules (at this slice: `Session`,
    `Caps`, `ToolRunner`, `Sentinel`), a module-attribute list 024 extends; the boot receipt is 024's, so at
    012 the hash is exposed and tested. AC9: kill and reseed twice, exactly one live worker in the registry,
    the hash equal before and after, and a `state/1` read shows no grant, approval or pending tool call
    survived (the pending list is rebuilt empty; grants have no home before 021).
12. `Trinity.Sessions.Sentinel.preflight/1` on model output: flags "already executed" claims, boundary-bypass
    phrasing and loop abuse (a fixed pattern list, stated as a tripwire); findings recorded on the assistant
    message's `provider_meta.sentinel` and can only tighten (a finding sets the turn's outcome to `hold`, never
    loosens anything). Test: each pattern fires; ordinary text does not; a finding never removes a hold.
13. AC5: 100 sessions started at once, one fake turn each, no supervisor restart, gapless seq (the restart
    count read from the supervisor before and after).
14. docs/01 tree synced (the Registry, Sessions.Supervisor and per-session Task.Supervisor exist; LLM.Supervisor
    still does not); ADR-0009 appended with the checkpoint above; VERSIONS row `jido` becomes `jido_action`.
15. Gate, coverage row, PROOF.md, ROADMAP to `done`, pull request, tag.

Manual verification queue: none. Every criterion is `[auto]`.

Deviations from SLICE.md, stated before building: `Trinity.CorePolicy.hash/0` is introduced here rather than
at 024 because AC9 names it; 024 extends its module list and adds the boot receipt. The recorded outcome of a
cap and a sentinel finding lives on the message's `provider_meta` until 024's receipts exist. `approval_wait`
and `compacting` are states with no inbound transition at this slice, present so the machine's shape is
complete and a test asserts they are unreachable rather than pretending they work.
