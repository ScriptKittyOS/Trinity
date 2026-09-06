# Slice 059 — MCP library spike (finalises ADR-0007)

| Field | Value |
|---|---|
| Phase | 6 MCP |
| Milestone | M5 Always-on |
| Size | M |
| Depends on | 020 |

## Goal
Choose the Elixir MCP implementation for client and server against a fixed checklist, by running each candidate,
not by reading READMEs. Output: ADR-0007 finalised with measurements; `VERSIONS.md` MCP rows flipped to ✅.

## Candidates
`fastest_mcp` (Apache-2.0, claims 2026-07-28 + 2025-11-25 client+server), `gen_mcp` 2.x (server only, 2026-07-28 +
compat plug), `anubis_mcp` 2.x (LGPL-3.0, ≤ 2025-11-25), own minimal stateless server + a candidate client.

## Checklist (each item is a runnable probe with pasted output)
1. Server: stateless 2026-07-28 over Streamable HTTP as a Plug in Phoenix; `server/discover`; `Mcp-Method`/`Mcp-Name`
   headers; `ttlMs`/`cacheScope` on lists; deterministic tool order; MRTR `input_required` round trip.
2. Server: 2025-11-25 client served from the same endpoint (compat).
3. Client: connect to a 2026-07-28 server and a 2025-11-25 server; MRTR retry loop; Tasks extension poll; stdio + HTTP.
4. Client: behaviour against a server advertising a revision the candidate does not speak. The failure must be
   legible and recoverable, not a hang or a silent downgrade. Record the exact failure.
5. OAuth RS hooks (PRM endpoint, bearer validation hook) present or feasible.
6. License, maintainer count, release cadence, download counts (from hex.pm, dated).
7. Binary size delta in a Burrito build.

## Acceptance criteria
1. [auto] A table with every checklist item per candidate, each cell a measurement with the command.
2. [auto] ADR-0007 status → accepted, naming the choice and the fallback.
3. [auto] `VERSIONS.md` updated with exact versions and dates.

## Scope
**In:**
- Run each candidate against the checklist below. Probes, not README reading.
- A comparison table where every cell is a measurement with the command that produced it.
- ADR-0007 finalised, naming the choice and the fallback.
**Out:**
- Building anything on the winner; that is 060 and 061.

## Deliverables
- `docs/adr/0007-*.md` finalised, the comparison table in PROOF.md, throwaway probe code under a scratch dir (not merged), `VERSIONS.md` MCP rows resolved.

## Proof required
- For each acceptance criterion: the command and its output, or a test name and its result, or a screenshot under `proof/`. A sentence is not proof.

## Manual verification queue
None. Every acceptance criterion in this slice is `[auto]` and is proven by a command or a test.
If that changes during the slice, the criterion is retagged and this section is filled at G1.

## Definition of Done
- [ ] `mix gate` green · [ ] AC1–3 proven · [ ] docs/ADR/VERSIONS updated if affected · [ ] ROADMAP status → done · [ ] final commit + tag

## Commit & tag
`feat(s059): complete slice 059 — MCP library spike` · tag `slice/059`
