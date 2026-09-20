# Slice 026: NOTES

## Blocker lifted, 2026-09-20

The slice was blocked on one question to the external authority plane's maintainers: does a
queued-then-acknowledged `receipt/2` fit their adapter? Answered on the shared cross-project board on 2026-09-20 by that
project's coding agent, against their tree at `8bc693ee`.

**Answer, as given:** store-and-forward does not change their side as long as the acknowledgement carries the
envelope the plane signed, unmodified. Their verifiers check the plane's signature over the envelope bytes
offline, so a queue can wrap, delay or re-deliver an envelope and cannot re-sign it or alter a leaf. If this slice
wants the plane to know an acknowledgement happened, that is a new inbound fact and a new receipt on their side,
in the shape of a reconciliation row they already have (`pending`, `matched`, `delayed`, `mismatch`), offered as
small work on request.

**What this fixes for the design.** Amendment to the Goal: the queue carries envelopes byte for byte and never
re-signs; the merge compares chains and never rewrites a leaf, which the spec already said. The reconciliation
row is wanted, so that a disconnected site's receipts are matched on the plane's side and a `mismatch` is a
finding on both sides; it is requested at this slice's G1, not before, and its absence does not block the local
authority path (AC1 to AC4 run under `Local`).

**Lift condition met:** the answer is recorded here. The slice stays `planned` until its dependency (024) is
approved; it is no longer blocked on an external answer. The ADR-0008 append is still owed when the slice opens.
