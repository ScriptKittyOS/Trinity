# Slice 062 — MCP authorization: resource server, embedded authorization server, Enterprise Managed Authorization

| Field | Value |
|---|---|
| Phase | 6 MCP |
| Milestone | M5 Always-on |
| Size | L |
| Depends on | 061 |

Supersedes the 2026-09-05 first draft (RS only, AS "owner decision").

## Goal
Make Trinity's MCP server enterprise-connectable per MCP 2026-07-28: (1) the **resource server** profile
(RFC 9728 Protected Resource Metadata, `401` + `WWW-Authenticate`, audience-bound bearer validation, RFC 8707);
(2) a **small embedded authorization server** (`Trinity.MCP.AuthServer`) so the server has an AS of record without
requiring an external IdP: RFC 8414 metadata, authorization-code + PKCE for individual users (login = the local
Trinity user or an OIDC upstream), Client ID Metadata Documents (CIMD) with DCR only as a legacy fallback, RFC 9207
`iss`, short-lived JWT access tokens with `aud` = the MCP server's resource identifier, scopes mapped to the gate;
(3) the **Enterprise Managed Authorization** extension: accept an ID-JAG (Identity Assertion JWT Authorization Grant,
RFC 8693 token exchange at the IdP, redeemed via the RFC 7523 JWT-bearer grant at our AS), validate it against the
IdP's JWKS (issuer, audience = our AS, subject, expiry, `client_id`), apply local policy (verified email domain →
organisation, group → scopes), and issue our own access token; admins configure trusted IdPs in Settings.

Identity is not authority (docs/09): OAuth/EMA answers *who is calling and with what scopes*; the permission gate and,
the selected authority adapter answer *may this effect happen*. Every token decision is receipted.

## Scope
**In:** the three components above as `Trinity.MCP.Auth.*` behind the `Trinity.MCP.Auth` behaviour (`Local`
loopback default unchanged; `Embedded` = RS + AS + EMA; `JWT`/`Introspection`/`TrustedHeaders` for external AS or
gateway deployments); key management via `Trinity.Secrets` with JWKS publication and rotation; admin UI for IdPs,
clients (CIMD URLs), scopes; conformance tests modelled on the spec's flows; docs page.
**Out:** SAML assertions as the identity assertion input (OIDC ID tokens only in v1); MCP Apps; refresh tokens for EMA
(the extension issues none).

## Acceptance criteria
1. [auto] RS: unauthenticated → 401 with `resource_metadata`; PRM lists our AS; wrong `aud`/expired → 401; each receipted (tests).
2. [auto] AS: a CIMD-registered test client completes authorization-code + PKCE with resource indicator and receives an
   audience-bound token that the RS accepts; DCR path works only when explicitly enabled (tests).
3. [auto] EMA: a fake enterprise IdP (in-repo, publishes OIDC discovery + JWKS) issues an ID-JAG for user `u@example.com`;
   our AS validates it, maps domain → org and group → scopes, issues an access token; the RS accepts it; a token for an
   unverified domain is refused; a replayed/expired ID-JAG is refused (tests, with the exact claim checks named).
4. [auto] Scope mapping: `trinity:recall` cannot call an `:artifact` tool; `trinity:tools:artifact` can, subject to the gate (tests).
5. [auto] Key rotation: rotate the AS signing key; old tokens verify until expiry via JWKS `kid`; new tokens use the new key (test).
6. [manual] Manual: one real MCP client that supports EMA (per the MCP client matrix at the time) connects through the fake IdP
   flow; screenshots. If none is available on the developer machine, recorded as not measured.
7. [auto] The library boundary: `Trinity.MCP.Auth.*` has no dependency on `Trinity.Sessions`/`Trinity.Tools` (boundary check),
   so it can be extracted per ADR-0011.

## Definition of Done
- [ ] gate green · [ ] AC1–7 proven · [ ] docs/08, docs/10 synced · [ ] ADR-0011 note appended · [ ] ROADMAP → done · [ ] commit + tag

## Commit & tag
`feat(s062): complete slice 062 — MCP authorization (RS, embedded AS, EMA)` · tag `slice/062`

## Risks / open questions
- R23: ID-JAG draft revision pinned in NOTES.md; re-check at each phase boundary.
