# Slice 080 — Subagents + delegation

| Field | Value |
|---|---|
| Phase | 8 Orchestration |
| Milestone | M5 Always-on |
| Size | M |
| Depends on | 020, 023 |

## Goal
A `delegate` tool that spawns supervised child sessions (subagents) with a scoped brief, restricted toolsets,
their own token budget and timeout, optional parallel fan-out, and returns a structured result to the parent
without polluting the parent's context — with live visibility of the subagent tree in the UI and the ability to
cancel a branch.

## Why
Zero-context-cost delegation, done with OTP processes and message passing rather than subprocess RPC.

## Scope
**In:**
- `Trinity.Subagents` context: `delegate(parent_session, brief, opts)` → child session (`origin: "subagent"`, `parent_id`), run under `Trinity.Subagents.Supervisor` with a monitor; result = final assistant message + optional structured object (`generate_object` at the end if `schema` provided); budget (max tokens/turns/time) enforced; cancel propagates.
- `delegate` tool (risk `:read`; but the child inherits the parent's permission scope, and approvals from children surface in the parent's UI/gateway with the child id).
- Parallel: `delegate_many(briefs)` runs N children concurrently under `Task.Supervisor` with a concurrency cap; results aggregated.
- Context isolation: child gets persona + brief + explicitly passed context snippets only.
- UI: subagent tree panel in the session view (status, tokens, cancel); child sessions browsable.
**Out:**
- Cross-node subagents (distributed Erlang) — noted as a follow-up; design keeps pids opaque.

## Acceptance criteria
1. [auto] Parent delegates a brief; child completes with FakeProvider; parent receives a `tool` message containing the child's structured result; parent's history does not include the child's messages (test).
2. [auto] `delegate_many` with 5 briefs and cap 2 → at most 2 run concurrently (test with timing/Sleep tool) → all results returned.
3. [auto] Child exceeds budget → terminated; parent gets a budget error result; parent continues (test).
4. [auto] Killing a child process → supervisor restarts it once (configurable) then reports failure (test).
5. [auto] Cancel from UI cancels the whole subtree within 200 ms (test).
6. [auto] Approval raised in a child appears in the parent's approval stream with the child id (test).
7. [manual] UI screenshot of the tree during a run.

## Definition of Done
- [ ] gate green · [ ] AC1–7 proven · [ ] docs/01 synced · [ ] ROADMAP → done · [ ] commit + tag

## Commit & tag
`feat(s080): complete slice 080 — subagents and delegation` · tag `slice/080`
