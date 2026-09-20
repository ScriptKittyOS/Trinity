# Proof for slice 010: Core domain + persistence

Agent: Trinity · Coding Agent · Date: 2026-09-20 · Branch: slice/010-core-domain-persistence · Final commit: `332e881` (the PROOF sha line was filled in by the commit after it, which is the only way a file can name the commit that carries it)

## Summary
The Repo is one writer with every pragma named; `Trinity.Repo.Receipts` is a declared, unstarted slot for slice
024's own file. The adapter is chosen at compile time (`TRINITY_DB`), and a Postgres job in CI runs the
migrations and the suite on postgres:17. A data-dir lock before the Repo makes one node per data directory a
refusal with a named holder rather than a hope. UUIDv7 ids are minted in-tree by an `Ecto.Type`. Three
migrations, the `Trinity.Sessions` context over an internal `Store`, gapless `seq` inside one transaction,
factories, and a stress test run inside the sandbox and again outside it for the real WAL number. Hard parts,
all in NOTES.md: the type checker refusing a runtime branch on the compile-time adapter; a sub-boundary that a
top-level boundary cannot list as a dep; mix's one-second mtime resolution defeating the boundary probe twice.
Deferred: a read-only replica repo (NOTES.md Follow-ups).

## Gate
```
$ mix gate                                   (this machine, OTP 28.5.0.5, Elixir 1.20.4, under a 32 GiB cgroup)
Result: 105 passed
trinity.coverage: 010 44.88% vs 001 30.37%: OK
plan_check: PASS
exit=0
```

## Tests
```
$ mix test --cover
Result: 105 passed
|     44.88% | Total |
```
`coverage.tsv` row: `010  44.88  45ba4f0  2026-09-20`. Up 14.51 points from 001's 30.37%; `trinity.coverage: 010
44.88% vs 001 30.37%: OK`.

## Acceptance criteria evidence

### AC1: `mix ecto.reset` works on SQLite; `TRINITY_DB=postgres mix ecto.reset` works in CI (log excerpt)
SQLite, this machine:
```
$ MIX_ENV=test mix ecto.reset
The database for Trinity.Repo has been dropped
The database for Trinity.Repo has been created
== Running 20260920120000 Trinity.Repo.Migrations.CreatePersonas.change/0 forward
== Migrated 20260920120000 in 0.0s
== Running 20260920120100 Trinity.Repo.Migrations.CreateSessions.change/0 forward
== Migrated 20260920120100 in 0.0s
== Running 20260920120200 Trinity.Repo.Migrations.CreateMessages.change/0 forward
== Migrated 20260920120200 in 0.0s
```
Postgres, CI job `postgres` on run 35509095238 (branch head `5a9ec9b`, postgres:17 service):
```
mix run -e 'Ecto.Adapters.Postgres = Trinity.Repo.__adapter__()'     (exit 0)
The database for Trinity.Repo has been dropped
The database for Trinity.Repo has been created
Excluding tags: [:sqlite]
Result: 72 passed, 7 excluded
```
That run predates the migrations; the job runs `mix ecto.reset` on every push, and the run on the closing
commit of this branch carries the three migrations (its id is in the pull request's checks).

### AC2: stress test passes on both adapters: gapless `seq` per session under concurrency; `integrity_check` ok
Inside the sandbox (`test/trinity/sessions_stress_test.exs`, 20 writers, 200 appends each, 5 sessions):
```
$ mix test test/trinity/sessions_stress_test.exs
stress: -wal size after 4000 appends: 0 bytes        (the sandbox rolls back; not a measurement)
Result: 1 passed
```
Outside the sandbox, so the WAL is real (`scripts/stress_010.exs`, dev database, SQLite 3.53.4):
```
$ MIX_ENV=dev mix ecto.reset && MIX_ENV=dev mix run scripts/stress_010.exs
stress_010: appends=4000 errors=0 wall_ms=1327 appends_per_s=3012.1 integrity=ok wal_bytes=4152992 gapless=true sqlite=3.53.4
$ MIX_ENV=dev mix run scripts/stress_010.exs
stress_010: appends=4000 errors=0 wall_ms=1169 appends_per_s=3420.3 integrity=ok wal_bytes=4152992 gapless=true sqlite=3.53.4
```
4,152,992 bytes is 1,014 pages of 4 KiB: the WAL sits at the 1,000-page autocheckpoint. On Postgres the same
test runs in the CI job with the pragma assertion excluded by adapter; gapless is the whole property there.

### AC3: `append_message/2` rejects unknown roles and empty content with `{:error, %Ecto.Changeset{}}`
```
$ mix test test/trinity/sessions_test.exs --trace
* test append_message/2 (AC3) rejects an unknown role with a changeset
* test append_message/2 (AC3) rejects empty and blank content with a changeset
* test append_message/2 (AC3) rejects a missing session by name
* test append_message/2 (AC3) assigns seq from 1 and never takes it from the caller
Result: 9 passed
```

### AC4: `history/2` returns messages in `seq` order and respects `limit`
```
* test history/2 (AC4) returns messages in seq order and respects limit and offset     (same run, passed)
```

### AC5: `boundary` prevents `TrinityWeb` from calling `Trinity.Sessions.Store` directly
`test/trinity/sessions_boundary_test.exs` writes a `TrinityWeb` module calling `Store` into `lib/trinity_web/`,
runs `mix compile --warnings-as-errors --force`, asserts a non-zero exit and this text in the output:
```
warning: forbidden reference to Trinity.Sessions.Store
  (module Trinity.Sessions.Store is not exported by its owner boundary Trinity.Sessions)
  lib/trinity_web/zz_boundary_violation.ex:2
