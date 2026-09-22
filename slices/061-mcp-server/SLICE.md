# Slice 061: MCP server (stateless 2026-07-28, compat for 2025-11-25)

| Field | Value |
|---|---|
| Phase | 6 MCP |
| Milestone | M5a Automates |
| Size | M |
| Depends on | 060, 024 |

Supersedes the 2026-09-05 first draft (bearer token from settings, anubis server).

**Dependencies and blockers, added 2026-09-20 under ADR-0007 decision 6.** The design below is unchanged.
- Blocked, for AC4 and AC7, on the MRTR wrapper (a sibling package wrapping `BeamMCP.Server` through the
  `:server` option on `BeamMCP.Transport.HTTP`) or on the recorded refusal of that seam and the fallback it names.
  beam_mcp's will-not-implement entry 12 keeps MRTR out of the core; the wrapper carries `requestState` verbatim
  and decodes nothing; Trinity mints and validates the envelope.
- Depends on `resultType` being stamped on `server/discover` by the core; at 0.8.0 only `tools/call` results
  carry it. Recorded as a gap on the beam_mcp board; 059's FINDINGS names its status at the time.
- `ttlMs` and `cacheScope` on every cacheable result shipped in beam_mcp 0.5.0 and are not a dependency.
- Replay defence is Trinity's: a partition-local nonce cache keyed by expiry window, in the wrapper's host
  callback, and the 024 membrane's idempotency key as the cross-partition backstop. The property is at-most-once
  per partition plus idempotent effects, stated as such, with reds for replay inside the window, replay across
  partitions, an expired envelope and one tampered byte.
- `connectome://` resources and the `:observe` tool are shipped by the core. Whether Trinity exports them is a
  G1 decision here, default off.

## Goal
Trinity as an MCP server: a stateless Plug mounted at `/mcp` serving 2026-07-28 (`server/discover`, `_meta`
protocol version per request, `Mcp-Method`/`Mcp-Name`, `ttlMs`/`cacheScope`, deterministic tool order, MRTR for
approvals, Tasks for long tools) and 2025-11-25 clients from the same route; exporting a read-only default set
(`recall`, `session_search`, `skills_list`, `skill_view`, memory read) plus opt-in `:artifact` tools; every call
attributed to a system persona with `origin: "mcp"` and crossing `Trinity.Effects` like any other call; a
`headless` release profile so the same tree can run as a server without the desktop shell.

## Scope
**In:**
- Server module with the chosen library; export config; `server/discover` advertises versions and capabilities.
- **Approvals over MRTR:** when a client calls an `:artifact` tool that needs approval, the server returns
  `resultType: "input_required"` with an approval-shaped input request **and an opaque `requestState` carrying
  everything needed to resume**; the human decides in Trinity's UI, or the client answers on retry with a decision
  token the gate validates. The server mints and validates `requestState` and accepts no retry without it. This is
  what lets the headless profile stay stateless: without it an approval begun on one instance could only be
  completed on that same instance, an affinity the profile does not declare. Decisions are receipted.
- Tasks extension for long tools; OTel `traceparent` propagation from `_meta` (feeds 090).
- Auth: `Trinity.MCP.Auth.Local` default (loopback bind + static token); the full RS profile is slice 062.
- `MIX_ENV=prod TRINITY_MODE=headless` release: no Tauri, no LiveView required, MCP + HTTP API only; systemd unit example.
- Docs page with connection snippets for common clients (Claude Code, Codex, goose, VS Code).
**Out:** MCP Apps (server-rendered UI): follow-up; internet exposure.

## Acceptance criteria
1. [auto] Our 060 client connects at 2026-07-28 and lists exported tools; a 2025-11-25 test client connects to the same
   route (tests). Amended at G1, 2026-09-22: the 2025-11-25 client connects to the same wrapper over the stdio wire, since the core's HTTP transport serves 2026-07-28 alone by its design (NOTES.md, "Read before code").
2. [auto] `tools/list` is deterministic and carries `ttlMs`/`cacheScope`; two calls return identical order (test).
3. [auto] `recall` via MCP yields a query receipt with `origin: "mcp"` (test).
4. [auto] An `:artifact` tool via MCP → `input_required` → approval in UI → retry succeeds; deny → retry gets a denial
   result and a receipt (tests + screenshot).
5. [auto] A tool claiming `:catalog` is not exportable (config validation test).
6. [auto] Headless release boots in a container with no display and serves `server/discover` (log).
7. [auto] An MRTR exchange begun against one server instance completes against a different instance of the same release, carrying only the `requestState`; a retry with it altered or missing is refused (test).
8. [manual] Claude Code connected and calling `recall` (screenshot).

## Manual verification queue
Every `[manual]` criterion below needs a person. Listed here so the owner sees the queue at G1 rather
than at review time.
- **AC8**: Claude Code connected and calling `recall` (screenshot).

## Definition of Done
- [ ] gate green · [ ] AC1–8 proven · [ ] docs synced · [ ] ROADMAP → done · [ ] commit + tag

## Commit & tag
`feat(s061): complete slice 061 (MCP server)` · tag `slice/061`
