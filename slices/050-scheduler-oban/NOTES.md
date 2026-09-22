# Slice 050: NOTES

## Read before code, 2026-09-22

Tree at `eecb7b8` on `main` (061 approved). What this slice joins: 012's Session (a session row with an
`origin` from the closed vocabulary, `cron` among them; `send_user_message/2`; the `{:state, :idle}`
broadcast on its topic when a turn ends), 032's observer (`Trinity.Memory.Observer.observe/2` runs `run/2`
under a task supervisor after each turn; off in the suite), 024's receipts (a query receipt for a read, an
effect receipt written by the promotion path itself at 041: the pattern a non-tool write takes), 041's
skills (the prompt's skills index; a task names skills to hint), and the compile-time adapter choice
(ADR-0002: SQLite primary with a pool of one writer, Postgres on the CI leg).

Measured today: oban 2.24.1 on hex.pm (Apache-2.0), oban_web 2.13.0 (Apache-2.0: the 2026-09-05 plan wrote
it in as a commercial package and it is not one any more), oban_met 1.3.1 (Apache-2.0, oban_web's
dependency). `Oban.Engines.Lite` is the SQLite engine and `Oban.Migration` picks `Oban.Migrations.SQLite`
by the repo's adapter; `Oban.Cron.Expression.parse/1` is Oban's own cron parser, so no crontab package is
added. Oban's open-source Cron plugin takes a static table at configuration time: a task's own schedule
cannot be a plugin entry, and Oban Pro's dynamic cron is out of scope, so the design below ticks.

Decisions at G1, open to the owner's veto in this turn:

- **Schedules are the tree's, not the plugin's.** A `tasks` row carries a cron expression or a one-shot
  ISO datetime and a `next_run_at` the context computes with Oban's parser. One Cron plugin entry, every
  minute, runs `Trinity.Scheduler.Workers.Tick`, which enqueues a `RunTask` job for every enabled task
  whose `next_run_at` has passed, unique on `(task_id, scheduled_at)` (the SLICE's idempotency key, as
  Oban's `unique` option on the job's args and as the `task_runs` unique index), and advances
  `next_run_at`; a one-shot task is disabled once enqueued. AC1's "inserts a cron entry" is read as: the
  task carries its cron and the tick enqueues it when due; the test drives the tick at a chosen time.
- **A run is one turn in a fresh `origin: "cron"` session** titled after the task, the persona the task
  names (the default when none), the prompt as the user message with a line naming the task's skills
  (the skills index already shows them; the line asks the model to use them). The worker subscribes to
  the session's topic, sends the message, waits for `:idle` (the task's `timeout_ms`, 10 minutes by
  default), reads the last assistant message as the summary (its first 2,000 bytes) and marks the run.
  A tool call that asks in a cron session has nobody at the desk: the approval waits its expiry (021,
  ten minutes by default) and the turn goes on with the denial, which the run's summary shows.
- **Failure is Oban's retry, then a failed run.** A turn that raises, times out or ends in the session's
  error state returns `{:error, reason}`; Oban retries under the worker's `max_attempts` (3) with its
  backoff; the run row is `failed` with the error text on the last attempt (`attempt == max_attempts`),
  `retrying` before that.
