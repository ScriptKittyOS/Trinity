# Slice 081 — A2A v1.0 Agent Card and task intake (optional)

| Field | Value |
|---|---|
| Phase | 8 Orchestration |
| Milestone | — (optional, post-M6) |
| Size | M |
| Depends on | 080, 061 |

## Goal
Publish an A2A v1.0 Agent Card and accept A2A tasks, mapping an inbound task to a Trinity subagent with a
restricted toolset and returning artifacts; outbound A2A delegation to other agents behind `delegate` with the
same scope rules. Status: planned, not scheduled; exists so the roadmap names it.

## Acceptance criteria (sketch)
1. [auto] Agent Card served at the A2A well-known path with Trinity's skills as A2A skills.
2. [auto] A test A2A client submits a task; Trinity runs it as a subagent; task states follow the A2A lifecycle; artifacts returned.
3. [auto] Every effect inside an A2A task crosses `Trinity.Effects` and is receipted with `origin: "a2a"`.

## Scope
**In:**
- Agent Card served at the A2A well-known path, Trinity's skills mapped to A2A skills.
- Inbound task intake mapped to a subagent with a restricted toolset; A2A task lifecycle honoured; artifacts returned.
- Outbound delegation to other agents behind `delegate`, same scope rules.
**Out:**
- Anything not required to accept and complete one task end to end.

**Status: optional and not scheduled.** It carries no milestone. This file exists so the roadmap names the option; it is not queued work.

## Deliverables
- `lib/trinity/a2a/*`, well-known route, tests with a test A2A client.

## Proof required
- For each acceptance criterion: the command and its output, or a test name and its result, or a screenshot under `proof/`. A sentence is not proof.

## Manual verification queue
None. Every acceptance criterion in this slice is `[auto]` and is proven by a command or a test.
If that changes during the slice, the criterion is retagged and this section is filled at G1.

## Definition of Done
- [ ] `mix gate` green · [ ] AC1–3 proven · [ ] docs/ADR/VERSIONS updated if affected · [ ] ROADMAP status → done · [ ] final commit + tag

## Commit & tag
`feat(s081): complete slice 081 — A2A agent card` · tag `slice/081`
