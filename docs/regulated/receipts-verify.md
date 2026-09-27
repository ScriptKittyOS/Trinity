<!-- SPDX-FileCopyrightText: Sudo Apt Holdings LLC -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
# Verifying the record

How an assessor checks Trinity's record of what it did, **without trusting the program that wrote
it**. Everything here quotes a task or a script that exists in the tree. Nothing is invented.

## Two entry points, and why there are two

| Entry point | Needs | Path |
|---|---|---|
| `mix trinity.receipts.verify` | The application, or just the exported file | `lib/mix/tasks/trinity.receipts.verify.ex` |
| `bin/verify_receipt.exs` | Elixir only. **Not the application** | `bin/verify_receipt.exs` |

The second is the one that matters for an assessment. A verifier that has to start Trinity to check
Trinity's records is asking you to trust the thing under examination. `bin/verify_receipt.exs` reads
an exported file and needs nothing from this application.

## The task, quoted

From `lib/mix/tasks/trinity.receipts.verify.ex`:

> Runs `Trinity.Receipts.Verifier` over a scope in the database or over an exported file
> (slice 024):
>
>     mix trinity.receipts.verify --scope session:<id>
>     mix trinity.receipts.verify --file receipts.json
>
> Exit codes, the same vocabulary as `bin/verify_receipt.exs`: 0 verified, 1 invalid,
> 2 usage, 5 trust not established (a key id the registry does not know), 6 compromised key.

## Exporting a scope first

From `lib/mix/tasks/trinity.receipts.export.ex`:

> Exports a scope for the standalone verifier (slice 024, AC7):
>
>     mix trinity.receipts.export --scope session:<id> --out receipts.json
>     mix trinity.receipts.export --scope boot --out boot.json
>
> The file is `Trinity.Receipts.export/1`'s map: the rows in seq order, the checkpoints and the
> registry, so `bin/verify_receipt.exs` needs nothing else. Exit 2 on usage.

## The exit vocabulary

Both entry points use the same codes. Treat them as the finding, not the console text.

| Code | Meaning |
|---|---|
| 0 | Verified |
| 1 | Invalid |
| 2 | Usage |
| 5 | Trust not established: a key id the registry does not know |
| 6 | Compromised key |

Codes 5 and 6 are the interesting ones for an assessor. **5 is not a failure of the chain**; it says
the chain refers to a key the reader cannot place, which is a question about key distribution rather
than about the records. **6 is a refusal**: the registry marks that key compromised and the verifier
will not vouch for rows signed under it.

## What the verifier actually checks

`lib/trinity/receipts/verifier.ex`, per row, in order:

1. `seq` is the previous plus one, and `prev_hash` is the previous row's `receipt_hash`.
2. The scheme is one the caller allowed, and the key id resolves in the registry.
3. The row's algorithm is the scheme's family, taken **from the registry row and never from the
   receipt**.
4. The stored hash equals the hash of the pre-authentication encoding over the stored body.
5. The stored columns agree with the signed body, so a row edited after the fact is caught.
6. For a signed kind, the signature verifies under the registry's public key.

Checkpoints are verified as well, so query receipts that are covered rather than individually
signed are still accounted for.

## What a clean verification does and does not prove

**Does prove:** the rows are in the order they claim, nothing was altered after signing, and each
signed row was signed by the key the registry names.

**Does not prove:** that the host was honest. Standalone, the same process decided, acted and wrote
the record, so a clean chain is the host's own consistent account. `authorization-boundary.md` sets
this out, and `docs/10-assurance-case.md` C6 records that a key in a file proves nothing about
custody of that key.

**Does not prove when.** The clock is the host's reading (`lib/trinity/receipts/clock.ex`). It is
signed and monotone within a chain, so the ordering cannot be rewritten; it is not a trusted
timestamp.

## Scheme versions an assessor will meet

Rows exist under two scheme versions and both verify. `receipt_v2_*` carries ten signed fields;
`receipt_v3_*` carries eleven, the extra one being the clock. A chain that spans the change verifies
row by row under each row's own scheme. The mapping to published constructs, including the three
fields that have no equivalent, is `docs/receipt-scheme-mapping.md`.

That document also states, in terms, that Trinity issues SCITT **Signed Statements** and never SCITT
**Receipts**, because it runs no Transparency Service. No conformance to RFC 9943 is claimed.
