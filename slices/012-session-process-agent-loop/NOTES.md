# Slice 012: NOTES

## The ADR-0009 design checkpoint, measured 2026-09-20 before any code

Packages read from their Hex tarballs in a scratch directory, never added to the tree: `jido` 2.3.3, `jido_action`
2.3.2, `jido_signal` 2.2.0 (`mix hex.package fetch <name> <version> --unpack`).

| Measurement the ADR names | Result | Derived by |
|---|---|---|
| (a) M3 and M4 assertable as tests against Jido's structures | M4 yes: a `Jido.Action` is a compile-time module with a param schema and `run/2`, so a compile-time catalog is a list of modules. M3 only with a census: `Jido.Exec.run/4` takes `timeout` and `max_retries` as call-site options, so "the loop takes no cap argument" holds only if Trinity's wrapper is `Jido.Exec`'s sole caller | `grep -n 'def run(' jido_action/lib/jido_action/exec.ex` → `run(action, params, context, opts)`; `grep -n '@callback' jido_action/lib/jido_action.ex` |
| (b) what `Jido.Agent` adds over the `gen_statem` | Sensors, a cron scheduler, signal routing, worker pools, and an `AgentServer` executing `RunInstruction` directives through `Jido.Exec`: a second execution path for tools beside `Trinity.Effects`, the bypass shape 024's census flags. Nothing the Session's six states, persist-before-broadcast rule or rehydrate need | `ls jido/lib/jido` (sensor, scheduler, agent_server, pod); `grep -n 'defmodule ' jido/lib/jido/agent/directive.ex` (Emit, Spawn, SpawnAgent, AdoptChild, StopChild, StartSensor, StopSensor, Schedule, RunInstruction, Stop, Error) |
| (c) dependency weight | `jido`: 29,820 lines, ten runtime dependencies (`jido_action`, `jido_signal`, `poolboy`, `crontab`, `time_zone_info`, `telemetry_metrics`, `nimble_options`, `splode`, `telemetry`; `jido_signal` adds `msgpax`, `memento`, `fuse`, `uniq`, `phoenix_pubsub`, `zoi`). `jido_action`: six (`jason`, `nimble_options`, `telemetry`, `zoi`, `splode`, `multigraph`), two of which the tree carries already | `find lib -name '*.ex' \| xargs cat \| wc -l`; `grep '{:' mix.exs` in each |

**Recommended at G1: actions only.** **Owner decision at G1, 2026-09-20: no Jido at all.** The one piece with
value, `Jido.Action` as the shape a tool is written in, is a few dozen lines to write and `jsv` (JSON Schema
validation) is already in the tree through req_llm; six dependencies and a census for that gain is a poor
trade, and the runtime was never a candidate on these numbers. Recorded as an appended decision on ADR-0009
(superseding the provisional decision and the "runtime is Jido v2" line, which stands as written), in
docs/02, in slice 020's spec (`Trinity.Tools.Tool` is Trinity's own behaviour) and in the standards register.
The `jido` VERSIONS row stays, marked not used, so a reader finds the decision where the package would be.
Slice 012 is unchanged: it used none of it.

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

## Lines 1 to 14, 2026-09-20: what was built, and what building it found

**Built.** `Trinity.Sessions.Events` (seven shapes, `valid?/1`, `broadcast/2` refusing any other);
`Trinity.Sessions.State` (in-memory turn only; `new_turn/0` is what a reseed starts from);
`Trinity.Sessions.Supervisor` (DynamicSupervisor, `:one_for_one`, 10 restarts a minute, `:transient` children so
an idle stop is not a restart); `Trinity.Registry` (`:unique` by session id); `Trinity.Sessions.Prompt.build/3`
(pure); `Trinity.Sessions.Session` (`gen_statem`, `handle_event_function` with `state_enter`, six states);
`Trinity.Sessions.ToolRunner` (behaviour, `Stub` answering `{:error, :no_tools}`, implementation from config);
`Trinity.Sessions.Caps` (three module attributes, `check/1` takes only the turn); `Trinity.Sessions.Sentinel`
(three families, merge never removes, outcome only tightens); `Trinity.CorePolicy.hash/0` (SHA-256 over the
object code of five named modules); the `Sessions` API (`start_session/1`, `ensure_started/1`, `whereis/1`,
`send_user_message/2`, `cancel_turn/1`, `state/1`, `subscribe/1`); `Trinity.SessionCase` and a fake provider
with global state and script sequences.

