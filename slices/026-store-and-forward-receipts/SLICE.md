# Slice 026: Store-and-forward receipts for disconnected operation

| Field | Value |
|---|---|
| Phase | 2 Tools |
| Milestone | none (regulated deployment, after M2) |
| Size | L |
| Depends on | 024 |
| Status | see ROADMAP.md |

Added 2026-09-20. Blocked until the external authority plane's maintainers answer whether a queued-then-acknowledged
`receipt/2` fits their adapter; that question is routed through the owner and this slice does not open before the
answer is recorded in NOTES.md. Opening it changes ADR-0008's contract and needs an appended decision there.

## Goal
`receipt/2` gains a queued-then-acknowledged mode so that the local authority and an external adapter behave
identically when the machine is offline: receipts are appended locally with a hybrid logical clock on every row,
queued for the adapter, acknowledged when it confirms, and merged on reconnect by Merkle comparison of the two
chains rather than by replay.

## Why
A field or clinical site loses its link and keeps working. Today `receipt/2` is synchronous: offline, the local
chain continues and the adapter's view stops, and nothing reconciles them. A chain that cannot survive a
partition is evidence only while the network is up.

## Scope
**In:**
- Hybrid logical clock on every receipt row; the clock's rules and its trust limits written into the security
  model (a signed receipt with an untrusted clock is weaker evidence, and the model says so).
- A durable outbound queue per chain scope; acknowledgement tracking; back-pressure when the queue is bounded.
- Merkle merge on reconnect: per-device chains, a comparison of tree heads, and a merge that never rewrites
  either side; conflicts are recorded as receipts of their own.
- The `Local` authority exercising the same path, so standalone Trinity proves the mode without an adapter.
**Out:**
- Multi-master conflict resolution beyond recording; a witness or gossip network; the external plane's side of the
  merge, which is theirs.

## Design notes
Nothing here changes what a receipt says, only when it is acknowledged and how two chains are compared. The
signer seam and chain scopes from 024 are used unchanged.

## Deliverables
- Queue and clock in `Trinity.Receipts`; the merge; the ADR-0008 appended decision; docs/07 clock section; tests
  that partition and reconnect.

## Acceptance criteria
1. [auto] With the adapter unreachable, effects proceed under the local chain, every receipt carries a clock, and
   the queue grows; with the adapter back, every queued receipt is acknowledged in order (test).
2. [auto] Two chains diverged during a partition merge on reconnect with neither rewritten and a conflict receipt
   for each divergence (test).
3. [auto] A receipt whose clock is behind the previous row's is refused and the refusal receipted (test).
4. [auto] Bounded queue: past the bound, effects are denied, not written unacknowledged (test).
5. [auto] Gate green; coverage line reported.

## Proof required
- For each criterion: the command and its output, or a test name and its result. A sentence is not proof.

## Manual verification queue
None. Every acceptance criterion in this slice is `[auto]` and is proven by a command or a test.
If that changes during the slice, the criterion is retagged and this section is filled at G1.

## Definition of Done
- [ ] `mix gate` green · [ ] AC1–5 proven · [ ] docs/ADR/VERSIONS updated if affected · [ ] ROADMAP status → done · [ ] final commit + tag

## Commit & tag
`feat(s026): complete slice 026 (store-and-forward receipts)` · tag `slice/026`

## Risks / open questions
- The external plane may answer that its adapter cannot take a queued mode; then this slice narrows to the local
  authority only and says so.
- Clock trust under disconnection has no software fix; a trusted time source is a deployment matter and is
  named in the register, not solved here.
