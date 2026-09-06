# ADR-0007 — Target MCP 2026-07-28; choose the Elixir MCP library by spike
Status: proposed → finalised by Slice 059 · Date: 2026-09-05

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
