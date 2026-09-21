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

## Findings, 2026-09-21

1. **The schema check refused this machine on its first run.** The test database on disk carried slice 033's
   migration from another branch, which this branch's binary does not have; the import refused
   `{:schema_newer_than_binary, [{"trinity.db", [20260921010000]}]}`, which is the criterion working before
   its test was written. A fresh test database for the branch, and the check stayed as it is.
2. **A `for` filter that binds `nil` skips the element.** `Manifest.verify/2` first checked digests with
   `bin = Map.get(entries, path)` as a comprehension filter, so a file the manifest named and the tarball
   lacked was never reported, and AC4's second half wrote the archive partially. Rewritten as a function over
   the list; the test that found it stays.
3. **A manifest path is data, and one of sobelow's fifteen findings was real.** `write_files` resolved
   `keys/<rest>` under the layout's keys directory, and `<rest>` came from the archive: `keys/../../x` would
   have landed outside. `Layout.safe_path?/1` now accepts the two databases and relative paths under `keys/`,
   `skills/` or `personas/` with no dot segments, `Manifest.verify/2` refuses anything else as `:unsafe_path`
   before the digests, and a test plants one. The other fourteen are the owner's own paths (the data
   directory, a task argument, a temporary file the export made) and carry their reasons inline.
4. **`.sobelow-skips` keys on file and line** (slice 022's lesson): adding `live_holder/1` to the lock module
   shifted two skipped findings and they came back; the function sits at the file's end.
5. **A 030 test polluted the code path.** `Application.app_dir(:trinity)` answered `/tmp/trinity-policy-N`
   during the suite because that test had prepended a directory of that name and `:code.lib_dir/1` reads any
   `<app>-<vsn>` entry as the application's; the migration listing this slice's check reads came back empty.
   Fixed as `fix(s030)` (a name without the prefix, the path removed on exit); found because AC1's schema
   assertion failed only in the full run.
6. **The persona picker test read the newest session on disk**, and a session a failed archive run had left
   outranked it; it reads the session it was redirected to now (in the same `fix(s030)`).
7. **Auto sandbox mode for the round trip, and none for the download.** `VACUUM INTO` cannot run inside the
   sandbox's transaction and the rows must be on disk, so the round-trip tests switch both repos to `:auto` and
   clean up their rows; the export itself never goes through Ecto (it opens the files), so the controller test
   needs no mode change, and switching it starved the one-connection pool until that was seen.
8. **The archive is SQLite's.** The postgres job had no file to snapshot; the archive tests carry `:sqlite`,
   and docs/backup.md says a Postgres deployment backs up with `pg_dump`.

## Follow-ups
- 040: `skills/` is archived when present; the restore reindexes skills after writing files (the design note),
  which has nothing to index until then.
- 032: measure the archive with vectors in it; the size line in docs/backup.md is today's.
- 024's boot receipt under a Mix-run script (030's finding 5) is unchanged by this slice.
- The private key's absence on a fresh install means a new key id on first boot; a later slice may offer the
  import of just the key file for someone restoring their own machine.
