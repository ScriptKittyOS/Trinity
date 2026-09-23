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

## Which layer carries the compliance control, and which does not

Researched rather than assumed, because the answer decides what this project should turn on by
default and what it must not let a reader mistake for a control.

**Full-disk encryption is the at-rest control.** For Controlled Unclassified Information, NIST SP
800-171 3.13.16 requires protecting the confidentiality of CUI at rest, and the ordinary
implementation on an endpoint is full-disk encryption. Data at rest needs to be encrypted **once**;
application-level encryption layered over an already-encrypted volume does not satisfy the control
a second time. It protects against a different threat, and is worth having for that reason and not
for a compliance one.

**The module must be validated, not merely approved.** 3.13.11 requires FIPS-*validated*
cryptography wherever encryption protects CUI, and 3.13.16 inherits that requirement. Validated
means a module with a current CMVP certificate, not an approved algorithm in an unvalidated
library. Trinity's `:crypto` calls run against whatever OpenSSL the host provides; they are
validated only on the FIPS build leg (`docs/fips-leg.md`), which is the leg that exists to make
statements like this one measurable. **So this project's application-level sealing is not a CUI
at-rest control and must not be presented as one.** The volume is.

**Availability under key loss is a control of its own.** NIST SP 800-53 SC-12(1) requires
maintaining the availability of information when a user loses cryptographic keys. This slice puts
key escrow and recovery explicitly out of scope, which bounds how far encryption should reach by
default: sealing data whose purpose is to leave this machine would trade a confidentiality gain
nothing asks for against an availability failure the framework names.

**Secure defaults, where they cost nothing.** CISA's secure-by-design guidance asks that the secure
configuration be the baseline and that deviating from it be deliberate. It also asks that products
be resilient out of the box *without end-users having to take additional steps*. Those two pull
against each other exactly where a key source has to be configured first, and the second one wins
on the path where it applies: a default that breaks an unconfigured install is not a secure
default.

### What that produces

| class | sealed by default | why |
|---|---|---|
| staged skill changes | **yes** | machine-local and short-lived; discarding a staged change is already supported, so a lost key costs a proposal that can be made again |
| exports | no | an export exists in order to move; its destination is where that data's at-rest control belongs |
| skill files | no | they are meant to be opened in an editor; an encrypted file a person cannot read is a broken skill, not a safer one |

And where a class is sealed but no key source exists, the blob is written in the clear and the fact
is logged once rather than hidden, because an operator who believed sealing was on should learn it
from a log and not from an incident. `Trinity.Vault.sealed?/1` reports what any given blob actually
is, so the answer never has to be inferred from configuration.

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
