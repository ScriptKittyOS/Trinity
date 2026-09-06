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
