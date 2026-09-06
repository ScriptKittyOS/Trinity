# Slice 060 — MCP client (2026-07-28 preferred, 2025-11-25 compat)

| Field | Value |
|---|---|
| Phase | 6 MCP |
| Milestone | M5 Always-on |
| Size | M/L |
| Depends on | 059, 021 |

Supersedes the 2026-09-05 first draft of this slice, which targeted anubis_mcp at 2025-11-25 and planned
sampling/elicitation callbacks (both deprecated in 2026-07-28).

**Sized `M/L`, conditionally, and the condition is decided by slice 059.** M if 059 selects a library that ships a
working client. L otherwise: a server-only library, or the own-minimal-server fallback, leaves this slice to build
the MRTR retry loop, Tasks polling and the whole OAuth client role — PKCE, resource indicators, client metadata
with dynamic-registration fallback, issuer checking and per-issuer credential storage. `docs/08-standards.md` says
as much in its own words: the stateless server side is small and the client side is more work. A single number
here would be a guess wearing an estimate's clothes.

## Goal
Connect to MCP servers (stdio and Streamable HTTP) with the library chosen in 059, one supervised client per
configured server, preferring 2026-07-28 (`server/discover`, request-scoped `_meta`, MRTR, cacheable lists,
Tasks extension) and falling back to 2025-11-25; expose their tools as runtime-registered tools that can never
enter the effect catalog (M4); health, reconnect, UI.

## Scope
**In:**
- `Trinity.MCP.Supervisor` + per-server client wrappers; `mcp_servers` table (name, transport, command/url, env refs,
  enabled, `effect_default: :none | :artifact`, per-tool effect/risk overrides).
- Version selection: `server/discover` first; on `UnsupportedProtocolVersion` or a legacy probe, 2025-11-25 path.
- `Trinity.MCP.ToolBridge`: `tools/list` → `%Trinity.Tools.Dynamic{}` per tool, **name-spaced `mcp:<server>:<tool>` before any tier lookup so a server cannot claim a core tool's tier**, with `effect` from config
  (default `:none`; `:artifact` allowed; `:catalog` refused and receipted), risk from `tier/1`, definition digest
  recorded; honour `ttlMs` for re-listing; `subscriptions/listen` for `toolsListChanged` where supported.
- **MRTR loop:** a tool result with `resultType: "input_required"` is routed to the Session as an approval-shaped
  request (the user answers in the UI or a gateway), and the original request is retried with `inputResponses`
  keyed identically **and the server's opaque `requestState` echoed back unmodified**. The client never inspects,
  parses or reconstructs `requestState`; treating it as opaque is the contract.
- Tasks extension: long-running tools return a task handle; poll `tasks/get` under the Session's Task with timeout;
  `tasks/update` for client-to-server input when the server asks.
- Results mapped to provenance-tagged content parts (M1), `untrusted` taint.
- OAuth client role for protected servers: PRM discovery, AS metadata (RFC 8414 / OIDC), PKCE, RFC 8707 resource
  indicator, CIMD first with DCR fallback, RFC 9207 `iss` check, per-issuer credential storage via `Trinity.Secrets`.
- Reconnect with backoff; health + tool list in `/mcp` UI.
- Test servers in `test/support/`: a 2026-07-28 server and a 2025-11-25 server built with the chosen library.
**Out:** sampling, roots, logging (all deprecated); SSE transport; revisions older than 2025-11-25.

## Acceptance criteria
1. [auto] Both test servers connect; version chosen per server is logged and asserted (test).
2. [auto] An MCP tool call flows through `Trinity.Effects` with `effect: :none` and yields a query receipt (test).
3. [auto] A server-config claiming `effect: :catalog` for an MCP tool is refused at load with a receipt (test).
4. [auto] MRTR: test server returns `input_required` with a `requestState`; the Session surfaces the request; answering resumes; the retried call carries the `requestState` back byte-for-byte and completes. A retry with the `requestState` altered or omitted is rejected by the server (test).
5. [auto] Tasks: a slow tool returns a handle; polling completes; cancel from the UI cancels the task (test).
6. [auto] Server dies → tools unregistered → reconnect → re-registered (test with short backoff).
7. [auto] OAuth: against a test AS (in-repo fake supporting CIMD + PKCE + resource indicator), the client obtains an
   audience-bound token and the RS accepts it; wrong `iss` is rejected (tests).
8. [manual] Manual: one real public 2026-07-28 server used end-to-end (GIF).

## Manual verification queue
Every `[manual]` criterion below needs a person. Listed here so the owner sees the queue at G1 rather
than at review time.
- **AC8** — Manual: one real public 2026-07-28 server used end-to-end (GIF).

## Definition of Done
- [ ] gate green · [ ] AC1–8 proven · [ ] docs/01, docs/08 synced · [ ] VERSIONS ✅ · [ ] ROADMAP → done · [ ] commit + tag

## Commit & tag
`feat(s060): complete slice 060 — MCP client` · tag `slice/060`
