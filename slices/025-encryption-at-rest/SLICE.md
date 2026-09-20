# Slice 025: Encryption at rest, and the key-custody seam

| Field | Value |
|---|---|
| Phase | 2 Tools |
| Milestone | none (regulated deployment, after M2) |
| Size | M |
| Depends on | 010, 024 |
| Status | see ROADMAP.md |

Added 2026-09-20 under two accepted recommendations: keys live where the deployment controls them, with a local
adapter first; and encryption at rest splits by whether SQLite indexes the data.

## Goal
A key-custody behaviour (`Trinity.Keys`) with a local adapter (passphrase-derived, TPM-sealed or
systemd-credential-supplied, whichever the machine offers, chosen at boot and named in the boot receipt) through
which the 024 signer and this slice's envelope encryption obtain keys; envelope encryption in code, AES-256-GCM
through `:crypto`, for the blobs nothing indexes: skill files, staged skill changes, exported artifacts; and the
documented, measured baseline for everything SQLite indexes, which is volume or page level encryption below the
database file and zero code in Trinity.

## Why
Field-level ciphertext in the memory store would break slice 032's full-text and vector search, which index
plaintext tokens and raw vectors. The split keeps the indexes working and still leaves no plaintext blob on disk
that Trinity could have encrypted. The custody seam is what lets a later deployment put keys in a KMS or an HSM
without touching either consumer.

## Scope
**In:**
- `Trinity.Keys` behaviour: `fetch/2`, `wrap/2`, `unwrap/2`, `rotate/1`; the `Local` adapter with its three
  sources; selection at boot; the 024 signer and the 100 keychain path retrofitted to read through it.
- Envelope encryption for the blob classes above: a data key per blob, wrapped by the custody adapter, the
  wrapped key stored beside the ciphertext; decryption on read; a receipt on every key wrap and unwrap.
- `docs/encryption-at-rest.md`: the split, the reasons, the dm-crypt baseline with the commands to set it up
  and the measured overhead on this machine from the 010 insert bench run on an encrypted and a plain volume.
**Out:**
- Encrypting the SQLite files in code (page-level libraries): only as a later option for a deployment that
  already licenses a validated one, and not in this tree.
- KMS and PKCS#11 adapters: their own slices when a deployment asks; the behaviour is shaped so they fit.
- Key escrow, recovery and multi-party custody.

## Design notes
The behaviour is shaped around a local round trip, on purpose; a network adapter later has to fit a callback
that was proven without one, rather than the other way round. Keys never appear in receipts, logs or the
database; the receipt names the key id and the operation.

## Deliverables
- `lib/trinity/keys/` with the behaviour and the `Local` adapter; envelope encryption in the skill and export
  paths; migrations for wrapped keys beside blobs; `docs/encryption-at-rest.md`; the bench results in PROOF.md.

## Acceptance criteria
1. [auto] The boot receipt names the custody adapter and source; each of the three local sources works when
   present and is refused with a named reason when absent (tests, one per source, with the absent case).
2. [auto] A skill file, a staged change and an export are ciphertext on disk, readable through the seam, and
   unreadable with the wrapped key removed (tests).
3. [auto] The 024 signer obtains its key through the seam and no other path; a census finds no key read outside
   `Trinity.Keys` (test with a planted read).
4. [auto] Rotation: after `rotate/1` new blobs use the new key, old blobs still open, and the registry records
   both (test).
5. [auto] The insert bench from slice 010 run on a dm-crypt volume and on a plain volume, same machine, same
   day, the two numbers in PROOF.md with the commands.
6. [auto] Gate green; coverage line reported.

## Proof required
- For each criterion: the command and its output, or a test name and its result. A sentence is not proof.

## Manual verification queue
None. Every acceptance criterion in this slice is `[auto]` and is proven by a command or a test.
If that changes during the slice, the criterion is retagged and this section is filled at G1.

## Definition of Done
- [ ] `mix gate` green · [ ] AC1–6 proven · [ ] docs/ADR/VERSIONS updated if affected · [ ] ROADMAP status → done · [ ] final commit + tag

## Commit & tag
`feat(s025): complete slice 025 (encryption at rest and the key-custody seam)` · tag `slice/025`

## Risks / open questions
- A TPM is absent on many developer machines; the passphrase source is the one every test can exercise, and the
  TPM and systemd-credential sources are proven where present and recorded as not measured where not.
- Retrofitting 024's signer to the seam is a change to an approved slice's code if 024 lands first; it is a
  fix commit referencing 024, never a rewrite of its record.
