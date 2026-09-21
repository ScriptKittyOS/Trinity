# Slice 034: NOTES

## Measured 2026-09-21 before any code

**A consistent copy of a live SQLite file is one statement.** `VACUUM INTO '<path>'` writes a compacted copy that
includes everything the WAL holds, without a checkpoint and without stopping writers; on this machine's dev
database (18 sessions, 8,029 messages, 3,096,576 bytes after the copy) it took 9 ms. The export uses it for both
databases, so the archive is a snapshot at one instant per file rather than a copy racing the writer.

**Size today.** The two databases above plus the receipts file (5 receipts, 53,248 bytes) make a 713,024-byte
gzip tarball (`:erl_tar` with `:compressed`): a 4.4 to 1 ratio on message text. SLICE.md's risk line (embeddings
and model caches) has nothing to measure yet; 032 adds the first vectors and reads this number.

## G1 plan, 2026-09-21

Tree at `294eecb` on `main` (030 and 031 approved; 033 on its own branch, not a dependency);
branch `slice/034-export-import-restore`; ROADMAP row 034 to `in_progress` in this commit. Each line names its test.

1. `Trinity.Archive.Layout`: the files of a data directory by role (`trinity.db`, `receipts.db`, `keys/registry.json`,
   `keys/receipts-*.key`, `skills/`, `personas/`), derived from a directory or given explicitly (the tests give the
   suite's own paths); `Trinity.Archive.Manifest`: `format`, `app_version`, `created_at`, `schema_versions` (the
   migrated versions of each repo), `keys_included`, and one `{path, sha256, bytes}` per file. Test: a manifest
   round-trips through JSON and its digests are the files'.
2. `Trinity.Archive.export(layout, out, opts)`: `VACUUM INTO` for each database into a temporary directory, the
   registry and (only with `keys: true`) the private key files copied, the manifest written, one gzip tarball.
   Tests: AC5 (keys absent by default, present with the flag, the manifest saying which).
3. `Trinity.Archive.import(archive, layout, opts)`: reads the manifest, refuses a non-empty target with the files
   it found unless `force: true`, in which case it states what it replaced; refuses `schema_versions` newer than
   the binary's migrations by name; verifies every digest against the tarball's bytes **before** writing anything;
   then writes the files and a `RESTORED` marker naming the archive. Tests: AC3 (both halves), AC4 (a byte flipped
   inside the tarball: refused, the target still empty), AC6 (a manifest version bumped past the binary's).
4. AC1 and AC2 end to end, outside the sandbox (`Ecto.Adapters.SQL.Sandbox.unboxed_run/2`, because `VACUUM`
   cannot run inside the sandbox's transaction and the test's rows must be on disk): a persona, a session with
   messages, memories and a receipt chain written through the contexts; export; import into an empty directory;
   the restored files opened through dynamic repos; the same rows; the digest over the restored tree equal to the
   manifest's; the restored receipt chain verified with the restored registry.
5. `mix trinity.export --out <file> [--keys]` and `mix trinity.import <file> [--force] [--data-dir <dir>]`; the import
   refuses while another Trinity holds the data directory's lock. A `/settings` page (the first; 024's boot
   receipt link moves there too) with the export as a download (`GET /settings/export.tar.gz`). Tests: the
   controller streams a tarball whose manifest parses; the page links to it.
6. `docs/backup.md`: what is in the archive, what is not, the restore procedure, and what the private key's
   absence or presence means; docs/05 unchanged (no table).

Manual verification queue: none; every criterion is `[auto]`.

Deviations stated before any code: (a) `skills/` and `personas/` are archived as directories when present and are
empty at this slice (skills arrive at 040; personas are rows in the database, restored with it); the "reindex
after restore" of the design note has nothing to reindex yet and is a follow-up for 040; (b) the "Settings
action" is the first `/settings` page, small, since none existed.
