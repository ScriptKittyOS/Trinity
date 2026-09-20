# 08: Standards landscape and Trinity's posture

Verified 2026-09-05. Re-verify at each phase boundary; this area moves monthly.

## Governance: the Agentic AI Foundation (AAIF)

**Lifecycle (policy effective 2026-03-18; Sandbox stage added 2026-09-01):** Sandbox → Growth → Impact → Emeritus.
Sandbox entry, as the Sandbox announcement states it: a working implementation, plus either early external interest
or a credible thesis (a protocol that needs to exist counts), plus a named active maintainer. Sandbox gets standard
infrastructure only, "no funding, no marketing, no scanning", a 6-month checkpoint, and a 12-month clock to apply for
Growth (two unaffiliated production users, commits from two orgs over six months, a growth plan with a TC sponsor);
missing that deadline triggers an archival discussion.

⚠️ **Corrected 2026-09-05.** This paragraph previously listed an OSI licence, a 1-2 page thesis, transfer of
trademarks and assets to the LF, adoption of the LF technical charter and a TC majority vote as Sandbox entry
requirements. The announcement states none of those at Sandbox, and the transfer requirement in particular was
carrying a High/High risk row and a legal-review gate. The charter text has not been read; everything about asset
transfer, and the Growth bar, stays **unverified** until it is. Proposals: `github.com/aaif/project-proposals`.
Trinity's posture: ADR-0012; package assembled in slice 122.

Linux Foundation directed fund formed 2025-12-09. Founding projects: **MCP** (donated by Anthropic), **goose**
(Block), **AGENTS.md** (OpenAI). **A2A** (donated to LF by Google, June 2025) was accepted as a Growth Stage
project and reached v1.0 in 2026. Platinum members: AWS, Anthropic, Block, Bloomberg, Cloudflare, Google,
Microsoft, OpenAI. Trinity targets AAIF-governed standards first; vendor-specific protocols second.

## The standards, what they are for, and what Trinity does with them

| Standard | Layer | Status (2026-09) | Trinity posture | Slice |
|---|---|---|---|---|
| **MCP 2026-07-28** | agent ↔ tools/data | Current stable. Date-versioned; there is no "2.0". Tier-1 SDKs went to major version 2 alongside it, which is where the nickname comes from; do not use it in any record. Tier-1 SDKs v2 shipped day-of. | **Primary target** for both client and server. Serve 2025-11-25 clients via compatibility for ≥ 12 months. | 059, 060, 061, 062 |
| MCP 2025-11-25 | " | Legacy; 12-month deprecation policy applies to removed features | Client: connect to older servers. Server: compat profile. | 060, 061 |
| MCP 2024-11-05 | " | Obsolete | Not a target. Trinity speaks 2026-07-28 and serves 2025-11-25 for compatibility; anything older is out of scope. | none |
| MCP extensions: **Tasks**, **MCP Apps**, **Enterprise Managed Authorization (EMA)** | " | Official, versioned extensions. EMA = the IETF Identity Assertion JWT Authorization Grant (ID-JAG, "Cross-App Access"): the enterprise IdP mints an assertion via RFC 8693 token exchange; the MCP server's **own authorization server** redeems it via the RFC 7523 JWT-bearer grant and issues its access token. Adopted by MCP June 2026; vendors label it beta. | Tasks: yes. MCP Apps: later. **EMA: yes**, Trinity ships a small embedded AS so the enterprise-managed flow works without a third-party auth product (062). Identity is not authority: the gate, or the selected authority adapter, still decides whether an effect happens. | 061, 062 |
| MCP authorization (OAuth 2.1, RFC 9728 PRM, RFC 8707 resource indicators, RFC 8414/OIDC discovery, CIMD, RFC 9207) | auth | Normative in 2026-07-28; DCR deprecated → CIMD | Trinity's MCP server = OAuth 2.1 **resource server** for non-loopback clients; the authorization server is an owner decision, and it is an identity concern rather than an authority one (ADR-0008). Client = OAuth 2.1 client with PKCE + resource indicators; CIMD first, DCR fallback. | 060, 062 |
| **Agent Skills** (agentskills.io, `SKILL.md`) | procedural knowledge | Open spec (Dec 2025), adopted by Claude Code, Codex, Gemini CLI, Copilot, Cursor, goose, Letta, 20+ others; `npx skills` distribution | Already ADR-0006. Add: honour `allowed-tools` frontmatter (experimental) as a permission hint; support `npx skills`-style GitHub install. | 040, 041 |
| **AGENTS.md** | project context | AAIF founding project; simple markdown convention | Load `AGENTS.md` from the session's project root(s) into the context tier, with precedence and size cap. | 033 |
| **A2A v1.0** | agent ↔ agent | Stable, Apache-2.0, LF/AAIF; Agent Cards, Tasks, streaming | Not v1. Optional later: publish an Agent Card and accept A2A tasks so other agents can delegate to Trinity; map A2A Task ↔ Trinity subagent. | 081 (optional) |
| ACP (Agent Client Protocol, Zed) | editor ↔ agent | Adopted by Zed, JetBrains and others | Not planned. Would let editors drive Trinity. Candidate follow-up after M6. | none |
| OpenTelemetry trace context in MCP `_meta` | observability | Documented convention in 2026-07-28 | Propagate `traceparent` through tool calls (fits Slice 090). | 090 |

