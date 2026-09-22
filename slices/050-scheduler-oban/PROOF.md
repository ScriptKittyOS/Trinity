# Proof for slice 050: Scheduler: Oban cron agent tasks with delivery targets

Agent: Trinity · Coding Agent · Date: 2026-09-22 · Branch: slice/050-scheduler-oban · Final commit: (the commit carrying this file; named in the closing correction)

## Summary
Oban on the app's own database (the Lite engine on SQLite, Basic on Postgres), a `tasks` row per
scheduled prompt with the time it next runs computed by `Trinity.Scheduler` from a cron expression or a
one-shot datetime, one Cron plugin entry a minute (`Workers.Tick`) enqueuing a `RunTask` for what is due
(unique on the task and the scheduled time), each run a turn in a fresh `origin: "cron"` session with the
run row carrying the summary, Oban's retry then a failed run, the desktop delivery (a results list on
`/tasks` until read), a phrase-to-cron helper checked by Oban's parser, the observer as a job on the
`memory` queue, a curator on the `maintenance` queue that marks and archives and never deletes, the
`/tasks` page and Oban Web at `/oban`. The SLICE's risk measured (Oban polling against the single
writer: a fifth off the write storm's throughput, no error). Five deviations and five findings in NOTES.md.

## Gate
```
$ mix gate                                   (tree c01466d, before this file and the coverage row were added, this machine, OTP 28.5.0.5, Elixir 1.20.4, under a 32 GiB cgroup)
2657 mods/funs, found no issues.
... SCAN COMPLETE ...
No retired or security advisory packages found
No vulnerabilities found.
versions.verify: OK. 106 locked packages, none disagreeing with 54 pins
versions.gen: VERSIONS.md already matches Trinity.Versions and mix.lock
trinity.version_form: OK
trinity.names: OK over 662 tracked files
trinity.secrets.scan: OK over 662 files
trinity.reuse: OK. Every commentable tracked file carries an SPDX header
Result: 501 passed, 18 excluded
trinity.coverage: 061 80.05% vs 060 80.32%: OK
plan_check: PASS
exit=0
```
CI: named in the closing correction.

## Tests
```
$ mix test --cover                           (tree c01466d)
Result: 501 passed, 18 excluded
|     77.19% | Trinity.Scheduler                      |
|     77.97% | Trinity.Scheduler.Workers.RunTask      |
|     83.33% | Trinity.Scheduler.Workers.Tick         |
|     88.24% | Trinity.Scheduler.Task                 |
|     81.25% | Trinity.Scheduler.Parse                |
|    100.00% | Trinity.Scheduler.Delivery.Desktop     |
|     93.75% | Trinity.Memory.Curator                 |
|     80.00% | Trinity.Memory.ObserverWorker          |
|     80.31% | Total                                  |
```
`coverage.tsv` row: `050  80.31  c01466d  2026-09-22` (from 80.05 at 061: up a quarter)

The gate line `trinity.coverage: 061 80.05% vs 060 80.32%` is the gate run before this row was appended; `mix trinity.coverage` on the row reads `050 80.31% vs 061 80.05%: OK``.

The slice's tests (`mix test test/trinity/scheduler test/trinity_web/live/tasks_live_test.exs --trace`):
```
* test the form adds a task; the list shows it with its next run; a bad schedule shows its error; edit, disable, remove
  * test run now queues a run; when it finishes the result is listed until marked seen; the run history shows it with its conversation
  * test Oban Web is mounted at /oban
  * test the suggest form fills the schedule from the model's answer
  * test stale at 30 days with a query receipt, archived at 90 with an effect receipt, fresh untouched, nothing deleted; the archived entry leaves recall
  * test an archived semantic entry leaves the semantic entries and the brute store's search
  * test the observer enqueues a memory job carrying the message ids and not their text; the job runs run/2
  * test AC1: creating a task with */5 * * * * computes the next boundary; the tick at that time enqueues one RunTask, unique on task and time; perform_job runs it
  * test AC2 (automatic half): the run is a turn in a fresh cron session titled after the task; the run row carries the summary; the desktop delivery marks it and broadcasts
  * test AC4: the human schedule helper turns a phrase into cron through the model and refuses an answer that does not parse; a cron phrase passes through
  * test a one-shot task runs once at its time and is then disabled; a schedule that does not parse is refused
  * test AC5: a job inserted before Oban stops runs after Oban starts again
  * test AC3: a failing turn is an error Oban retries; the run reads retrying, then failed with the error on the last attempt
