<!-- SPDX-FileCopyrightText: Sudo Apt Holdings LLC -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
# Encryption at rest

Slice 025. What Trinity encrypts itself, what it leaves to the volume beneath it, why the line is
drawn where it is, and what the volume half costs, measured rather than estimated.

## The split, and why it is not a compromise

**Trinity encrypts, in code, the blobs nothing indexes:** skill files, staged skill changes, and
exported archives. Each gets a fresh 256-bit data key, AES-256-GCM through OTP's `:crypto`, with the
data key wrapped by the custody adapter and stored beside the ciphertext.

**Trinity does not encrypt, in code, anything SQLite indexes.** That is left to the volume.

The reason is not effort. Slice 031 builds full-text search over every past message and slice 032
builds semantic recall; both work by indexing **plaintext** — tokens in an FTS5 index, raw vectors
in an HNSW or pgvector index. Field-level ciphertext in those columns does not degrade search, it
removes it: an index over ciphertext matches nothing a person would search for. A design that
encrypted those fields and kept the feature would have to decrypt the whole corpus per query, which
is slower than the search it replaces and holds the entire plaintext in memory while it runs.

So the line is drawn where the data structure changes, not where the convenience does. Below the
database file, everything is encrypted, including every index. Above it, the blobs no index touches
are encrypted by Trinity, so there is no plaintext blob on disk that Trinity could have encrypted
and did not.

## The volume half: what it costs

Measured 2026-09-23 on the development machine, with `scripts/insert_bench.exs`, which reproduces
the two write patterns this project actually uses rather than a synthetic one:

| pattern | configuration | where it is used |
|---|---|---|
| `receipts` | `synchronous=FULL`, one row per transaction | the signed receipt chain (slice 024), where every receipt must survive a power cut |
| `main` | `synchronous=NORMAL`, batched | everything else (slice 010) |

Both volumes are on the same NVMe device on the same machine, minutes apart.

```
$ elixir scripts/insert_bench.exs /mnt/bench 2000        # LUKS2 / dm-crypt
$ elixir scripts/insert_bench.exs /tmp/plainbench 2000    # the same device, unencrypted
```

| run | encrypted | plain |
|---|---|---|
| 1 | 659.3 µs/row | 322.3 µs/row |
| 2 | 655.7 µs/row | 324.5 µs/row |
| 3 | 628.1 µs/row | 335.7 µs/row |
| **mean** | **647.7 µs/row** | **327.5 µs/row** |

Batched writes, the same three runs: **1.8 µs/row encrypted against 1.6 µs/row plain.**

### What that means

**Encryption roughly doubles the cost of a durability-critical single-row write, and costs
essentially nothing for batched writes.** The whole overhead lands on the `fsync` path, which is
exactly where the receipt chain lives: each signed receipt is one row in one transaction with
`synchronous=FULL`, on purpose, because a receipt that did not survive a power cut is not a receipt.

At 648 µs per receipt a deployment writes about 1,500 receipts a second, which is far above what an
agent doing real work generates. The number is recorded because a regulated deployment will ask what
full-disk encryption costs, and "not much" is not an answer.

### What this measurement is not

- **It is an upper bound, not the floor.** The encrypted volume is a LUKS2 container in a *loopback
  file* on the same filesystem, so every write passes through one more filesystem than a real
  dm-crypt partition would. A dedicated encrypted partition will cost less than this.
- **It is one machine.** NVMe with hardware AES-NI. A machine without AES acceleration, or with
  slower storage, will show a different ratio, and the ratio is what transfers, not the microseconds.
- **It is not a claim about the database's own safety.** It measures write cost, nothing else.

## Setting up the encrypted volume

What a deployment does once. This is the baseline Trinity assumes for everything SQLite indexes.

```sh
sudo apt-get install -y cryptsetup

# a dedicated partition is what production should use; a file-backed container is for measuring
fallocate -l 2G /tmp/luks.img
sudo cryptsetup luksFormat /tmp/luks.img
sudo cryptsetup open /tmp/luks.img trinity-data
sudo mkfs.ext4 /dev/mapper/trinity-data
sudo mkdir -p /mnt/trinity
sudo mount /dev/mapper/trinity-data /mnt/trinity
sudo chown "$USER" /mnt/trinity
```

Then point Trinity's data directory at the mount. The key for the volume is the deployment's to
hold: LUKS with a passphrase, a keyfile on removable media, or TPM-sealed through
`systemd-cryptenroll`. Trinity does not manage it and does not see it, which is the point of
leaving this half to the volume.

## Reproducing the measurement

```sh
elixir scripts/insert_bench.exs <directory> [rows]
```

It prints microseconds per row for both patterns, and names the device and mount it measured, so a
result pasted into a record says what it was taken on.
