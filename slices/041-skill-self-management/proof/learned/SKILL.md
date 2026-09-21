---
name: trinity-backup-restore-skill
description: "This skill guides you through creating a Trinity archive backup, verifying its contents, and restoring it on a fresh or same machine, including when to include private keys and how Postgres deployments differ."
metadata:
  category: backup
  learned_from: "file:<scratch>/learn-src/backup.md (docs/backup.md, copied)"
---

# Backup and Restore Trinity Archive Skill
this skill describes how to create a Trinity archive, what it contains, and how to restore it on a fresh or same machine.
**Backup**
1. With Trinity stopped, run `mix trinity.export --out <file.tar.gz>` or use the Export button on `/settings`. This creates a gzip tarball containing: `manifest.json`, `trinity.db`, `receipts.db`, `keys/registry.json`, optional `keys/receipts-*.key`, and any `skills/` or `personas/` files present.
2. The archive always includes a manifest that records the format version, build version, timestamp, migrated schema versions, and each file's size and SHA‑256 digest.
3. If you need the private signing key included, add `--keys` (or enable `?keys=1` on the page); otherwise the archive will contain only the public key registry.
**What the archive does NOT hold**
- Model caches, desktop shell state, `LOCK` file, earlier `RESTORED` markers.
- The private key unless `--keys` was used; without it receipts verify against the embedded public keys and a fresh install will generate its own key on first boot.
- Data from other machines – this is a single data directory, not a sync.
**Restore**
1. On a fresh install with Trinity stopped, run `mix trinity.import <file.tar.gz>`. The command reads the manifest, checks schema versions (newer archives are refused, older ones are migrated on next boot), verifies every file's digest against the tarball, and then writes the files.
2. If the data directory is not empty, the import refuses and lists the paths; use `--force` to replace them (each path is printed).
3. A live Trinity process refuses the import until it stops.
4. After import, a `RESTORED` file is created in the data directory naming the archive and the restore time.
5. Start Trinity; receipt chains verify under the restored registry (`mix trinity.receipts.verify --scope <scope>` or the Verify button).
6. The search index is inside the SQLite database (generated column on Postgres).
**Postgres deployment**
- When `TRINITY_DB=postgres`, the archive contains the key registry and directories, but not the databases themselves; the manifest notes this.
- Back up the Postgres database with `pg_dump` separately.
**Size example**
- On a test machine (2026‑09‑21) with 18 sessions and 8,029 messages the archive was 713 KB (≈3.1 MB of uncompressed database).
Vectors and model caches are not included yet.

