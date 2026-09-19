# Slice 050: Scheduler: Oban cron agent tasks with delivery targets

| Field | Value |
|---|---|
| Phase | 5 Automation |
| Milestone | M5 Always-on |
| Size | M |
| Depends on | 012 |

## Goal
Oban running on the app DB (Lite engine on SQLite; standard on Postgres); durable agent tasks (`tasks` table)
that run a prompt in a fresh or designated session on a cron/one-shot schedule, optionally with skills attached,
and deliver the result to the desktop UI (and later gateways); the memory observer and other background work move
onto Oban queues; a tasks UI with run history and manual "run now".

## Why
Scheduled work as durable, retried, observable jobs rather than entries in a config file (Vision goal 8 and the "always-on" milestone).

## Scope
**In:**
- Oban config (queues: `agent_tasks`, `memory`, `maintenance`), Lite engine on SQLite, Cron plugin for system jobs (reindex, prune), Oban Web mounted at `/oban` (dev; behind a flag in prod).
- `Trinity.Scheduler` context: `tasks` CRUD, `schedule/1` (converts cron expr or one-shot to Oban insert / cron plugin entry), `run_now/1`, `task_runs` history.
- `Trinity.Scheduler.Workers.RunTask`: creates/uses a session with `origin: "cron"`, runs one turn with the prompt (+ skill hints), waits for completion via PubSub with timeout, records summary, delivers via `Trinity.Scheduler.Delivery` behaviour (`Desktop` impl now: notification list in UI; gateways add impls in 070).
- Natural-language schedule helper: `Trinity.Scheduler.Parse.human("every weekday at 9am")` → cron (LLM-assisted with `generate_object`, validated by a cron parser).
- Memory observer (032) becomes an Oban worker on `memory` queue; retry policy defined. *If 032 is not yet approved when this slice runs, skip this item here and do it in 032 (note in NOTES.md); AC6 is then waived.*
- UI: `/tasks` list, create/edit form, run history with links to the sessions.
**Out:**
- Oban Pro; multi-step workflows (modelled later via chained jobs if needed).

## Design notes
- One SQLite file for both app and Oban is fine with a single writer pool; watch `busy_timeout`. Document.
- Task runs are idempotent by `(task_id, scheduled_at)` unique key.

## Deliverables
- Oban config + migration, `lib/trinity/scheduler/*`, workers, delivery behaviour, UI, tests using `Oban.Testing`.

## Acceptance criteria
1. [auto] Creating a task with `*/5 * * * *` inserts a cron entry; `Oban.Testing.assert_enqueued` / `perform_job` runs it (test).
2. [manual] `RunTask` creates a session with `origin: "cron"`, completes a FakeProvider turn, records a `task_runs` row with summary, and delivers a desktop notification (test + screenshot of notifications list).
3. [auto] A failing turn retries per policy then marks the run failed with the error (test).
4. [auto] Human schedule "every weekday at 9am" → `0 9 * * 1-5` (test with FakeProvider scripted output + parser validation).
5. [auto] App restart with a due job pending → job runs after restart (test using Oban's persistence).
6. [manual] Memory observer runs as an Oban job and is visible in Oban Web (screenshot).
7. [manual] Manual: create a "daily summary of my notes dir" task, run now, see the result (GIF).

## Proof required
- Tests, screenshots, GIF.

## Manual verification queue
Every `[manual]` criterion below needs a person. Listed here so the owner sees the queue at G1 rather
than at review time.
- **AC2**: `RunTask` creates a session with `origin: "cron"`, completes a FakeProvider turn, records a `task_runs` row with summary, and delivers a desktop….
- **AC6**: Memory observer runs as an Oban job and is visible in Oban Web (screenshot).
- **AC7**: Manual: create a "daily summary of my notes dir" task, run now, see the result (GIF).

## Definition of Done
- [ ] gate green · [ ] AC1–7 proven · [ ] docs/05 synced · [ ] VERSIONS (oban ✅) · [ ] ROADMAP → done · [ ] commit + tag

## Commit & tag
`feat(s050): complete slice 050 (scheduler with Oban cron agent tasks)` · tag `slice/050`

## Risks / open questions
- Oban Lite + `ecto_sqlite3` pool contention with the app's writes: measure under the 010 stress test with Oban running.
