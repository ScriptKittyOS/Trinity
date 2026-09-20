# Proof for slice 012: Session process + agent loop

Agent: Trinity · Coding Agent · Date: 2026-09-20 · Branch: slice/012-session-process-agent-loop · Final commit: <closing commit>

## Summary
One supervised `gen_statem` per conversation runs the turn loop: a user row, a model call in a Task, deltas
coalesced and drafted to a row, tool calls through a stub runner, a final assistant row, idle. The two crash
tests are the slice's headline: a kill mid-stream restarts the process from the database with the draft marked
interrupted and a neighbour untouched; two kills and reseeds leave one live worker, the core policy hash unchanged
and nothing of the dead process's turn. Hard parts, all in NOTES.md: a name collision with 010's schema (renamed
to `SessionRow`, a fix referencing 010), a fake provider whose process-local state a session's Task could not see,
and a factory persona naming a model that was not a registry id. The ADR-0009 checkpoint ran at G1 with three
measurements and the owner decided: no Jido at all.

## Gate
```
$ mix gate                                   (this machine, OTP 28.5.0.5, Elixir 1.20.4, under a 32 GiB cgroup)
515 mods/funs, found no issues.
No vulnerabilities found.
Result: 155 passed, 10 excluded
trinity.coverage: 011 51.57% vs 010 44.88%: OK
plan_check: PASS
exit=0
```

## Tests
```
$ mix test --cover
Result: 155 passed, 10 excluded
|     60.82% | Total |
|     84.39% | Trinity.Sessions.Session |
|    100.00% | Trinity.Sessions.Caps, Sentinel, Events; Trinity.CorePolicy |
```
`coverage.tsv` row: `012  60.82  <sha>  2026-09-20`. `trinity.coverage: 012 60.82% vs 011 51.57%: OK`.

The seventeen tests of `test/trinity/sessions`, with timings from `--trace`:
```
test 100 concurrent sessions each complete a turn with the same pid throughout and seq 1, 2 (105.4ms)
test a failing stream (AC3) a Task that raises is an error turn too (6.3ms)
test a failing stream (AC3) the Session enters error, persists an error message, returns to idle and takes the next message (4.2ms)
test a turn (AC1) 50 deltas arrive coalesced, then the assistant message; two rows with seq and usage (2.3ms)
test a turn (AC1) a busy session refuses a second message by name (504.5ms)
test backpressure (AC7) 1,000 deltas in well under a second reach the subscriber as few broadcasts with the text intact (2.6ms)
test cancel (AC4) cancel during streaming persists the partial text as interrupted and is idle within 100 ms (54.3ms)
test Caps (M3) each cap fires in order and a fresh turn passes (2.6ms)
test Caps (M3) the caps are module attributes and the check takes only the turn (4.4ms)
test CorePolicy.hash/0 is a 64-hex sha-256 over the named modules, stable across calls (1.9ms)
test crash test A: a kill mid-stream restarts the session, keeps history, marks the draft interrupted, spares a neighbour (AC2) (775.2ms)
test Events the seven shapes and nothing else; broadcast refuses a foreign shape (10.6ms)
test idle (AC8) the process hibernates after the configured idle time and restarts on demand (302.8ms)
test kill and reseed twice: one live worker, the core policy hash unchanged, no grant, approval or pending call survives (AC9) (46.9ms)
test Prompt.build/3 is pure: the same inputs build the same request, with the persona's soul as the system prompt (2.9ms)
test Sentinel each family fires; ordinary text does not; findings only accumulate (1.5ms)
test the tool path (AC6) a tool call enters tool_wait, the stub answers with an error, a tool row is written, a final message follows (5.6ms)
```

## Acceptance criteria evidence

### AC1: 50 deltas, coalesced deltas then {:assistant_message, m}; DB has user and assistant rows with seq and usage
`a turn (AC1) 50 deltas arrive coalesced, then the assistant message; two rows with seq and usage`: the fake streams
50 deltas of `"ab "`; the subscriber receives fewer than 50 `assistant_delta` broadcasts whose join is the full
text, then `{:assistant_message, %Message{seq: 2, usage: %{"input_tokens" => 50, "output_tokens" => 50}}}`;
`history/1` returns seq `[1, 2]`; the Session is idle with an empty pending list. Every event passes
`Events.valid?/1`.

