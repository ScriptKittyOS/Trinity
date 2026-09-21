# Reference – key points from the source
**Archive entries (always present)**
- `manifest.json` – format version, build version, timestamp, schema migrations, key presence, per‑file size and SHA‑256.
- `trinity.db` – primary database (personas, sessions, messages, search index, memories, change log, approvals, rules).
- `receipts.db` – receipt chains and checkpoints.
- `keys/registry.json` – public keys, algorithms, statuses.
- `keys/receipts-<alg>.key` – private signing key *only* with `--keys`.
- `skills/…`, `personas/…` – present when those directories exist.
**What it does NOT contain**
- Model caches, desktop shell state, `LOCK` file, earlier `RESTORED` markers.
- Private key unless `--keys`; without it receipts verify under the public registry and a new key is generated on first boot.
- Data from other machines.
**Restore flow**
1. `mix trinity.import <archive.tar.gz>` (Trinity stopped).
2. Manifest checked, schema migrated if needed, digests verified.
3. Non‑empty data dir refused unless