- **Delivery is a behaviour with one implementation.** `Trinity.Scheduler.Delivery` (`deliver/2`);
  `Trinity.Scheduler.Delivery.Desktop` marks the run `delivered_at`, broadcasts `{:task_run, run}` on the
  `tasks` topic, and the `/tasks` page shows the runs not yet seen as the notifications list with a count
  in the bar (the pending-approvals badge's shape); `seen_at` is set from the page. Gateways add
  implementations at 070; `deliver_to` on the row is `%{"kind" => "desktop"}` until then.
- **The observer becomes a job on the `memory` queue** (032 is approved, so AC6 stands): `observe/2`
  enqueues `Trinity.Memory.ObserverWorker` with the turn and the message ids; the worker reloads the
  messages from the session's history and calls `run/2` as before; `max_attempts` 3. `run/2` keeps its
  contract (032 AC3's test calls it), and `observer: false` keeps the suite quiet.
- **The curator on the `maintenance` queue**, a Cron plugin entry daily at 03:00: a `memories` row
  untouched (`last_used_at`, else `updated_at`) for 30 days is marked stale (`stale_at`, a query receipt on
  the persona's memory scope), one untouched for 90 days is archived (`archived_at`, an effect receipt
  written by the curator as 041's promotion writes its own, subject the entry, phase `done`); nothing is
  deleted; the thresholds are `config :trinity, :curator` with those defaults. Archived entries leave
  recall (the always-on chain and the semantic search filter them); stale ones stay and are shown as such.
  Two new columns on `memories`, no new table.
- **Oban runs on the app's repo with its pool of one writer.** Oban Lite polls its queues (the producers'
  `poll_interval`, 1 s by default) through the same pool as the app; the SLICE's risk (contention with the
  app's writes under the 010 stress test) is measured at G3 and the interval set from the measurement.
  Queues: `agent_tasks: 1` (one turn at a time: the machine's model is one), `memory: 2`, `maintenance: 1`.
  `Oban.Plugins.Pruner` keeps the jobs table to a week; `Oban.Plugins.Lifeline` rescues an orphaned
  executing job after a crash.
- **Oban Web at `/oban`** in dev, and elsewhere behind `config :trinity, :oban_web, true`, in the browser
  pipeline (the pages carry no authentication yet; the same rule as the rest of the pages).
- **The human schedule helper** asks the session's default model for `%{"cron" => …}` with
  `Trinity.LLM.generate_object/3` and accepts the answer only when `Oban.Cron.Expression.parse/1` does; a
  phrase that already parses as cron is returned as is, and the page's form offers "suggest".

## G1 plan, 2026-09-22

Branch `slice/050-scheduler-oban`; ROADMAP row 050 to `in_progress` in this commit; `oban ~> 2.24`,
`oban_web ~> 2.13` in mix.exs and `VERSIONS.md`. Each line names its test.

1. Migrations: Oban's (`Oban.Migration.up/1`, both adapters), `tasks` (docs/05: `name`, `schedule`,
   `kind` (`cron | once`), `prompt`, `persona_id`, `skill_names`, `deliver_to`, `enabled`, `timeout_ms`,
   `last_run_at`, `next_run_at`), `task_runs` (`task_id`, `scheduled_at`, `session_id`, `status` (`queued |
   running | retrying | ok | failed`), `attempt`, `summary`, `error`, `started_at`, `finished_at`,
   `delivered_at`, `seen_at`; unique on `(task_id, scheduled_at)`), and `memories` gains `stale_at` and
   `archived_at`. Schemas `Trinity.Scheduler.Task` and `Trinity.Scheduler.Run`.
2. Oban in `Trinity.Application` (engine by adapter, the queues, the plugins: Cron with the tick and the
   curator, Pruner, Lifeline), `testing: :manual` in the suite; `Trinity.Scheduler` context (`tasks` CRUD,
   `schedule/1` computing `next_run_at`, `run_now/1` enqueuing a `RunTask` at once, `runs/1`). Tests AC1
   (a task with `*/5 * * * *` carries the next five-minute boundary; the tick at that time enqueues
   `RunTask` with the task and the time, asserted with `Oban.Testing`; `perform_job` runs it).
3. `Trinity.Scheduler.Workers.Tick` and `Trinity.Scheduler.Workers.RunTask` (the session, the turn, the
   wait, the run row, the delivery). Tests AC2 (the automatic half: a `FakeProvider` turn, the `cron`
   session, the run row's summary, the delivery's broadcast and `delivered_at`) and AC3 (a turn whose
   provider raises: `{:error, _}`, the run `retrying`, then `failed` with the error on the last attempt).
4. `Trinity.Scheduler.Delivery` and `Delivery.Desktop`; the `tasks` topic. Tested under AC2.
5. `Trinity.Scheduler.Parse.human/2`: the LLM call and the parser check. Test AC4 with the fake's
   scripted object (`0 9 * * 1-5` for "every weekday at 9am"; a scripted answer that does not parse is
   refused; a phrase that is already cron passes through).
6. AC5: a test with its own Oban instance (`testing: :disabled`, the Lite engine on the sandbox
   connection, `agent_tasks: 1`): a `RunTask` job inserted, the instance stopped, started again, the job
   runs and its run row is `ok`.
7. `Trinity.Memory.ObserverWorker` on the `memory` queue and `observe/2` enqueuing it. Test: `observe/2`
   enqueues the job with the turn and the ids; `perform_job` on it runs `run/2` (the 032 test's fake).
8. `Trinity.Memory.Curator` on the `maintenance` queue. Tests: an entry 31 days old gets `stale_at` and a
   query receipt; one 91 days old gets `archived_at` and an effect receipt; a fresh one is untouched;
   nothing is deleted; an archived entry is absent from `AlwaysOn.entries/2` and from the semantic search.
9. `/tasks` LiveView: the list, the form (name, schedule with "suggest" from a phrase, prompt, persona,
   skills, enabled), run now, the run history with session links, the notifications list and the bar's
   count; `/oban` mounted in dev and behind the flag. LiveView tests for the list, the form and run now.
10. docs/05 as built, docs/01 (the `Trinity.Scheduler` boundary), docs/07 (a cron session's approvals
    expire unanswered), README (`/tasks`, `/oban`, the Automates bullet's first half); PROOF; the ROADMAP
    row; the stress measurement with Oban running (the SLICE's risk).

Manual verification queue: **AC2** (a screenshot of the notifications list after a run), **AC6** (the
observer's job in Oban Web, a screenshot), **AC7** (a "daily summary of my notes dir" task created on the
page, run now, the result: a GIF). All three are taken here with the dev-run scripts and the headless
browser, as 060 and 061's were; the owner's queue is to look.

Not built here: Oban Pro, multi-step workflows, gateway deliveries (070), a task's own approval channel
(a cron session's approvals expire, recorded above), Oban Web behind authentication (the pages have none
yet; 062).

## Deviations while building, 2026-09-22

- **The suite's SQLite pool has two connections, not one.** Oban verifies its migration at start through
  a raw checkout (`Oban.Migration.verify_migrated!/1`, `Sandbox.unboxed_run`), and at that moment the
  sandbox is still in auto mode with the first long-lived boot process holding the one connection until
  it exits: Oban waited 90 s and the application failed to start. `config/test.exs` gives the test pool a
  second connection for that check; every test still shares its owner's single connection with every
  process it starts, which is 010's property, and 010's pool-size test now reads the shipped
  configuration from `config/config.exs` under the production environment (one connection, as before).
- **AC1's "inserts a cron entry" is the tick's design**, decided at G1: the task carries its cron and its
  next time; the tick enqueues it when due. The test drives the tick at the task's boundary.
- **032's observer-through-session test drains the memory queue** instead of waiting for a task's row,
  since the observer is a job now and the suite runs Oban manually.
- **Oban Web's LiveView cannot mount in the suite** (it awaits `Oban.Met`, which Oban does not start in
  manual testing mode); the route's mount is asserted on the router, and the page is AC6's screenshot.
- **The dashboard route is mounted in the suite** through `config :trinity, :oban_web, true` in
  config/test.exs, so the mount is a test and not a dev-only line.

## Findings at G3, 2026-09-22

1. **The SLICE's risk, measured: Oban's polling against the app's single writer.** `scripts/stress_010.exs`
   in the dev environment, Oban's three queues polling at the Lite engine's default interval (1 s) and the
   plugins running: `appends=4000 errors=0 wall_ms=1559 appends_per_s=2565.7 integrity=ok
   wal_bytes=4165352 gapless=true sqlite=3.53.4`, against 3012.1 and 3420.3 appends per second at 010
   (its two runs, on that tree, without Oban). No error, no lost append, the WAL the same size; a
   throughput a fifth lower under a write storm no session produces. The poll interval stays at the
   default; the number is here to set it from if a later slice needs to.
2. **Three workers, one dashboard.** After one run of the "daily summary" task with the observer on,
   `/oban/jobs` lists the completed `Tick` (maintenance), `RunTask` (agent_tasks) and `ObserverWorker`
   (memory, the message ids in its args and no text), each once (`proof/ac6-2-oban-jobs.png`).
3. **The session's first `:idle` is the process's, not the turn's.** A fresh session broadcasts `:idle`
   when it starts; the worker waiting for the turn's end read that one and finished with no summary.
   `RunTask` drains the start's idle before it sends the message (the SessionCase's `start_drained`
   is the same lesson from 012).
4. **`Oban.Cron.Expression.next_at/2` answers whole minutes** and an ISO string carries whatever it
   carried; the columns are microsecond, so the context normalises every datetime it stores.
5. **Two flakes recorded on 061's branch did not recur here**: the suite ran clean three times locally
   (500, 501 with the new tests); CI's numbers are in the closing correction.

## Follow-ups

- 070: gateway deliveries implement `Trinity.Scheduler.Delivery` and name their kind in `deliver_to`.
- 062: Oban Web and the tasks page behind authentication with the rest of the pages.
- A task's approvals: a cron session's tool call that asks is denied at expiry; a delivery that carries
  the pending approval to a gateway (070) or a longer expiry per task is the next step if it bites.
- The poll interval (finding 1) is a knob without a need yet.