## MCP 2026-07-28: the changes that affect our design

1. **Stateless core.** No `initialize`/`initialized`, no `Mcp-Session-Id`. Each request carries
   `io.modelcontextprotocol/protocolVersion` and `clientCapabilities` in `_meta`. Servers MUST implement
   `server/discover`. Consequence: our MCP *server* is a stateless Plug, no per-connection process, trivially
   embeddable in Phoenix and trivially runnable headless. Cross-call state must be explicit server-minted handles
   passed as tool arguments (we already have session ids).
2. **Multi Round-Trip Requests (MRTR)** replace server-initiated `sampling/createMessage`, `elicitation/create`,
   `roots/list`. A server returns `resultType: "input_required"` with `inputRequests` **and an opaque
   `requestState`**; the client retries the original request with `inputResponses` keyed identically **and the
   `requestState` echoed back unmodified**. That echo is what makes MRTR work on a stateless server: all the
   state rides in the payload, so any instance can resume the work. Consequence: our permission gate over MCP maps naturally to MRTR
   (approval = input_required → user decides → retry), and our client must implement the retry loop.
3. **Deprecated:** Roots, Sampling, Logging (use tool params/resource URIs, provider APIs directly, stderr/OTel),
   HTTP+SSE transport, DCR. Do not build new code on these.
4. **Extensions framework** with `extensions` in capabilities. Tasks (`io.modelcontextprotocol/tasks`,
   poll-based `tasks/get`, `tasks/update`) is the one we use.
5. **Subscriptions** via a single `subscriptions/listen` stream per opted-in notification type
   (`toolsListChanged`, …) instead of the GET endpoint.
6. **Cacheable lists**: `tools/list` etc. MUST return `ttlMs` + `cacheScope`; return tools in deterministic
   order (prompt-cache friendly: we do this anyway).
7. **HTTP headers**: `Mcp-Method`, `Mcp-Name` required on POSTs; `x-mcp-header` passthrough. Useful for
   any gateway sitting in front of the server, which can route and authorize on headers without parsing bodies.
8. **Auth hardening** (see ADR-0008).
9. **Error codes** `-32020..-32099` reserved for the spec; implementation-defined `-32000..-32019`.
10. **SSE resumability removed**; a broken stream = re-issue the request with a new id.

## Elixir library situation (the reason Slice 059 exists)

| Library | Spec support | License | Maturity | Notes |
|---|---|---|---|---|
| anubis_mcp 2.0.x | ≤ 2025-11-25 (no 2026-07-28 seen) | **LGPL-3.0** | Established (358k downloads), single maintainer | LGPL is a distribution consideration for a shipped desktop binary; needs legal review before adoption. |
| fastest_mcp 0.3.x | **2026-07-28 + 2025-11-25**, client + server, OAuth, Tasks, MCP Apps, stdio + Streamable HTTP, OTel | Apache-2.0 | Very new (Aug 2026, ~400 downloads), Elixir ≥ 1.19 | Best feature match; adoption risk. |
| gen_mcp 2.0.x | 2026-07-28 stateless server + compat plug for 2025 clients | verify | Server only | Would need a separate client. |
| Own implementation | none | none | none | The stateless server side is small (a Plug + JSON-RPC dispatch + `server/discover`). A viable fallback for the *server*; the *client* side (MRTR, tasks, OAuth) is more work. |

Decision procedure: Slice 059 spike, then ADR-0007 is finalised.
