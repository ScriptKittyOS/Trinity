# Slice 024: Effect catalog, authority selection, local receipts

| Field | Value |
|---|---|
| Phase | 2 Tools |
| Milestone | M2 Acts |
| Size | L |
| Depends on | 021, 022 |

**Amended 2026-09-20: the signer seam, algorithm agility and chain scopes by kind.** The design below still
holds; six amendments sit on top of it and two acceptance criteria are added. The reason, stated as the red it
answers: on an OTP built with FIPS mode enabled, `crypto:sign(eddsa, ...)` returns `notsup` (OTP's own `pkey.c`
refuses EdDSA in FIPS mode, whatever OpenSSL provider sits beneath it), and the validated OpenSSL FIPS provider
lists Ed25519 as not approved. This slice as first written pins Ed25519 and says signing unavailable means the
effect is denied. Both are right. Together they mean that on a FIPS build Trinity denies every effect. That is
fail-closed, which is the rule, and it is also useless, which is the amendment.

1. **A signer behaviour.** `Trinity.Receipts.Signer` with `algorithm/0`, `sign/2` and `verify/3`. One key-custody
   module implements it and also the `sign/2` callback the MCP core's signer seam expects, so a deployment
   configures its algorithm once and cannot end up with one family on receipts and another on exported bytes.
2. **Selection once, at boot.** ECDSA P-384 with SHA-384 when `crypto:info_fips()` returns `enabled`; Ed25519
   otherwise. The choice lands in the boot receipt (ADR-0010). Denial happens only when no approved algorithm is
   available, never because the default is unavailable.
3. **`key_id` inside the signed bytes; the registry binds the algorithm.** The registry row for a `key_id` names
   the algorithm. The verifier resolves the algorithm from the registry and never from the receipt body, the
   signature, or the signer's input. There is no `alg` field in the envelope, on purpose.
4. **The scheme string carries the family.** `receipt_v2_ed25519`, `receipt_v2_p384`, `receipt_v2_mldsa87`. A
   chain never mixes families without a visible break; a receipt of another family is refused at the scheme
   string before any signature is checked.
5. **Chain scopes by kind.** Effect, decision, boot and cap receipts are signed one by one: AC5 stays exactly as
   written. Query receipts, which are high in volume and low in stakes, are hash-chained and checkpointed: every
   N rows, or T seconds, or on shutdown, `ChainWriter` signs the tail; on rehydrate it re-signs the current tail
   before accepting a new row. N and T come from the signing measurement in NOTES.md at G1, not from this file.
   Signing the tree head for every kind was considered and rejected because it deletes AC5 for effects.
6. **ML-DSA-87 behind the same seam, compile-conditional.** Enabled only when the linked OpenSSL is 3.5 or later
   (OTP 28.1 and later expose it through `crypto:sign/4`; the pinned 28.5.0.5 does; this machine's OpenSSL 3.0.13
   does not). Never the default. Its signature is 4,627 bytes against 96 for P-384 and 64 for Ed25519, and the
   size goes in the standards register. The word validated is written for it only when the CMVP lists the
   provider that carries it.

| Mode | Algorithm | Hash | Signature bytes | Status |
|---|---|---|---|---|
| Default, not FIPS | Ed25519 | built in | 64 | ships with this slice |
| FIPS mode enabled | ECDSA P-384 | SHA-384 | 96 | amendment 2, proven on the FIPS build leg (slice 003) |
| Post-quantum, opt-in | ML-DSA-87 | built in | 4,627 | amendment 6, compile-conditional |

Store-and-forward for `receipt/2` (a queued-then-acknowledged mode) is slice 026 and changes ADR-0008's
contract; it is not part of this slice.

## Goal
The membrane: one side-effect boundary (`Trinity.Effects`) that every `:artifact` and `:catalog` effect crosses;
the `Trinity.Authority` behaviour with `Local` built and selection at boot; the immutable core policy hash; and
local receipts, one per decision and per effect, in a per-scope hash chain, signed through the signer seam
(Ed25519 by default, P-384 in FIPS mode, per the amendment above), with a standalone verifier and an append-only
key registry in the tree.

## Why
Vision goals 1 and 5, and ADR-0008 and ADR-0010. Without this, "every action is gated" is a claim rather than a
property, and "Trinity keeps no executor for delegated effects" is unfalsifiable.

## Scope
**In:**
- `Trinity.Effects` boundary: the only module that invokes a tool's `execute/2` for `effect != :none`; revalidates
  policy decision, approval fingerprint (M2), idempotency key, scope, and authority mode before executing; denies
  and receipts on any mismatch. A census test asserts no other caller of `execute/2` exists for effectful tools
  (plant a bypass module in test; census must flag it: the F6 pattern).
- `Trinity.Effects.Catalog` compile-time module attribute; `Trinity.CorePolicy.hash/0` = digest over the policy,
  catalog and gate modules' object code, recorded in the boot receipt.
- `Trinity.Authority` behaviour: `stage/2`, `decide/3`, `execute/3`, `receipt/2`; the `Local` implementation;
  selection at boot from `TRINITY_AUTHORITY` (ADR-0010). `local` is the default. Any other value is a module name,
  and Trinity refuses to start unless that module is loaded and implements every callback, naming which condition
  failed. Standalone test: under `local`, no adapter module is loaded and no outbound connection is attempted.
- **Refactor `Trinity.Sessions.ToolRunner` (from slice 020) to route effectful calls through `Trinity.Effects`.**
  ToolRunner keeps calling `execute/2` directly for `effect: :none` tools; everything else goes through the
  membrane. This work belongs to no other slice and is named here so it is not discovered mid-slice.
- **This slice owns receipts outright**: the table, the schema, the chain, the signer. Slice 021 owns the
  `approvals` audit table and writes no receipts; this slice reads that audit when building decision receipts.
