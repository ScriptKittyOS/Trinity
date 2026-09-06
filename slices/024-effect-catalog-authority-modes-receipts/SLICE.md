# Slice 024 — Effect catalog, authority selection, local receipts

| Field | Value |
|---|---|
| Phase | 2 Tools |
| Milestone | M2 Acts |
| Size | L |
| Depends on | 021, 022 |

## Goal
The membrane: one side-effect boundary (`Trinity.Effects`) that every `:artifact` and `:catalog` effect crosses;
the `Trinity.Authority` behaviour with `Local` built and selection at boot; the immutable core policy hash; and
local receipts, one per decision and per effect, in a per-scope hash chain, Ed25519-signed, with a standalone
verifier and an append-only key registry in the tree.

## Why
Vision goals 1 and 5, and ADR-0008 and ADR-0010. Without this, "every action is gated" is a claim rather than a
property, and "Trinity keeps no executor for delegated effects" is unfalsifiable.

## Scope
**In:**
- `Trinity.Effects` boundary: the only module that invokes a tool's `execute/2` for `effect != :none`; revalidates
  policy decision, approval fingerprint (M2), idempotency key, scope, and authority mode before executing; denies
  and receipts on any mismatch. A census test asserts no other caller of `execute/2` exists for effectful tools
  (plant a bypass module in test; census must flag it — the F6 pattern).
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
  `key_id`, `kind ∈ {decision, effect, query, boot, cap}`, `subject` refs); canonical bytes RFC 8785; Ed25519 via
  `:crypto`; key generated on first run into the OS keychain (100) or a 0600 file until then. **State plainly what
  a file-backed key does and does not establish**: it proves the chain was not altered after the fact by anything
  lacking read access to that file, and nothing more. Slice 100 migrates it and the registry records the change; `priv/keys/registry.json`
  append-only with `key_id`, `public_key_b64`, `fingerprint`, `valid_from`, `status`; `mix trinity.receipts.verify`
  and a standalone `bin/verify_receipt.exs` with exit codes `0 verified / 1 invalid / 2 usage / 5 trust not
  established / 6 compromised key` (same vocabulary as the public verifier so operators learn one).
- Signing unavailable ⇒ the effect is **denied** and the failure alarms outside the receipt stream (the
  completion-definition C1 resolution, adopted).
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

## Manual verification queue
None. Every acceptance criterion in this slice is `[auto]` and is proven by a command or a test.
If that changes during the slice, the criterion is retagged and this section is filled at G1.

## Definition of Done
- [ ] gate green · [ ] AC1–7 proven · [ ] docs/01, docs/05, docs/07 synced · [ ] ROADMAP → done · [ ] commit + tag

## Commit & tag
`feat(s024): complete slice 024 — effect catalog, authority selection, local receipts` · tag `slice/024`

## Legal review (before G1)
The `signed_payload` field set goes to the owner for legal review before this slice starts (R21). Default design
until cleared: policy identifiers (`core_policy_hash`, any policy or canonicalization version) live in **unsigned**
receipt metadata, and the signed bytes carry `seq`, `chain_scope`, `prev_hash`, `kind`, `subject`, `decision`,
`fingerprint`, `at`. Anything added later goes in by a versioned scheme bump, never by editing v1.

## Risks / open questions
- Trinity's receipt scheme is its own. Do not adopt another system's verifier or its signed-byte layout for local
  receipts; an adapter that needs a different scheme brings its own.
