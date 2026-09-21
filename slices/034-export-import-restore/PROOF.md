# Proof for slice 034: Export, import, restore

Agent: Trinity · Coding Agent · Date: 2026-09-21 · Branch: slice/034-export-import-restore · Final commit: (the commit carrying this file; named in the closing correction)

## Summary
One gzip tarball with the two databases snapshotted by `VACUUM INTO`, the key registry, the private key only on
the explicit flag, and a manifest with a digest per file and the schema versions; an import that checks the
schema versions against this binary's migrations, verifies every digest and every path against the tarball's
bytes before writing anything, refuses a non-empty directory unless forced (and then says what it replaced) and
a directory a live Trinity holds; two mix tasks, the first `/settings` page with the download, `docs/backup.md`.
Eight findings in NOTES.md; the one that mattered most was a manifest path resolving outside the layout, found by
sobelow and closed before the slice closed.

## Gate
```
$ mix gate                                   (this machine, OTP 28.5.0.5, Elixir 1.20.4, under a 32 GiB cgroup, tree 3a5785f)
1650 mods/funs, found no issues.
... SCAN COMPLETE ...
No retired or security advisory packages found
No vulnerabilities found.
Result: 362 passed, 17 excluded
plan_check: PASS
exit=0
```
CI, run 35553822292 on the tree at 3a5785f: `gate` success (362 passed, 17 excluded), `postgres` success (342
passed, 37 excluded: the archive tests are `:sqlite`), `fips-tag` and `fips` success (367 passed, 12 excluded).