### AC2: crash test A
`crash test A: a kill mid-stream restarts the session, keeps history, marks the draft interrupted, spares a neighbour`:
two sessions stream a slow script; session A has a draft row by the time of `Process.exit(pid, :kill)`; the
supervisor restarts it (a new pid, `ensure_started/1` returns that pid); the rehydrate broadcasts
`{:turn_interrupted, %Message{id: <the draft's id>, parts: %{"interrupted" => true, "draft" => false}}}`; history is
`["user", "assistant"]` with the draft text; the new process is idle with no pending calls; session B keeps its pid
and its `thinking` state.

### AC3: crash test B
`a failing stream (AC3) the Session enters error, persists an error message, returns to idle and takes the next
message` (a permanent provider error) and `a Task that raises is an error turn too` (the fake raises inside the
Task; the Session sees `:DOWN`): states include `:error`; the assistant row carries the partial text and
`parts.error` naming the reason; the next message is accepted and completes.

### AC4: cancel_turn/1 during streaming
`cancel (AC4) cancel during streaming persists the partial text as interrupted and is idle within 100 ms`: measured
with `:timer.tc`, under 100 ms; `{:turn_interrupted, %Message{content: "start ", parts: %{"interrupted" => true}}}`;
a second cancel in idle returns `{:error, :idle}`.

### AC5: 100 sessions concurrently, no supervisor restarts, gapless seq
`100 concurrent sessions each complete a turn with the same pid throughout and seq 1, 2`: 100 rows, 100 processes,
100 turns through `Task.async_stream` at concurrency 100; every session finishes; every pid after equals the pid
before (DynamicSupervisor exposes no restart counter, so the pid identity is the measurement); every session's
seqs are `[1, 2]`.

### AC6: the tool-call path
`the tool path (AC6) ...`: the default script ends in a tool call; states include `:tool_wait`;
`{:tool_call, %{id: "call_1", name: "get_weather"}}` is broadcast; history is `["user", "assistant", "tool",
"assistant"]` with seq `[1, 2, 3, 4]`; the tool row carries `tool_call_id "call_1"`, content naming `no_tools`
and `parts.ok == false`; the first assistant row's `parts.tool_calls` carries the call with its arguments.

### AC7: backpressure
`backpressure (AC7) 1,000 deltas ...`: 1,000 single-character deltas; at most 25 delta broadcasts (asserted
`<= 25`); their join and the final row's content are the full 1,000 characters.

### AC8: idle hibernation
`idle (AC8) the process hibernates after the configured idle time and restarts on demand`: with
`idle_hibernate_ms: 200` in test config, after 300 ms `Process.info(pid, :current_function)` is
`{:gen_statem, :loop_hibernate, 3}` (what a hibernating gen_statem reports on this OTP) with an empty mailbox;
`ensure_started/1` returns the same pid; a message wakes it.

### AC9: kill and reseed twice
`kill and reseed twice: one live worker, the core policy hash unchanged, no grant, approval or pending call survives`:
with a pending tool call in process state, two kills each restart the session; after each, `state/1` shows
`idle`, `pending: []`, `turns: 0`, `draft_id: nil`; the registry holds exactly one pid for the id and the
supervisor exactly one live child for it; `Trinity.CorePolicy.hash/0` is the same 64-hex string before and after.
Grants have no home before slice 021, and the state view is the census that none is in process state.

### M3 (platform alignment): code-owned caps
`Caps (M3) the caps are module attributes and the check takes only the turn`: `Caps.check/1` exists and
`Caps.check/2` does not; no key under the `:trinity` application environment names a cap; each cap fires in order.

## Manual verification for the reviewer
None. Every criterion is `[auto]`.

## Deviations from SLICE.md
See NOTES.md: `CorePolicy.hash/0` arrives here; outcomes on `parts` and `provider_meta` until 024's receipts;
`approval_wait` and `compacting` present and unreachable; the per-session Task supervisor is started by the Session
rather than named in the tree; AC5 asserts pid identity instead of a restart count. And the ADR-0009 checkpoint
outcome, decided by the owner at G1: no Jido.

## Versions touched
`VERSIONS.md` updated: yes, the `jido` row now reads not used (ADR-0009, decided 2026-09-20). No pin moved.

## Git
```
$ git log --oneline main..HEAD
be6e70d feat(s012): the session process and the agent loop
019d9cf docs(s012): ADR-0009 decided at the checkpoint: no Jido at all
6dffc53 docs(s012): G1 plan with the ADR-0009 checkpoint measured, and the slice opens
<closing commit>
```
