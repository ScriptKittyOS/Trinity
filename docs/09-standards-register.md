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
| FIPS 140-3 validated cryptography in FIPS mode | OTP built with `--enable-fips` against a validated provider; `crypto:info_fips()` enabled; slice 024's signer selects an approved algorithm or denies | slice 003 (FIPS build leg), slice 024 AC8 | 003 landed 2026-09-20: the gate runs in the mode on every push (`fips` job, docs/fips-leg.md); the provider is the one the distribution ships and names, and the word validated is the certificate's, not this tree's; 024 AC8 still `:unknown` | owner, then an assessor |
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
| IETF RFC 9943 (SCITT) alignment of the receipt object | nothing to satisfy: Trinity issues SCITT **Signed Statements**, never SCITT **Receipts**, which MUST carry inclusion proofs from a Transparency Service Trinity does not run. The signed field set maps element by element to COSE, CWT and in-toto constructs; the three fields that do not map (`seq`, `prev_hash`, `chain_scope`) are the ones SCITT delegates to that service | docs/receipt-scheme-mapping.md; slice 124 amendment 1; `Trinity.Receipts.SchemeMappingTest` | `not claimed`: alignment is documented, conformance is not claimed and none should be inferred. Field names are deliberately **not** renamed to COSE/CWT names, because an object that reads as conformant while running no transparency service is a claim made by appearance, which is what this register exists to prevent | owner; a conformance claim would need a `COSE_Sign1` envelope and a Transparency Service, both outside slice 124 |

## Data at rest and keys

| Control | Where Trinity satisfies it | Evidence path | Status | Decider |
|---|---|---|---|---|
| Encryption of data at rest with deployment-controlled keys | volume or page level below SQLite (documented baseline); envelope encryption for blobs; keys through the custody seam | slice 025 | `:unknown` until 025 lands | owner, then an assessor |
| Exclusive deployment control of encryption keys | `Trinity.Keys` behaviour; local adapter first; KMS, HSM and PKCS#11 as later adapters | slice 025 AC1, AC3 | `:unknown` | deployment |

## Identity

| Control | Where Trinity satisfies it | Evidence path | Status | Decider |
|---|---|---|---|---|
| Non-person entity identity from the deployment's PKI, with an accountable sponsor | X.509 per instance; sponsor field in the boot receipt; SPIFFE as an issuance path only | slice 062 amendment note | `not claimed`; no criterion yet | owner |
| Identity is not authority | OAuth answers who (slice 062: the resource server hands the tool layer a principal, never the token; scope is checked before the gate and is never an allow rule); the gate and the authority adapter answer whether (slice 024) | `test/trinity/mcp/auth/resource_server_test.exs` (a scoped token still reaches the gate), `test/trinity/mcp/auth/boundary_test.exs` (the auth boundary reaches nothing of the tree) | tree property, held by tests since 2026-09-22; the deployment's adapter is the real-world half | owner |
| Trinity issues no production authority | The production profile validates the external issuer's tokens and mints none; the personal profile's issuer refuses to start under an external authority adapter and its tokens are marked and refused in production | `test/trinity/mcp/auth/embedded_test.exs` (refused at boot; no key material in production), `test/trinity/mcp/auth/token_test.exs` (the mark refused) | tree property, held by tests since 2026-09-22 | owner |
| Enterprise Managed Authorization (ID-JAG) | Not in this tree: the external authorization server redeems the assertion (owner decision 2026-09-22, slice 062 NOTES "Deferred") | docs/08 row; slice 062 NOTES | `not claimed`; deferred with a lift condition | owner |

## Open source assurance

| Control | Where Trinity satisfies it | Evidence path | Status | Decider |
|---|---|---|---|---|
| Recognised open-source security baseline | The OpenSSF Best Practices criteria at the passing level: basics, change control, reporting, quality, security and analysis | https://www.bestpractices.dev/projects/14772 | **passing, self-certified 2026-09-23.** Three suggested criteria are recorded unmet rather than stretched: `version_semver`, `dynamic_analysis`, `dynamic_analysis_enable_assertions` | maintainer |
| Recognised open-source security baseline, second tier | The same criteria at the **silver** level: documented governance and roles, continuity of access, a published roadmap, a written test policy, 80% statement coverage, and an assurance case carrying a threat model, trust boundaries, a secure-design argument and an implementation-weakness argument | https://www.bestpractices.dev/projects/14772 | **silver, self-certified 2026-09-23** (all 44 MUST criteria met or not applicable; `signed_releases` is not applicable only while no release is published, and becomes required at the first one). Recorded unmet with reasons: `bus_factor` and `accessibility_best_practices` (both SHOULD), `version_tags_signed` (SUGGESTED) | maintainer |
| Recognised open-source security baseline, third tier | The same criteria at the **gold** level | https://www.bestpractices.dev/projects/14772 | **Not held; 30% when this row was first written, before the tree work below landed.** Met in the tree: `require_2FA` (the organisation enforces two-factor authentication for write access); `copyright_per_file` and `license_per_file`, held by `test/spdx_headers_test.exs`; `code_review_standards`, the *Code review* section of docs/03-conventions.md; `small_tasks`, the *Good first tasks* section of CONTRIBUTING.md; `security_review`, docs/11-security-review.md dated 2026-09-23 with five resolved findings and four open; `build_reproducible`, **met for the release** and re-runnable with `./scripts/check_reproducible.sh` (all 243 modules this project compiles are byte-identical across two builds from a clean tree; three dependency modules and the per-release secret cookie are not, and are named). **Not applicable:** `test_branch_coverage80`, because the criterion is conditional on a FLOSS tool existing for the language and `cover:analyse/3` raises `function_clause` for `branch`, which is what every Elixir coverage tool wraps. **Outstanding, not glossed:** `bus_factor`, `contributors_unassociated` and `two_person_review` all need people other than the author in the git history and cannot be bought with code; `test_statement_coverage90` needs 90% against the current 80.31%; `dynamic_analysis` and `dynamic_analysis_enable_assertions` need a tool the project does not run; `secure_2FA` depends on which second factor the maintainers use | maintainer |
| Linux Foundation Incubation prerequisite | The same badge; LF Incubation requires it at passing, alongside documented technical governance and a README per repository | https://www.bestpractices.dev/projects/14772, `GOVERNANCE.md`, `MAINTAINERS.md` | badge held; neutral asset hosting is not yet in place and is a foundation-side step | owner |

**Time-bound answers in that self-certification.** Three of the answers were true on the date given
and are not permanent: `report_responses` and `enhancement_responses` ("no external reports received
yet"), `vulnerability_report_response` ("none in the last 6 months"), and
`vulnerabilities_fixed_60_days`, which depends on the age of the open `glib` advisory recorded as R25
in `docs/06-risk-register.md`. They are re-checked when the badge is revisited rather than assumed to
still hold.

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
