# 09: Standards register

Opened 2026-09-20 as a stub, on the owner's decision. One row per control a regulated deployment may ask
about. The register separates two kinds of statement that are easy to blur: a **tree property**, which a test
or a command in this repository proves, and a **real-world dependency**, which is an act by a deployment, an
assessor or an authority and which no version of this tree can close.

The rule this file enforces by existing: **no README, release note or public page of this project makes a
claim about a regulation, a certification or a government or healthcare requirement unless this register
carries the row, with an evidence path, and the status column says the claim is true.** A row whose status is
`:unknown` or `not claimed` is not a claim. Marketing copy cites this file or says nothing.

Columns: the control; where Trinity satisfies it, or would; the evidence path in the tree (a test name, a
document, a PROOF.md line) or `none`; the status; who decides the status. Statuses: `tree property`,
`real-world dependency`, `not claimed`, `:unknown`.

## Cryptography

| Control | Where Trinity satisfies it | Evidence path | Status | Decider |
|---|---|---|---|---|
| FIPS 140-3 validated cryptography in FIPS mode | OTP built with `--enable-fips` against a validated provider; `crypto:info_fips()` enabled; slice 024's signer selects an approved algorithm or denies | slice 003 (FIPS build leg), slice 024 AC8 | `:unknown` until 003 and 024 land | owner, then an assessor |
| CNSA 1.0 signature suite (ECDSA P-384, SHA-384) | slice 024 amendment 2, FIPS mode selection | slice 024 AC8 | `:unknown` until 024 lands | owner |
| CNSA 2.0 readiness (ML-DSA-87) | slice 024 amendment 6, behind the same seam, compile-conditional on OpenSSL 3.5 or later; never default | none yet | `not claimed` | owner; the word validated waits on the CMVP listing of the provider that carries it |
| FIPS 140-2 certificates on the Historical list from 2026-09-22 | not applicable: Trinity cites no 140-2 module | none | `real-world dependency` (deployment's modules) | deployment |
| TLS floor 1.2 in FIPS mode | one README line and a test pinning it | slice 002 AC3 | `:unknown` until 002 lands | owner |
| Envelope MAC in FIPS mode is an approved algorithm | HMAC-SHA256 or AES-GCM in the MRTR envelope Trinity mints | slice 061 | `:unknown` until 061 lands | owner |

## Records and audit

| Control | Where Trinity satisfies it | Evidence path | Status | Decider |
|---|---|---|---|---|
| NIST SP 800-53 AU family: non-repudiation of every governed act (AU-10) | per-receipt signatures for effect, decision, boot and cap receipts; checkpointed chains for query receipts; standalone verifier | slice 024 AC3, AC7, AC9 | `:unknown` until 024 lands | owner, then an assessor |
| Audit record durability of the last committed receipt | receipts file may run `synchronous: :full` in its own file | slice 010 (file slot), slice 024 | `:unknown` | owner |
| Disconnected operation without loss of audit | store-and-forward receipts, hybrid logical clocks, Merkle merge | slice 026 | `not claimed`; 026 is blocked on an external answer | owner |
| Trusted time for receipts | none in software; a deployment supplies a trusted time source | slice 026 risk line | `real-world dependency` | deployment |

## Data at rest and keys

| Control | Where Trinity satisfies it | Evidence path | Status | Decider |
|---|---|---|---|---|
| Encryption of data at rest with deployment-controlled keys | volume or page level below SQLite (documented baseline); envelope encryption for blobs; keys through the custody seam | slice 025 | `:unknown` until 025 lands | owner, then an assessor |
| Exclusive deployment control of encryption keys | `Trinity.Keys` behaviour; local adapter first; KMS, HSM and PKCS#11 as later adapters | slice 025 AC1, AC3 | `:unknown` | deployment |

## Identity

| Control | Where Trinity satisfies it | Evidence path | Status | Decider |
|---|---|---|---|---|
| Non-person entity identity from the deployment's PKI, with an accountable sponsor | X.509 per instance; sponsor field in the boot receipt; SPIFFE as an issuance path only | slice 062 amendment note | `not claimed`; no criterion yet | owner |
| Identity is not authority | OAuth and EMA answer who; the gate and the authority adapter answer whether | slice 062, slice 024 | `:unknown` until both land | owner |

## Supply chain

| Control | Where Trinity satisfies it | Evidence path | Status | Decider |
|---|---|---|---|---|
| Software bill of materials on every release | CycloneDX from the gate, attached to releases | slice 002 AC1, AC2 | `:unknown` until 002 lands | owner |
| Build provenance on release artifacts | GitHub attestation, verified in the workflow | slice 002 AC2 | `:unknown` until 002 lands | owner |
| Signed releases, Scorecard, SLSA level | slice 121 | none yet | `not claimed` | owner |
| Cryptography bill of materials | none until the minimum elements are published | none | `not claimed` | owner |

## Architecture arguments a deployment may ask for

| Control | Where Trinity satisfies it | Evidence path | Status | Decider |
|---|---|---|---|---|
| Independence from other systems that share the Jido library | not applicable: Trinity uses no Jido package (ADR-0009, decision appended 2026-09-20) | `mix deps.tree` shows no jido package | `tree property` | owner |
| Standalone operation with no authority plane and no outbound connection | `TRINITY_AUTHORITY=local`, the standalone assertion | slice 024 AC2 | `:unknown` until 024 lands | owner |
| Nothing fails open | signing unavailable denies; unknown tool denies; unknown effect denies; adapter unresolvable refuses to start | slice 024 AC5, ADR-0010 | `:unknown` until 024 lands | owner |

## Real-world dependencies that no tree change closes

An authorization to operate, a provisional authorization, a FedRAMP package, a business associate agreement
with every downstream model provider, a CMMC level, a device submission. Each is a deployment's act with a
sponsor and a date. They are listed here so nobody mistakes a green gate for one of them.

| Item | Status | Decider |
|---|---|---|
| Any authorization to operate | `real-world dependency` | deployment and its authorizing official |
| Business associate agreements with model providers | `real-world dependency` | deployment |
| CMMC assessment | `real-world dependency` | deployment and its assessor |
| Device submission with a change-control plan | `real-world dependency` | deployment and its regulator |

## How rows change

A row's status moves only with an evidence path a stranger can follow. A row is never deleted; a control that
stops applying keeps its row with the reason. Corrections append below the table they correct, dated.
