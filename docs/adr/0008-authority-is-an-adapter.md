# ADR-0008 — Authority is an adapter behind a behaviour; identity is a separate concern
Status: accepted · Date: 2026-09-05

## Context
For every effect, something decides whether it may happen. Trinity can make that decision itself, through its own
permission gate, or delegate it to an external authority layer it does not contain and should not try to emulate.
Both need to be expressible without the second becoming a hard dependency of this tree.

Separately, Trinity's MCP server needs to know who is calling. That is a different question, and answering it well
does not answer the first one. Conflating the two is the common mistake: an access token says who you are, not
whether the thing you asked for is allowed to happen.

## Decision
1. `Trinity.Authority` is a behaviour: `stage/2`, `decide/3`, `execute/3`, `receipt/2`.
2. One implementation ships here: `Trinity.Authority.Local`. Permission gate, local signed receipts, effects
   executed locally under approval. The tree is complete and useful with this alone.
3. An external authority layer is an adapter living **outside this repository**, supplied as a module. Trinity
   holds no client for any particular one and codes to no particular envelope or schema.
4. **Identity is not authority.** Trinity's MCP server authenticates callers as an OAuth 2.1 resource server
   behind `Trinity.MCP.Auth`. That answers who is calling and with what scopes. Whether an effect happens is
   answered by the gate, or by whichever `Trinity.Authority` implementation is in force. The auth layer is never
   described as an authority layer.
5. When an external adapter is in force, Trinity keeps **no executor** for the effects that adapter governs. The
   absence is asserted by a census over the tree, not by intent.

## Consequences
- Adapters can be written against a published behaviour by anyone, including for authority layers this project
  has never seen.
- Slice 024 builds the behaviour, `Local`, the effect catalog and local receipts. No slice in this tree builds an
  adapter; that is downstream work in a downstream repository.
- Slice 062 builds the MCP resource-server profile. It is scoped as identity and never as authority.

## Amendment, 2026-09-26 (slice 026): a fifth callback, optional, for store-and-forward

The Decision above names four callbacks. Store-and-forward adds a fifth, `forward_receipt/2`, and it is
**optional**, which is the part that matters for this ADR's posture: an adapter written against the four
published callbacks stays valid and unchanged, and an adapter that does not export the fifth is simply one this
machine never forwards to.

The question this slice was blocked on was put to the external authority plane's maintainers on 2026-09-20 and
answered the same day, against their tree at `8bc693ee`. Their answer, and it shapes the contract:

> store-and-forward does not change their side as long as the acknowledgement carries the envelope the plane
> signed, unmodified. Their verifiers check the plane's signature over the envelope bytes offline, so a queue can
> wrap, delay or re-deliver an envelope and cannot re-sign it or alter a leaf.

So `forward_receipt/2` receives the exported receipt **byte for byte**. An implementation may not re-sign it,
rebuild it or alter a leaf. This tree holds up its end by storing the envelope at queue time rather than
reconstructing it at send time, and a test asserts the stored bytes equal the export; a queue that rebuilt the
envelope would break offline verification with nothing here failing.

Two further consequences for the posture in point 5 above, that Trinity keeps no executor for effects an adapter
governs:

- **The queue is bounded and the bound is a refusal.** Past it, effects are denied rather than performed and left
  unacknowledged. A machine acting unboundedly while unable to confirm anything is exactly the state this ADR's
  separation exists to avoid, and an unbounded queue would create it quietly.
- **A reconciliation row on the plane's side is wanted and was offered as small work on request.** It is not a
  dependency: `AC1` to `AC4` run under `Local`, which acknowledges immediately, so the mode is proven in this
  tree without any adapter. The request is made at this slice's G1, and its absence blocks nothing here.

The merge this slice adds never rewrites either chain. It records where two chains disagree and signs that
record. That is deliberate and belongs in this ADR because it is a statement about what an authority boundary
can and cannot deliver: after a partition, two devices hold two true accounts of what each did, and nothing
available afterwards turns them into one account of what happened. A system that claimed otherwise would be
inventing the part it could not know.
