# Slice 010: NOTES

## G1 plan, 2026-09-20

Tree at `68000bc` on `main`; branch `slice/010-core-domain-persistence`; ROADMAP row set to `in_progress` in
this commit (docs/04 lifecycle, plan_check rule 11). Machine: Ryzen AI Max+ 395, OTP 28.5.0.5, Elixir 1.20.4,
ecto_sqlite3 and exqlite as locked. Every line below names its test or command; the order is the build order.

1. **Gate follow-up first, its own commit:** `plan_check` rule 12 parses every `.github/**/*.yml` and
   `.github/dependabot.yml` with the Python YAML module the ubuntu runner and this machine both carry
   (pyyaml 6.0.1 here); red demonstrated on a planted bare colon (the defect PR #7 fixed), then green.
2. Repo config: `journal_mode: :wal`, `synchronous: :normal`, `busy_timeout`, `wal_auto_check_point` named in
   config; write pool of size 1 (`Trinity.Repo`) and a read pool; `Trinity.Repo.Receipts` declared with the same
   adapter and not started (the slot the 2026-09-20 amendment reserves). Test: the pragmas read back from a
   connection (`PRAGMA journal_mode`, `PRAGMA synchronous`).
3. `TRINITY_DB=postgres` branch in `config/runtime.exs` with `postgrex` as an optional dependency; a CI matrix
   job with a Postgres service running `mix ecto.reset` and the suite. Test on both: the migrations apply.
4. Data-dir lock: `Trinity.DataDir.Lock` writes `<data_dir>/LOCK` carrying pid, mode (`desktop | headless`) and
   a monotonic token, taken with `:file.open` exclusive create plus a liveness check on the recorded pid; a
   second boot against a held dir refuses to start naming holder pid and mode and touches no database file.
   Test: two applications in one VM cannot both own the dir; the refusal message names the holder (AC6).
5. Migrations: `personas` (name unique, soul, model, settings), `sessions`, `messages` per docs/05, UUIDv7 ids
   from a small generator in `Trinity.UUID` (no new dependency; tested against RFC 9562's version and variant
   bits and for monotonic ordering within a millisecond).
6. `Trinity.Sessions.Store` (queries) behind `Trinity.Sessions` (`create_session/1`, `get_session/1`,
   `list_sessions/1`, `append_message/2`, `history/2`, `archive/1`); `boundary` on `Trinity.Sessions` with
   `exports: [Trinity.Sessions]` so `Store` is internal. Test for AC5: a module under `test/support` that calls
   `Store` from `TrinityWeb` fails `mix compile --warnings-as-errors` (output pasted).
7. `append_message/2`: one transaction reading `max(seq)` and inserting; on Postgres `SELECT ... FOR UPDATE` on
   the session row. Changeset refuses unknown roles and empty content (AC3). `history/2` ordered by `seq` with
   `limit` and `offset` (AC4).
8. Factories in `test/support/factory.ex` (no `ex_machina`; plain functions).
9. Stress test (AC2): 20 processes, 200 appends each, 5 sessions; gapless `seq` per session; no `SQLITE_BUSY`
   surfaced; `PRAGMA integrity_check` returns `ok`; run on both adapters; the `-wal` file size reported after
   the run (the 2026-09-20 risk line).
10. `mix ecto.reset` on SQLite and on Postgres in CI (AC1), log excerpts in PROOF.md.
11. Coverage line and `mix gate` (AC7); docs/05 synced with any column the migrations add.
12. PROOF.md from the template; ROADMAP row to `done`; final commit and tag per CLAUDE.md section 4, through a
    pull request as the ruleset requires.

Manual verification queue: none. Every criterion is `[auto]`.

Deviations from SLICE.md, stated before building: line 3 adds `postgrex` as `optional: true` rather than a
default dependency, so the standalone desktop build carries no Postgres driver; line 5 writes the UUIDv7
generator in-tree rather than adding `uniq`, and proposes nothing new for VERSIONS.md.

## Line 1, 2026-09-20: plan_check rule 12, red then green

Planted the exact defect PR #7 fixed (the quotes removed from the step name at
`.github/workflows/package.yml:173`, working tree only, reverted after):

