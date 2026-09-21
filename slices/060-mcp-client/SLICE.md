# Slice 060: MCP client (2026-07-28 preferred, 2025-11-25 compat)

| Field | Value |
|---|---|
| Phase | 6 MCP |
| Milestone | M5a Automates |
| Size | L |
| Depends on | 059, 021 |

Supersedes the 2026-09-05 first draft of this slice, which targeted anubis_mcp at 2025-11-25 and planned
sampling/elicitation callbacks (both deprecated in 2026-07-28).

**Amended 2026-09-20 under ADR-0007 decision 7.** The size condition is decided: beam_mcp ships no client and
will not, so this slice is L. The client is Trinity's own thin driver. The OAuth client role moves to slice 062,
which owns authorization in every role; this driver consumes the tokens 062 obtains.

**The thin-driver rule, which is a test (AC7).** The driver builds the outbound JSON-RPC request object and
nothing else of the protocol. Decoding and validation call beam_mcp's public functions. Revision handling is
limited to sending `server/discover` and reading `supportedVersions`, with the `initialize` path for 2025-11-25.
If the driver needs its own revision negotiation, envelope vocabulary or schema validator, the slice stops and
the question of a shared client package is raised on the beam_mcp side through the owner, instead of forking.

## Goal
Connect to MCP servers (stdio and Streamable HTTP) with Trinity's own driver over beam_mcp's public functions, one supervised client per
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
- Token use for protected servers: the driver presents the bearer token that slice 062's client role obtained
  and handles `401` with `WWW-Authenticate` by asking 062 for a token; it performs no OAuth flow of its own.
- Order of work: stdio first (Port driven), Streamable HTTP second, both against beam_mcp's shipped transports
  as the server under test.
- Reconnect with backoff; health + tool list in `/mcp` UI.
- Test servers in `test/support/`: a 2026-07-28 server and a 2025-11-25 server built with beam_mcp.
**Out:** sampling, roots, logging (all deprecated); SSE transport; revisions older than 2025-11-25.

## Acceptance criteria
1. [auto] Both test servers connect; version chosen per server is logged and asserted (test).
2. [auto] An MCP tool call flows through `Trinity.Effects` with `effect: :none` and yields a query receipt (test).
3. [auto] A server-config claiming `effect: :catalog` for an MCP tool is refused at load with a receipt (test).
4. [auto] MRTR: test server returns `input_required` with a `requestState`; the Session surfaces the request; answering resumes; the retried call carries the `requestState` back byte-for-byte and completes. A retry with the `requestState` altered or omitted is rejected by the server (test).
5. [deferred] Tasks: a slow tool returns a handle; polling completes; cancel from the UI cancels the task (test). Deferred at G1, 2026-09-21: 059's approved finding 4 says this slice builds no client for an extension the core neither builds nor refuses (NOTES.md, "Read before code").
6. [auto] Server dies → tools unregistered → reconnect → re-registered (test with short backoff).
7. [auto] The thin-driver rule: a census over `lib/trinity/mcp/client/` finds no revision negotiation beyond
   `server/discover` and `initialize`, no protocol object built other than the outbound request, and no schema
   validator; decode and validation are calls into beam_mcp's public functions (test, with the population
   command pasted).
8. [manual] Manual: one real public 2026-07-28 server used end-to-end (GIF).

## Manual verification queue
Every `[manual]` criterion below needs a person. Listed here so the owner sees the queue at G1 rather
than at review time.
- **AC8**: Manual: one real public 2026-07-28 server used end-to-end (GIF).

## Definition of Done
- [ ] gate green · [ ] AC1–8 proven · [ ] docs/01, docs/08 synced · [ ] VERSIONS ✅ · [ ] ROADMAP → done · [ ] commit + tag

## Commit & tag
`feat(s060): complete slice 060 (MCP client)` · tag `slice/060`