- Receipts: `receipts` table (`seq`, `chain_scope`, `prev_hash`, `receipt_hash`, `signed_payload`, `signature`,
  `key_id`, `kind ∈ {decision, effect, query, boot, cap}`, `subject` refs); canonical bytes RFC 8785; the
  signature through `Trinity.Receipts.Signer` (Ed25519 by default, P-384 under FIPS, amendments 1 and 2), with
  `key_id` inside the signed bytes and the registry row naming the algorithm (amendment 3); the scheme string
  carrying the family (amendment 4); key generated on first run into the OS keychain (100) or a 0600 file until then. **State plainly what
  a file-backed key does and does not establish**: it proves the chain was not altered after the fact by anything
  lacking read access to that file, and nothing more. Slice 100 migrates it and the registry records the change; `priv/keys/registry.json`
  append-only with `key_id`, `algorithm`, `public_key_b64`, `fingerprint`, `valid_from`, `status`; `mix trinity.receipts.verify`
  and a standalone `bin/verify_receipt.exs` with exit codes `0 verified / 1 invalid / 2 usage / 5 trust not
  established / 6 compromised key` (same vocabulary as the public verifier so operators learn one).
- Signing unavailable ⇒ the effect is **denied** and the failure alarms outside the receipt stream (the
  completion-definition C1 resolution, adopted). Unavailable means no approved algorithm can sign, after the
  boot-time selection of amendment 2; the default being refused in FIPS mode is not unavailability.
- Query receipts are checkpointed rather than signed one by one (amendment 5); every other kind is signed per
  receipt.
- UI: receipts view per session; boot receipt in Settings.
**Out:** receipts, proposals or sockets belonging to an external authority plane. This slice builds Trinity's own
local chain and nothing else.

## Deliverables
- `Trinity.Effects` (the membrane) and `Trinity.Effects.Catalog`; `Trinity.Authority` behaviour with the `Local`
  implementation and boot-time selection; `Trinity.Receipts` with `ChainWriter` (ADR-0013) and the signer.
- **The `Trinity.Sessions.ToolRunner` refactor from slice 020**, routing effectful calls through the membrane and
  leaving `effect: :none` calls direct. It belongs to no other slice and is a deliverable of this one.
- Migration for `receipts`; the census test for the single insert path; the boot receipt.

## Acceptance criteria
1. [auto] Census test: exactly one caller of `execute/2` for effectful tools; a planted bypass is flagged (both outputs).
2. [auto] `TRINITY_AUTHORITY` set to a module that is absent, or present but not implementing the behaviour, refuses to start and names which condition failed; `local` starts; the standalone assertion passes.
3. [auto] Every gate decision and every effect yields a receipt; chain verifies across 1,000 mixed receipts; tampering one
   byte in any `signed_payload` → verifier exit 1; unknown key id → 5; registry status `compromised` → 6.
4. [auto] Fingerprint mismatch at execution (args mutated after approval) → denied + receipt (M2 re-verify).
5. [auto] Signing key removed mid-run → next effect denied, alarm event emitted, no unsigned receipt row exists.
6. [auto] Boot receipt carries `core_policy_hash`; changing a policy module changes the hash (test).
7. [auto] `bin/verify_receipt.exs` runs from an empty directory against an exported receipt file + registry (stranger test).
8. [auto] Algorithm agility: with FIPS mode enabled and P-384 available, no effect is denied for want of a signer
   and the boot receipt names P-384 (runs on the FIPS build leg, slice 003); the verifier ignores any algorithm
   hint outside the registry (a receipt whose body claims a different algorithm verifies against the registry's,
   not the body's); a P-384 receipt presented to an Ed25519 chain is refused at the scheme string before any
   signature check (tests, one mutant each: drop the registry lookup, drop the scheme check).
9. [auto] Query-receipt checkpoints: after N query receipts the tail carries a signature; on rehydrate the tail is
   re-signed before a new row is accepted; a query receipt inserted after the last checkpoint and before
   shutdown is covered by the shutdown checkpoint (tests); the AC5 mutant (remove the denial on signer error)
   goes red.

## Manual verification queue
None. Every acceptance criterion in this slice is `[auto]` and is proven by a command or a test.
If that changes during the slice, the criterion is retagged and this section is filled at G1.

## Definition of Done
- [ ] gate green · [ ] AC1–9 proven · [ ] docs/01, docs/05, docs/07 synced · [ ] ROADMAP → done · [ ] commit + tag

## Commit & tag
`feat(s024): complete slice 024 (effect catalog, authority selection, local receipts)` · tag `slice/024`

## Legal review (before G1)
The `signed_payload` field set goes to the owner for legal review before this slice starts (R21). Default design
until cleared: policy identifiers (`core_policy_hash`, any policy or canonicalization version) live in **unsigned**
receipt metadata, and the signed bytes carry `seq`, `chain_scope`, `prev_hash`, `kind`, `subject`, `decision`,
`fingerprint`, `at`. Anything added later goes in by a versioned scheme bump, never by editing v1.

## Risks / open questions
- Trinity's receipt scheme is its own. Do not adopt another system's verifier or its signed-byte layout for local
  receipts; an adapter that needs a different scheme brings its own.
- AC8's FIPS half cannot run on the developer machine (`crypto:info_fips()` returns `not_supported` there); it
  runs on slice 003's leg. If 003 has not landed when this slice reaches G3, the FIPS half is recorded as not
  measured, by name, and the slice does not close.
- P-384 signs slower than Ed25519 through OpenSSL and has no dedicated assembly path; the checkpoint window
  (amendment 5) absorbs it for query receipts, and the per-receipt cost for the other kinds is measured at G1.
