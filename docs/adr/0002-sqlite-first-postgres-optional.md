# ADR-0002 — SQLite primary, Postgres optional
Status: accepted · Date: 2026-09-05

## Context
Desktop distribution favours an embedded DB. SQLite corruption in agents of this shape comes from multiple OS
processes writing one file, which is not a SQLite problem per se. Oban Pro Workflows and pgvector HNSW require Postgres.

## Decision
`ecto_sqlite3` is the default (`TRINITY_DB=sqlite`): single writer via the Repo, WAL mode, FTS5, `sqlite_vec`.
Postgres (`TRINITY_DB=postgres`) is supported: migrations run on both in CI; vector search is behind
`Trinity.Memory.VectorStore`. Oban uses the Lite engine on SQLite.

## Consequences
- All migrations must be adapter-aware where SQL differs (FTS, vectors).
- Oban Pro Workflows are unavailable in the default build; durable multi-step task graphs are modelled with
  Oban chaining + `task_runs` state until/unless Postgres is chosen.
- Multi-device sync (later) will likely need the Postgres path or a sync layer.