```
$ ./scripts/plan_check.sh | grep -E '== 12|FAIL .github|plan_check:'
== 12. Every workflow and Dependabot file parses as YAML ==
FAIL .github/workflows/package.yml: not parseable as YAML:   in ".github/workflows/package.yml", line 173, column 25
plan_check: FAIL
exit=1

$ git checkout -- .github/workflows/package.yml && ./scripts/plan_check.sh | grep -E '== 12|FAIL|plan_check:'
== 12. Every workflow and Dependabot file parses as YAML ==
plan_check: PASS
exit=0
```

The population is `git ls-files '.github/*.yml' '.github/*.yaml' '.github/**/*.yml' '.github/**/*.yaml'`, three
files today. The parser is Python's yaml module (6.0.1 here, present on the ubuntu runner); its absence is a
FAIL, not a skip.

## Line 2, 2026-09-20: the one-connection pool, named pragmas, the receipts slot

`config/config.exs` names every pragma (`journal_mode :wal`, `synchronous :normal`, `foreign_keys :on`,
`busy_timeout 5000`, `cache_size -64000`, `wal_auto_check_point 1000`) and sets `pool_size: 1` for SQLite in
every environment; dev and test no longer override the pool. The adapter is chosen at compile time from
`TRINITY_DB` (default sqlite), because `use Ecto.Repo` takes the adapter as a literal; the config says so.
`Trinity.Repo.Receipts` is declared with the same adapter, not started, not in `:ecto_repos`.

`test/trinity/repo_config_test.exs` reads the pragmas back from a live connection: `wal`, `1` (normal), `1`
(foreign keys), `1000` (autocheckpoint pages) all read back as configured. **One does not:** `PRAGMA
busy_timeout` reads `0`, because exqlite installs its own busy handler and applies the timeout on its side of
it (`deps/exqlite/lib/exqlite/connection.ex`, the comment above `set_busy_timeout/2`, at 0.40.0); the pragma
would destroy that handler, so the driver never sets it. The test asserts the configured value and the `0`
together, with the reason. Contention itself is the stress test's job (line 9).

A read pool is not added at this slice: WAL readers do not block the writer, but a one-connection pool
serialises reads behind writes in the same process queue. Measured need arrives with 012 and 013, and the
Repo layout admits a read-only replica repo then without moving anything. Recorded under Follow-ups.

```
$ mix test test/trinity/repo_config_test.exs        → 7 passed
$ mix compile --warnings-as-errors --force          → Generated trinity app
$ mix test                                           → 79 passed
$ mix credo --strict                                 → found no issues
```

## Follow-ups
- A read-only replica repo over the same file, when 012 or 013 measures read latency behind the single writer.

## Line 3, 2026-09-20: the Postgres branch, proven in CI on this branch

Run 35509095238 on `5a9ec9b`, job `postgres` (postgres:17 service, `TRINITY_DB=postgres`, `DATABASE_URL` from
the job env), lines from its log:

```
mix run -e 'Ecto.Adapters.Postgres = Trinity.Repo.__adapter__()'     (exit 0: the compiled adapter is Postgres)
The database for Trinity.Repo has been dropped
The database for Trinity.Repo has been created
Excluding tags: [:sqlite]
Result: 72 passed, 7 excluded
```

The seven excluded are the SQLite pragma read-backs (`@moduletag :sqlite`), excluded by tag on that job and
never skipped. Job `gate` on the same run: success. The job is not yet a required check on the ruleset; it is
added after its first green run on `main`, which this slice's merge will be.

No local Postgres was used: the machine has a server on 5432 whose password this seat does not have and did
not guess. AC1 names CI as the proof for this half.

## Line 4, 2026-09-20: the data-dir lock

`Trinity.DataDir.Lock`: `<data_dir>/LOCK` created with `:exclusive`, carrying OS pid, mode, a per-boot token and
the time; a supervised child placed before `Trinity.Repo`; refusal names the holder's pid and mode and touches
no database file. Liveness through `/proc/<pid>` on Linux; elsewhere a held file is treated as held (the safe
direction) and the message names the pid to remove by hand. A malformed file is held, never taken over.
Test env points the lock at a temporary directory keyed by `MIX_TEST_PARTITION`.

```
$ mix test test/trinity/data_dir      → 10 passed
```

One thing seen and left as it is: `mix test` halts the VM without running `terminate/2`, so the test lock
file survives a run and is taken over as stale at the next (its pid is dead). Correct behaviour, and the
reason the stale path has a test.