**The turn, as built.** A user message is a row, then a broadcast, then `thinking`: the model call runs in a
Task under a `Task.Supervisor` the Session starts and links (so it dies with the Session and its Tasks with it),
talking back only by message. Deltas fold into a buffer flushed by a 50 ms timer (at most 20 broadcasts a
second) and into a draft row written every 500 ms or 2 KB. At `{:llm_done, ref, {:ok, usage}}` the draft is
finalised (the one edit docs/05 now names) or the row inserted, the sentinel runs over the text and the
pending calls, and the message is broadcast; with pending tool calls and a finish of `:tool_calls` the Session
enters `tool_wait`, runs every call through `ToolRunner` in a Task, writes a `tool` row per result, checks
`Caps`, and starts the next turn. A Task crash or a provider error is an `error` turn: the partial text is the
row, `parts.error` names the reason, `error` is entered and left at once for `idle`. Cancel kills the Task
and persists the partial text as interrupted. Idle arms two generic timeouts, hibernate and stop, cancelled on
leaving idle. Rehydrate marks a draft interrupted and broadcasts it, and never resumes.

**Found while building, each recorded rather than smoothed.**

1. **A name collision with an approved slice.** 010 named the Ecto schema `Trinity.Sessions.Session`, and
   docs/01 gives that name to the process. The architecture wins: the schema is now `Trinity.Sessions.SessionRow`
   (a fix commit referencing 010 inside this slice; its moduledoc says why the suffix). The `has_many :messages`
   association then needed its foreign key named, because Ecto derives it from the new module name.
2. **The fake provider's state was process-local**, and a session's Task is not on the test's `$callers` chain,
   so scripts and failures set by a test were invisible to the turn and every test saw the default script, a tool
   call, looping to the cap. The fake now keeps global state (a persistent term, cleared in setup; these tests
   are not async) and takes a sequence of scripts consumed one per call.
3. **The factory persona named a model that is not a registry id** (`"fake:model"`), so every turn was an
   `unknown_model` error until the persona's model became nil (the registry default). Visible only by driving a
   turn by hand outside ExUnit and reading the events.
4. **`collect` stopped at the first `{:state, :idle}`**, the enter broadcast from init, before the turn began;
   `start_drained/1` in the case template drains it.
5. **A hibernating `gen_statem` reports `{:gen_statem, :loop_hibernate, 3}`** as its current function on this
   OTP, not `{:erlang, :hibernate, 3}`; the test accepts either and also asserts an empty mailbox.
6. **A row from a hand-driven probe (`mix run` on the test database) survived** outside the sandbox's rollback
   and broke a 010 list test that assumed an empty table; the test now scopes to the rows it made, and the test
   database was reset.
7. **Outcomes live in `parts`, not `provider_meta`**: `interrupted`, `error`, `cap` and `tool_calls` are about the
   message's shape; `provider_meta` keeps the sentinel's findings, the outcome and the finish reason.

**Deviations from SLICE.md**, in addition to the three stated at G1: the per-session `Task.Supervisor` is started
and linked by the Session rather than being a named child in the tree, so the tree's one name per session is
the Session itself; `Trinity.Sessions.Supervisor` has no restart counter to read (DynamicSupervisor exposes
none), so AC5 asserts the stronger thing, that every session's pid is the same after the run as before.

```
$ mix test test/trinity/sessions      → 17 passed (session, crash, many_sessions, units)
$ mix gate                            → exit 0; 155 passed, 10 excluded; plan_check: PASS
$ mix test --cover                    → 60.82% total (Session 84.39%, Caps, Sentinel, Events, CorePolicy 100%)
```

## Follow-ups
- `approval_wait` and `compacting` have no inbound transition; 021 and 023 add them.
- The recorded outcome of a cap or a sentinel hold moves to receipts at 024.
- `Trinity.LLM.Supervisor` (rate limiters) still unbuilt; nothing needs it.