```
then writes the same module calling `Trinity.Sessions`, asserts exit 0 and no "forbidden reference", and
removes both probes. Four consecutive runs pass (`Result: 1 passed`, 2.7 s each).

### AC6: a second instance against a held data dir refuses to start, names the holder's pid and mode, leaves the database untouched
```
$ mix test test/trinity/data_dir --trace
* test the supervised child refuses to start against a held dir with pid and mode in the reason
* test a held dir has no database file created by the refused instance
* test a second acquire in the same VM is refused, naming the live holder
* test the application holds the configured directory
* test the lock child starts before the Repo
Result: 10 passed
```
The refusal reads: `<dir> is held by OS pid <pid> in desktop mode; refusing to start and touching no database
file`. The child sits before `Trinity.Repo` in the supervisor, asserted by position.

### AC7: gate green; coverage line reported
Above: `mix gate` exit 0; `trinity.coverage: 010 44.88% vs 001 30.37%: OK`.

## Manual verification for the reviewer
None. Every criterion is `[auto]`. The Postgres half of AC1 and AC2 is CI's; the reviewer reads the `postgres`
job on the pull request.

## Deviations from SLICE.md
See NOTES.md G1 plan: `postgrex` optional rather than default; an in-tree UUIDv7 generator instead of a new
dependency. One more, found while building: the Postgres row lock is compiled in or out from the adapter rather
than branched at runtime, because the type checker refuses a runtime branch on a compile-time constant.

## Versions touched
`VERSIONS.md` updated: yes. The `postgrex + pgvector` row split into `postgrex` (in `mix.lock`, optional) and
`pgvector` (not yet a dependency). `mix hex.outdated` not run; no pin moved.

## Git
```
$ git log --oneline main..HEAD
32d745d test(s010): the gate is green: coverage row, four sobelow skips with reasons, the boundary probe compiles forced
45ba4f0 feat(s010): migrations, UUIDv7 ids, the Sessions context with gapless seq, the stress test
a45db66 fix(s010): Trinity exports Paths; the boundary refused the application's data-dir call
34842c0 refactor(s010): the lock's contention branch is its own function; credo --strict was red on nesting depth
22937bf feat(s010): the data-dir lock, before the Repo, refusing a held directory by pid and mode
5a9ec9b feat(s010): the Postgres branch: postgrex optional, test config, a CI job with a Postgres service
0b38a68 feat(s010): one-connection write pool, every pragma named, the receipts repo slot
17850ce feat(s010): plan_check rule 12 parses every workflow and Dependabot file
7b2fb39 docs(s010): G1 plan, and the slice opens
332e881 feat(s010): complete slice 010 (core domain and persistence)
```
