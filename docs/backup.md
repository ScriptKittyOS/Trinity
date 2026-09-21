# Backup, restore, and moving to another machine

Slice 034. One archive holds a Trinity; a fresh install takes it back. Losing the machine is a recoverable
event, not a total one.

## What the archive holds

`mix trinity.export --out <file.tar.gz>`, or the Export button on `/settings`, writes a gzip tarball with:

| Entry | What it is | Always |
|---|---|---|
| `manifest.json` | the format (`trinity-archive/1`), this build's version, when it was made, the migrated schema versions of each database, whether private keys are inside, and one line per file with its size and SHA-256 | yes |
| `trinity.db` | the primary database: personas, sessions, messages, the search index, memories and their change log, approvals and rules | yes |
| `receipts.db` | the receipt chains and their checkpoints | yes |
| `keys/registry.json` | the key registry: public keys, algorithms, statuses (a stranger verifies receipts with this) | yes |
| `keys/receipts-<algorithm>.key` | the private signing key | only with `--keys` (or `?keys=1` on the page) |
| `skills/…`, `personas/…` | files under those directories, when present (skills arrive at slice 040) | when present |

Each database is snapshotted with `VACUUM INTO`: a consistent copy including what the write-ahead log held,
taken while Trinity runs. The manifest says `keys_included` either way, so an archive's holder knows what it
carries.

## What it does not hold

- Model caches, the desktop shell's state, the `LOCK` file, `RESTORED` markers from earlier restores.
- The private key, unless asked for. An archive without it verifies every receipt ever written (the registry
  carries the public keys) and cannot write a new one as you: a fresh install without the key generates its
  own on first boot and appends it to the registry as a new key id; the old chain stays verifiable under the
  old key's row. Hand an archive to someone else without `--keys`.
- Anything from other machines: this is one data directory, not a sync.

## Restoring

On a fresh install, with Trinity stopped:

```
mix trinity.import trinity-2026-09-21.tar.gz
```

The task reads the manifest, checks the schema versions against this binary's migrations (an archive from a
newer Trinity refuses by name; an older one migrates on the next boot), verifies every file's digest against
the tarball's bytes, and only then writes the files. A data directory that is not empty is refused with the
paths it found; `--force` replaces them and prints each one. A directory held by a live Trinity is refused
until that process stops. A `RESTORED` file in the data directory names the archive and the time.

Then start Trinity. The receipt chains verify under the restored registry (`mix trinity.receipts.verify --scope
<scope>`, or the Verify button on a session's receipts page), which is the sharpest check that the copy is
faithful. The search index is inside the database on SQLite; on Postgres it is a generated column.

`--data-dir <dir>` points either task at a directory other than the configured one.

## Size

On the machine this was written on (2026-09-21), 18 sessions and 8,029 messages made a 713 KB archive (3.1 MB
of database before compression). Vectors (slice 032) and any model cache are not measured yet; the slice that
adds them reads this line.
