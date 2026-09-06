# Slice 010 — Core domain + persistence

| Field | Value |
|---|---|
| Phase | 1 Core loop |
| Milestone | M1 Talks |
| Size | M |
| Depends on | 000 |

## Goal
`Trinity.Repo` configured for SQLite (WAL, single writer) with Postgres as a CI-tested alternative; `sessions` and
`messages` schemas; the `Trinity.Sessions` context's persistence API (create session, append message with gapless
`seq`, list, load history); PubSub started; the concurrency stress test this design has to pass.

## Why
Data outlives processes. Everything later rehydrates from these tables.

## Scope
**In:**
- Repo config: SQLite path from `Trinity.Paths.data_dir/0`, `journal_mode: :wal`, `busy_timeout`, pool size 1 for the write pool; optional read pool.
- **Data-dir lock at boot.** The single-writer pool makes concurrent writes safe *within one BEAM node*. It does
  nothing about two OS processes on one database file, which is exactly the failure `docs/00-vision.md` claims to
  fix. Slice 061 ships a headless profile and slice 100 ships a desktop app; nothing today stops them sharing a
  data dir. Acquire an advisory lock or a lockfile carrying pid and mode at boot, and refuse to start with a named
  reason when it is held.
- `TRINITY_DB=postgres` config branch (`postgrex`); CI matrix job with a Postgres service.
- Migrations: `personas` (minimal: name, soul, model — full use in 030), `sessions`, `messages` per `docs/05-data-model.md`.
- `Trinity.Sessions` persistence functions: `create_session/1`, `get_session/1`, `list_sessions/1`, `append_message/2`
  (assigns `seq` atomically), `history/2` (ordered, with limit/offset), `archive/1`.
- `Trinity.Sessions.Store` internal module isolates queries; `boundary` `exports: [Trinity.Sessions]`.
- UUIDv7 ids (`uniq` or a tiny generator), `utc_datetime_usec`.
- Factories in `test/support/factory.ex`.
- Stress test: 20 concurrent processes each appending 200 messages to 5 sessions; assert gapless `seq`, no
  `SQLITE_BUSY` errors surfaced, DB `PRAGMA integrity_check` == ok.
**Out:**
- Session processes (012), FTS (031), memories (030), LLM.

## Design notes
- `append_message/2` must be a single transaction that reads max(seq) and inserts; on SQLite with one writer this is
  race-free; on Postgres use `SELECT … FOR UPDATE` on the session row. Test both.
- Keep `parts` as `:map` — SQLite stores JSON text; Postgres jsonb.

## Deliverables
- `config/*.exs` DB branches, `priv/repo/migrations/*`, `lib/trinity/sessions/{session,message,store}.ex`, `lib/trinity/sessions.ex`, `lib/trinity/paths.ex` (if not from 001), tests, CI matrix update, `docs/05-data-model.md` synced.

## Acceptance criteria
1. [auto] `mix ecto.reset` works on SQLite; `TRINITY_DB=postgres mix ecto.reset` works in CI (log excerpt).
2. [auto] Property/stress test passes on both adapters: gapless `seq` per session under concurrency; `integrity_check` ok.
3. [auto] `append_message/2` rejects unknown roles and empty content with `{:error, %Ecto.Changeset{}}`.
4. [auto] `history/2` returns messages in `seq` order and respects `limit`.
5. [auto] `boundary` prevents `TrinityWeb` from calling `Trinity.Sessions.Store` directly (test compiles a violating module in a tmp dir — or document the compile error).
6. [auto] A second instance started against a held data dir refuses to start, names the holder's pid and mode, and leaves the database untouched (test).
7. [auto] Gate green; coverage line reported.

## Proof required
- Test output for stress tests on both adapters, migration logs, boundary check evidence, coverage.

## Definition of Done
- [ ] gate green · [ ] AC1–7 proven · [ ] docs/05 updated · [ ] ROADMAP → done · [ ] commit + tag

## Commit & tag
`feat(s010): complete slice 010 — core domain and persistence` · tag `slice/010`

## Risks / open questions
- `ecto_sqlite3` and Oban Lite both want the same file; confirm pool settings when Oban arrives (050).
