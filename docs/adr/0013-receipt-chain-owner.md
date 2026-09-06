# ADR-0013 — One supervised writer per receipt chain scope
Status: accepted · Date: 2026-09-06

## Context
Slice 024 defines `receipts` as a hash chain: each row carries `prev_hash` and `receipt_hash`, and a row is only
meaningful if `prev_hash` is the `receipt_hash` of the row that actually preceded it in its `chain_scope`.

Nothing in the plan owned that ordering. `docs/01-architecture.md` had no process for it, and the assumption that
SQLite's single writer was sufficient is wrong in a way worth stating precisely: SQLite serialises the *insert*,
so two concurrent sessions cannot corrupt the file. It does not serialise the *read-then-append*. Two sessions can
both read row N as their predecessor and both write row N+1 with the same `prev_hash`. The database is intact and
the chain is forked, which is the failure that matters, because a forked chain verifies from either branch and
proves nothing about what happened.

This was found as finding M1: the 2026-09-05 platform pass added the receipt design to slice 024 and updated
neither `docs/01-architecture.md` nor `docs/05-data-model.md`.

## Decision
One supervised writer per chain scope. `Trinity.Receipts.ChainWriter` is a `GenServer` registered `:unique` in
`Trinity.Registry` under its `chain_scope`, started on demand under a `DynamicSupervisor`, and it is the only
module permitted to insert into `receipts`.

Read-modify-write for a scope happens inside that process, so the predecessor read and the successor append cannot
interleave. Appending is a `call`, never a `cast`: the caller must learn whether its receipt is in the chain, and a
receipt whose write silently failed is worse than no receipt.

The writer holds the last `seq` and `receipt_hash` for its scope in process state and rehydrates them from the tail
row on start, so a crash costs a query and never a fork.

A census test asserts `ChainWriter` is the only caller that inserts into `receipts`; planting a second insert path
must fail it. This is the same shape as the effect-catalog census in slice 020, and for the same reason: the
guarantee is "exactly one path", and only a test over the tree can hold that.

## Consequences
- `docs/01-architecture.md` gains the process in the supervision tree; `Trinity.Receipts` gains `Repo` in its
  permitted dependencies.
- Chain scopes are coarse enough to keep the writer count bounded and fine enough to avoid a global bottleneck;
  slice 024 fixes the scope key and states the count it expects.
- Verification is unchanged and stays offline: a verifier walks a scope by `seq` and recomputes the hashes.
- The receipt path costs one process hop per catalogued effect. That is the price of an unforked chain, and it is
  paid on effects, not on reads.
