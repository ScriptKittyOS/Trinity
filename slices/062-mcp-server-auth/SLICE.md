# Slice 062: MCP authorization: resource server, embedded authorization server, Enterprise Managed Authorization

| Field | Value |
|---|---|
| Phase | 6 MCP |
| Milestone | M5a Automates |
| Size | L |
| Depends on | 061 |

Supersedes the 2026-09-05 first draft (RS only, AS "owner decision").

**Amended 2026-09-20 under ADR-0007 decision 8.** This slice owns authorization in every role. The OAuth client
role moves here from slice 060: PRM discovery, AS metadata (RFC 8414 and OIDC), PKCE, RFC 8707 resource
indicators, CIMD first with DCR as the legacy fallback, RFC 9207 `iss` checking, per-issuer credential storage via
`Trinity.Secrets`. The 060 driver consumes the tokens this role obtains. The resource server half lives above
beam_mcp, whose will-not-implement entry 8 keeps OAuth out of the core; the `:authorize` and `:authorize_body`
hooks are where the RS attaches.

**Amended 2026-09-22 under the owner's decision (NOTES.md, "Amendment: EMA leaves the slice").** Quoted:
"production profile is OAuth client + resource server against an external enterprise AS. Embedded AS is a
non-default personal profile and must not be the path that can mint authority for healthcare or DoD effects."
Component (3) below, Enterprise Managed Authorization, is removed from this slice: Trinity does not redeem an
ID-JAG and does not issue production access tokens; the external authorization server does both, and Trinity's
resource server accepts what it issues. The embedded authorization server is the `:personal` profile, not the
default, refused at boot under an external authority adapter, and every token it mints is marked and refused in
`:production`. AC3 and AC6 are removed (below); the goal's text above them is history, not the spec.

**Non-person identity, noted for a later amendment.** A deployment that requires it gives each Trinity instance
an X.509 credential from the deployment's own PKI, and the boot receipt carries a sponsor field naming the
accountable person. SPIFFE is an issuance path for that credential, not an identity model of its own. No
acceptance criterion is added for it until the standards register carries the row that asks for it.

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

Identity is not authority: OAuth/EMA answers *who is calling and with what scopes*; the permission gate and,
the selected authority adapter answer *may this effect happen*. Every token decision is receipted.

## Scope
**In:** the OAuth client role described in the amendment above, as `Trinity.MCP.Auth.Client`; the three components above as `Trinity.MCP.Auth.*` behind the `Trinity.MCP.Auth` behaviour (`Local`
loopback default unchanged; `Embedded` = RS + AS + EMA; `JWT`/`Introspection`/`TrustedHeaders` for external AS or
gateway deployments); key management via `Trinity.Secrets` with JWKS publication and rotation; admin UI for IdPs,
clients (CIMD URLs), scopes; conformance tests modelled on the spec's flows; docs page.
**Out:** SAML assertions as the identity assertion input (OIDC ID tokens only in v1); MCP Apps; refresh tokens for EMA
(the extension issues none).

## Acceptance criteria
1. [auto] RS: unauthenticated → 401 with `resource_metadata`; PRM lists our AS; wrong `aud`/expired → 401; each receipted (tests).
2. [auto] AS: a CIMD-registered test client completes authorization-code + PKCE with resource indicator and receives an
   audience-bound token that the RS accepts; DCR path works only when explicitly enabled (tests).
3. [removed] EMA: a fake enterprise IdP (in-repo, publishes OIDC discovery + JWKS) issues an ID-JAG for user `u@example.com`;
   our AS validates it, maps domain → org and group → scopes, issues an access token; the RS accepts it; a token for an
   unverified domain is refused; a replayed/expired ID-JAG is refused (tests, with the exact claim checks named). Paused at G1, 2026-09-22, under the owner's decision that Trinity is not the issuer of production authority (NOTES.md, "Paused"); the owner's answer decides whether it leaves the slice.
   Removed 2026-09-22 by the owner's answer (NOTES.md, "Amendment: EMA leaves the slice"): Trinity is not the issuer; the external AS redeems the ID-JAG and AC1 covers the token it issues. Deferred, not built in any profile.

4. [auto] Scope mapping: `trinity:recall` cannot call an `:artifact` tool; `trinity:tools:artifact` can, subject to the gate (tests).
5. [auto] Key rotation: rotate the AS signing key; old tokens verify until expiry via JWKS `kid`; new tokens use the new key (test).
6. [removed] Manual: one real MCP client that supports EMA (per the MCP client matrix at the time) connects through the fake IdP
   flow; screenshots. If none is available on the developer machine, recorded as not measured. Removed 2026-09-22 with AC3.
7. [auto] The library boundary: `Trinity.MCP.Auth.*` has no dependency on `Trinity.Sessions`/`Trinity.Tools` (boundary check),
   so it can be extracted as its own package (slice 123).
8. [auto] Client role: against a test AS (in-repo fake supporting CIMD, PKCE and resource indicators), the client
   obtains an audience-bound token and the RS accepts it; wrong `iss` is rejected; the 060 driver presents that
   token without performing any flow of its own (tests).

## Manual verification queue
Every `[manual]` criterion below needs a person. Listed here so the owner sees the queue at G1 rather
than at review time.
- **AC6**: Manual: one real MCP client that supports EMA (per the MCP client matrix at the time) connects through the fake IdP.
  Removed 2026-09-22 with AC3. The queue is empty; the personal profile's consent page is in `proof/` as a
  screenshot for the owner's eye, not as a criterion.

## Definition of Done
- [ ] gate green · [ ] AC1–8 proven (3 and 6 removed, recorded as such) · [ ] docs/08 synced · [ ] ROADMAP → done · [ ] commit + tag

## Commit & tag
`feat(s062): complete slice 062 (MCP authorization: client role, resource server, personal-profile AS)` · tag `slice/062`
(amended 2026-09-22; was "RS, embedded AS, EMA")

## Risks / open questions
- R23: ID-JAG draft revision pinned in NOTES.md; re-check at each phase boundary. Moot for this slice since
  2026-09-22: no ID-JAG is redeemed here (docs/06 re-scopes the row).