Result: 13 passed
```

## Acceptance criteria evidence

### AC1 [auto]: Creating a task with `*/5 * * * *` inserts a cron entry; `Oban.Testing.assert_enqueued` / `perform_job` runs it
`scheduler_test.exs` "AC1": the task's `next_run_at` is the next five-minute boundary; a tick a second
before it enqueues nothing; `perform_job(Tick, %{"now" => at})` enqueues one `RunTask` with the task and the
time (`assert_enqueued`), writes one `queued` run, and advances the task by five minutes; a second tick for
the same minute enqueues nothing more (one run, one job); `perform_job(RunTask, …)` runs the FakeProvider
turn and the run reads `ok` with its summary. The design (the tick, not the plugin's static table) is in
NOTES.md "Read before code".

### AC2 [manual]: `RunTask` creates a session with `origin: "cron"`, completes a FakeProvider turn, records a `task_runs` row with summary, and delivers a desktop notification (test + screenshot)
The test: `scheduler_test.exs` "AC2 (automatic half)": the session row (`origin: "cron"`, the task's name as
its title, the task's persona, `origin_ref` with the task and run ids), the history (the prompt with the
skills line, the assistant's answer), the run (`ok`, the summary, `delivered_at`), the `{:task_run, run}`
broadcast, the run among `unseen_runs/0` until `mark_seen/1`, the task's `last_run_at`. The screenshot:
`proof/ac2-results-list.png` (the "Results" list on `/tasks` after "run now": the task's name, the time,
`ok`, the summary, "open the conversation", "seen"; the bar's "1 result to read"), taken with
`scripts/dev_tasks.sh` and a headless browser.

### AC3 [auto]: A failing turn retries per policy then marks the run failed with the error
`scheduler_test.exs` "AC3": with the provider failing, `perform_job(RunTask, args, attempt: 1)` returns
`{:error, text}` and the run reads `retrying` with the error; `attempt: 3` (the worker's `max_attempts`)
marks it `failed` with `finished_at` and delivers the failure (the results list shows it in red).

### AC4 [auto]: Human schedule "every weekday at 9am" → `0 9 * * 1-5`
`scheduler_test.exs` "AC4": with the fake's object scripted to `0 9 * * 1-5`, `Parse.human/1` answers it;
scripted to "at nine on weekdays", the answer is refused as `{:not_cron, …}` (Oban's parser is the check);
`@daily` and a padded expression pass through without the model; a blank is `:empty`. The page's "suggest"
form fills the schedule (`tasks_live_test.exs`).

### AC5 [auto]: App restart with a due job pending → job runs after restart
`scheduler_test.exs` "AC5": a `RunTask` job inserted; an Oban instance with a live `agent_tasks` queue
(`testing: :disabled`, the Lite engine, on the test's connection) started and stopped while the run is
still `queued`; started again, the job runs and the run reads `ok` within the wait. The job is a row; the
restart is Oban's supervisor's.

### AC6 [manual]: Memory observer runs as an Oban job and is visible in Oban Web (screenshot)
The test half: `curator_test.exs` "the observer enqueues a memory job": `observe/2` enqueues
`Trinity.Memory.ObserverWorker` on the `memory` queue with the turn and the message ids and none of the
text; `observer_test.exs` (032) drains the queue and the extraction runs. The screenshots:
`proof/ac6-2-oban-jobs.png` (Oban Web's completed jobs after one task run with the observer on:
`Trinity.Memory.ObserverWorker` on `memory` with `message_ids` in its args, `RunTask` on `agent_tasks`,
`Tick` on `maintenance`) and `proof/ac6-1-oban-queues.png` (the three queues).

### AC7 [manual]: Create a "daily summary of my notes dir" task, run now, see the result (GIF)
`proof/ac7-daily-summary-task.gif`: the task created on `/tasks` (name, `0 9 * * *`, the prompt), "run now",
the result appearing in the list, the run history opened, the conversation opened; the frames
`proof/ac7-1-task-created.png`, `proof/ac7-2-run-history.png`, `proof/ac7-3-conversation.png`. The model
is the fake provider scripted with a summary (`scripts/dev_tasks.sh`): the flow is the criterion, the
words are the script's, and a real provider run is the same page with a slower answer.

### The curator (scope, added 2026-09-20)
`curator_test.exs`: at 31 days `stale_at` and one query receipt on the persona's memory scope; at 91 days
`archived_at` and one effect receipt (phase `done`, the entry); a fresh entry untouched; three rows before
and after (nothing deleted); the archived entry absent from the always-on chain and from the semantic
entries and the brute store's search; a second run changes nothing.

## Manual verification for the reviewer
AC2, AC6 and AC7 are the screenshots and the GIF above; `scripts/dev_tasks.sh` reruns the page with Oban's
queues live (`PORT=` printed) for a look at `/tasks` and `/oban`.

## Deviations from SLICE.md
NOTES.md: the G1 decisions (the tick; a run's approvals expire unanswered) and five found building (the
test pool of two; AC1 read as the tick; the 032 test draining the queue; Oban Web's mount asserted on the
router; the dashboard route mounted in the suite).

## Versions touched
`VERSIONS.md` updated: yes, by `mix versions.gen`: `oban` from 🔍 to ✅ in `mix.lock` (2.24.1) and a new row
`oban_web` ✅ (2.13.0; Apache-2.0 on hex.pm, which the 2026-09-05 plan did not know); `oban_met` 1.3.1 comes
with it (Apache-2.0). `mix versions.verify`: named in the gate output above.

## Git
```
$ git log --oneline main..HEAD
(named in the closing correction, after the final commit)
```

## Closing correction, 2026-09-22

Supersedes "named in the closing correction" above. The tree the PR is merged from is `abcfcd0`; the code
is `e382fc0` (`feat(s050): complete slice 050`, the commit carrying this file) plus `abcfcd0` (the postgres
job's adapter check run with `--no-start`: its first run, 35711666503, booted the application before
`ecto.reset` and Oban refused to start without its table; the SQLite suite never hits that because its
`mix test` alias migrates first). On `abcfcd0`, CI run 35712404770: `gate` success (501 passed, 18
excluded), `postgres` success (481 passed, 38 excluded; the Basic engine and Oban's Postgres migration
on that leg), `fips-tag` and `fips` success (506 passed, 13 excluded; the six FIPS tests by name); the
`push` event's run 35712400033 the same numbers. The coverage row stays at `c01466d` (80.31%): the
commits after it change this file, the workflow, ROADMAP.md and coverage.tsv only.

```
$ git log --oneline main..HEAD
abcfcd0 ci(s050): the adapter check runs without booting the application (Oban needs its table first)
e382fc0 feat(s050): complete slice 050 (scheduler with Oban cron agent tasks)
c01466d chore(s050): VERSIONS.md regenerated (oban, oban_web rows in mix.lock)
228e361 docs(s050): deviations, findings at G3 (the stress measurement with Oban polling), follow-ups
4d7dd97 docs(s050): AC2, AC6 and AC7 proof (the results list, Oban Web with the three workers, the task's GIF); the dev script
89f5249 docs(s050): docs 01, 05, 07 and the README as built
9be8540 test(s010): the pool-size property reads the shipped configuration (the suite's pool is two for Oban's boot check)
384d2c0 feat(s050): the /tasks page (list, form with suggest, run now, results to read, run history), Oban Web at /oban; the curator and observer tests
2152a5d feat(s050): Oban on the app's repo; tasks and runs; the tick, the run worker, the desktop delivery, the schedule helper; the observer as a job; the curator; AC1 to AC5 green
b73184a docs(s050): G1 plan; oban and oban_web pinned and fetched
```
