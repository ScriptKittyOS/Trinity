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