## Tests
```
$ mix test --cover                           (tree 3a5785f)
Result: 362 passed, 17 excluded
|     95.71% | Trinity.Archive                        |
|     85.71% | Trinity.Archive.Layout                 |
|     85.71% | Trinity.Archive.Manifest               |
|     91.67% | TrinityWeb.ExportController            |
|     92.00% | TrinityWeb.SettingsLive                |
|     78.83% | Total                                  |
```
`coverage.tsv` row: `034  78.83  3a5785f  2026-09-21` (from 78.40 at 030 on this branch's base).

The slice's 20 tests (`--trace`):
```
* test a pin absent from the lock is NOT reported [L#19]
  * test a pin absent from the lock is NOT reported (4.0ms) [L#19]
  * test a pin the lock disagrees with is reported, naming the package (0.02ms) [L#7]
  * test the real pin list is satisfied by the real lock (7.2ms) [L#28]
  * test a pin that is not a version requirement is documentation, not an assertion (0.00ms) [L#23]
  * test satisfies?/2 is false for a nil lock and for a non-version string (0.00ms) [L#40]
  * test GREEN: a git dependency with no lock key still counts as documented, by name (0.02ms) [L#60]
  * test RED: a direct dependency with no row is reported (0.01ms) [L#56]
  * test the real project has no undocumented direct dependency (0.03ms) [L#64]
  * test the download is a gzip tarball with a manifest; keys only on request (59.5ms) [L#29]
  * test the page shows the data directory and links to both exports and the boot receipt (56.5ms) [L#17]
  * test an empty directory is restored and the task says what it wrote; a second run is refused, --force replaces (11.7ms) [L#40]
  * test a directory held by a live process is refused before anything else (5.9ms) [L#24]
  * test usage without an archive is exit 2 (5.9ms) [L#59]
  * test a manifest path outside the layout is refused before anything is written (7.1ms) [L#306]
  * test AC5: private keys are absent from a default export and present with keys: true; the manifest records which (11.6ms) [L#189]
  * test AC1 and AC2: export, import into an empty directory, the rows and the chain come back, the tree's digests match the manifest (28.2ms) [L#129]
  * test AC4: a tampered archive fails digest verification before anything is written (9.4ms) [L#235]
  * test a manifest round-trips through JSON; another format is refused (0.07ms) [L#345]
  * test AC3: a non-empty target refuses with what it found; forced, the result states what it replaced (6.8ms) [L#217]
  * test AC6: an archive from a newer schema refuses to import with the versions named (7.3ms) [L#275]
Result: 20 passed
```

## Acceptance criteria evidence

### AC1 [auto]: export then import into an empty data dir reproduces sessions, messages, memories, skills and personas; a content digest over the restored tree matches the manifest
`AC1 and AC2: export, import into an empty directory, the rows and the chain come back, the tree's digests match
the manifest` (test/trinity/archive/round_trip_test.exs, on real files with the sandbox in `:auto`): a persona, a
session with five messages, a memory entry and a six-receipt chain are written through the contexts; the export's
manifest lists `trinity.db`, `receipts.db` and `keys/registry.json` with `keys_included: false` and the schema
versions equal to this binary's migration files; the import into an empty directory writes three files, replaces
nothing and leaves `RESTORED` naming the archive; `Archive.digest_tree/2` over the restored files equals the
manifest's digests path for path; through dynamic repos on the restored databases the persona's soul, the
session's title, the five messages and the memory entry read back. Skills: none exist at this slice (deviation a).

### AC2 [auto]: the receipt chain verifies end to end after the round trip
The same test: the six receipts read from the restored `receipts.db` and the registry read from the restored
`keys/registry.json` verify with `Trinity.Receipts.Verifier.verify/1` (`{:ok, %{receipts: 6}`).

### AC3 [auto]: import into a non-empty data dir refuses with a named reason; forced, it states what it replaced
`AC3: a non-empty target refuses with what it found; forced, the result states what it replaced`:
`{:error, {:not_empty, [db, keys_dir]}` with the stand-in file untouched; `force: true` returns
`replaced: [db, keys_dir]` and the database is the archive's. The task prints each replaced path
(test/mix/trinity_import_task_test.exs, "a second run is refused, --force replaces").

### AC4 [auto]: a tampered archive fails digest verification before anything is written
`AC4: a tampered archive fails digest verification before anything is written`: a byte flipped inside
`receipts.db` in the tarball gives `{:verification_failed, [{"receipts.db", :digest_mismatch}]}` and the target
directory is still empty; a tarball lacking a file the manifest names gives `:missing`, target still empty. `a
manifest path outside the layout is refused before anything is written` adds the third refusal, `:unsafe_path`
for `keys/../../escaped`, with nothing written and nothing escaped.

### AC5 [auto]: signing keys are absent from a default export and present only with the explicit flag; the manifest records which
`AC5: private keys are absent from a default export and present with keys: true; the manifest records which`: the
default manifest has `keys_included: false` and no `keys/receipts-*.key` entry (the tarball's entries agree, the
registry is there); with `keys: true` the manifest says so and the key file is inside; restored, the key file is
mode 0600. The download does the same with `?keys=1` (test/trinity_web/settings_export_test.exs).

### AC6 [auto]: an archive from a newer schema refuses to import into an older binary with a named reason
`AC6: an archive from a newer schema refuses to import with the versions named`: a manifest whose `trinity.db`
versions carry `20991231000000` gives `{:schema_newer_than_binary, [{"trinity.db", [20991231000000]}]}`, target
untouched. NOTES finding 1: the check refused this machine's own test database on the first run, for a real
newer version from another branch.

## Manual verification for the reviewer
None; SLICE.md tags every criterion `[auto]`. The settings page's Export button and `mix trinity.import` are the
same code paths the tests run.

## Deviations from SLICE.md
(a) `skills/` and `personas/` are archived as directories when present and are empty at this slice (skills at
040; personas are rows, restored with the database); the reindex-after-restore of the design note waits for 040.
(b) The "Settings action" is the first `/settings` page. Both stated at G1. Found during the build: the archive
is the SQLite data directory's; a Postgres deployment backs up with `pg_dump` (docs/backup.md).

## Versions touched
`VERSIONS.md` updated: no; no dependency changed (`:erl_tar` and `:crypto` are OTP's, `VACUUM INTO` is SQLite's).

## Git
```
$ git log --oneline main..HEAD
3a5785f test(s034): the archive tests are SQLite's, as the archive is; docs/backup.md says what Postgres does
27d0305 fix(s034): a manifest path outside the layout is refused before any write; sobelow reasons
c370669 refactor(s034): credo's two findings
59839e9 feat(s034): the export and import tasks, the settings page with the download, docs/backup.md
e7a8e38 fix(s030): the planted-policy test no longer puts a trinity-* directory on the code path
874ea1f feat(s034): Trinity.Archive: export by VACUUM INTO, import verified before any write, the manifest
fd546f2 docs(s034): G1 plan with the snapshot statement and the archive size measured, and the slice opens
```
