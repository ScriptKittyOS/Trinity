# ADR-0007 — Target MCP 2026-07-28; choose the Elixir MCP library by spike
Status: accepted · Date: 2026-09-05 · Decision 5 recorded 2026-09-20, superseding decision 3

## Context
The plan originally targeted anubis_mcp (spec ≤ 2025-11-25). On 2026-07-28 MCP shipped its largest revision:
stateless core, MRTR, extensions (Tasks, Apps, EMA), auth hardening (CIMD over DCR), deprecations with a
12-month window. anubis_mcp shows no 2026-07-28 support and is LGPL-3.0. fastest_mcp (Apache-2.0) claims full
2026-07-28 + 2025-11-25 client/server support but is weeks old. gen_mcp 2.0 is server-only.

## Decision
1. Trinity speaks **2026-07-28** as its preferred protocol on both sides, and serves/consumes **2025-11-25** for
   compatibility until at least 2027-07-28.
2. New code never uses deprecated features (Roots, Sampling, Logging, HTTP+SSE, DCR-first registration).
3. Library choice is made by **Slice 059 (MCP library spike)** against a fixed checklist (stateless server via
   Plug, `server/discover`, MRTR client loop, Tasks extension, OAuth RS + PRM, CIMD client, stdio + Streamable
   HTTP, both spec versions, license = Apache/MIT preferred). Candidates: fastest_mcp, gen_mcp (+ own client),
   anubis_mcp (only if license acceptable and 2026-07-28 lands), own minimal server.
4. Whatever is chosen sits behind `Trinity.MCP.Client` / `Trinity.MCP.Server` boundaries so it can be replaced.

## Consequences
- Slices 060–062 are rewritten against 2026-07-28 semantics.
- `VERSIONS.md` MCP rows are provisional until 059.
- Risk register gains R14 (library lag) and R15 (LGPL).

## Decision, appended 2026-09-20

Owner decision of 2026-09-08, recorded here on 2026-09-20. Nothing above is rewritten; decision 3 is
superseded by decision 5 and its candidate list is history, not an input.

5. **The server core is `beam_mcp`**, pinned at 0.8.0 (`v0.8.0` = `cfa706b` on its `main`, on hex.pm,
   Apache-2.0). Slice 059 no longer chooses a library; it measures beam_mcp's capability gap against the
   2026-07-28 checklist and probes one seam. Decision 4 stands unchanged: `Trinity.MCP.Client` and
   `Trinity.MCP.Server` are the only modules that import `BeamMCP.*`, enforced by `boundary`.
6. **The layering rule.** beam_mcp holds no authority: no risk tiers, approvals, receipts, masking or
   authority in the package, by its own plan and by its will-not-implement page, each entry with an
   enforcing test. An approval-shaped `input_required` is an authority act, so multi-round-trip requests
   (MRTR) live above the core, in a sibling package that wraps `BeamMCP.Server` and decodes nothing, and
   the envelope inside `requestState` is minted and validated by Trinity. The core needs one seam for that:
   a `:server` module option on `BeamMCP.Transport.HTTP`, default `BeamMCP.Server`. That option is beam_mcp's
   to add; Trinity asks for it and does not fork the transport. If the seam is refused and the refusal is
   recorded, the fallback is a fork of the dispatch function into Trinity, recorded as the worse option.
7. **The client is Trinity's own thin driver** (slice 060). beam_mcp does not build a client and its
   will-not-implement page pins that. The driver builds the outbound JSON-RPC request and nothing else of the
   protocol; decoding and validation call beam_mcp's public functions. If the driver grows a second
   protocol core, the slice stops and the question of a shared client package is raised instead of forking.
8. **OAuth in every role is Trinity's** (slice 062): the resource server and the embedded authorization
   server live above the core, and the driver consumes tokens the 062 client role obtains.

| Layer | Package | Status at this record |
|---|---|---|
| Server core | beam_mcp 0.8.0 | shipped |
| MRTR wrapper | sibling package; name and tree are the owner's call | proposed |
| Client driver | Trinity slice 060 | planned |
| Authorization, all roles | Trinity slice 062, extractable at slice 123 | planned |

Consequences: `VERSIONS.md` gains a `beam_mcp ~> 0.8` row, marked not yet a dependency until 059 adds it;
R14 in the risk register is re-scoped from library lag to the will-not-implement gap; R15 (LGPL) is closed;
slices 059 to 062 are amended in the same change as this record.
