# Slice 062: NOTES

## Read before code, 2026-09-22

Tree at `b4a7bb9` on `main` (050 approved; 061 the dependency). What this slice joins: 061's server (the
wrapper above the core, `Trinity.MCP.Server.Auth.Local` as the `:authorize` hook, the MCP session and its
receipts, the plug in the endpoint ahead of the parsers), 060's client (`Trinity.MCP.Client.Auth.bearer/1`,
the seam a static token fills), 024's authority selection (`Trinity.Authority.Selection.selected/0`: `Local`,
or the external adapter a regulated deployment names), the receipts (decision and query on the MCP session's
scope), and ADR-0008 decision 4: identity is not authority.

**The owner's decision of 2026-09-22, which shapes every line below.** Quoted: "production profile is OAuth
client + resource server against an external enterprise AS. Embedded AS is a non-default personal profile
and must not be the path that can mint authority for healthcare or DoD effects." And the constraint: "no
tool dispatch without an audience-bound token and a host gate; no token material in the model context;
receipts must name issuer/subject/scope. Pause if the slice would make Trinity the issuer of production
authority."

Measured today: `jose` 1.11.12 on hex.pm (MIT, 2025-11-20), the JOSE library the JWT work uses (JWK, JWS,
JWKS; ES256 and EdDSA through OTP's crypto); not `joken` (Apache-2.0, a layer over jose this slice does not
need). One new row in VERSIONS.md.

### The profiles, as this slice builds them

`config :trinity, :mcp_auth, profile:` names one of three; the first is the default, as at 061.

- **`:local`** (the default; the desktop, a developer's machine): 061's static bearer on the loopback bind,
  unchanged. No token is a JWT; nothing here is an authorization server.
- **`:production`** (the owner's production profile): Trinity is an OAuth 2.1 **resource server** against an
  **external** authorization server the deployment names (`issuer:`, `resource:` the server's own identifier,
  `audience:` defaulting to it). RFC 9728 Protected Resource Metadata at `/.well-known/oauth-protected-resource`
  listing that issuer; a request without a valid bearer is `401` with `WWW-Authenticate: Bearer
  resource_metadata="…"`; a bearer is a JWT validated against the issuer's JWKS (RFC 8414 / OIDC discovery of the
  issuer at boot, the JWKS cached and refreshed on an unknown `kid`): `iss` equal to the configured issuer,
  `aud` containing the resource identifier (audience-bound, or refused), `exp` and `nbf`, `alg` in the allow
  list (ES256, ES384, EdDSA, RS256; never `none`, never HMAC). `introspection: true` selects RFC 7662 against
  the issuer for opaque tokens instead. Trinity issues nothing in this profile.
- **`:personal`** (non-default, and refused where it must be): the same resource server plus a small **embedded
  authorization server** for a person's own machine: RFC 8414 metadata, authorization-code with PKCE (S256
  only), the consent page answered by the owner in the browser (the local Trinity user; no OIDC upstream in
  this slice), Client ID Metadata Documents first (the client's `client_id` is the https URL of its metadata
  document, fetched and checked) and RFC 7591 DCR only with `dcr: true`, RFC 8707 `resource` required, RFC 9207
  `iss` on the authorization response, ES256 access tokens with `aud` = the resource identifier, `scope` from
  the consent, ten minutes of life, JWKS at `/.well-known/jwks.json`, key rotation by `kid`. **This profile
  refuses to start** when `Trinity.Authority.selected/0` is not `Trinity.Authority.Local` (the regulated
  deployment, where an external authority adapter is in force, has no embedded issuer, by construction and
  not by configuration), and every token it mints carries `"profile" => "personal"`, which the resource
  server refuses in the production profile whatever key signed it. That is the owner's "must not be the
  path that can mint authority for healthcare or DoD effects", made a property the tests hold.

### Paused: Enterprise Managed Authorization (AC3)

The SLICE's EMA component redeems an enterprise IdP's ID-JAG *at Trinity's own AS* and issues Trinity's
access token: Trinity as the issuer for enterprise identities, which is the case the owner named as a pause.
In the production profile the external AS is where an ID-JAG is redeemed and Trinity's resource server
validates the token it issues, which the profile above already does; in the personal profile there is no
enterprise IdP. **AC3 is retagged `[paused]` in this commit**, and the question is on the owner's desk (asked
in the same turn as this plan): (a) EMA leaves Trinity: the external AS's job, Trinity's RS accepts what it
issues (the recommendation; the standards row for EMA moves to "satisfied by the external AS"); or (b) EMA
is built inside the personal profile only, which would be an enterprise flow on a machine with no enterprise
IdP. Nothing of EMA is built until the answer; the rest of the slice does not depend on it.

### The three constraints, as properties

- **No tool dispatch without an audience-bound token and a host gate.** In the production and personal
  profiles, `tools/call` reaches the wrapper only through the resource server's check (the Plug refuses
  before the body is read), and the wrapper still runs every call through the permission gate and the
  membrane (061). A token without the resource identifier in `aud` is refused; a scope that does not cover
  the tool's effect is refused before the gate (AC4: `trinity:tools:read` for a `:none` tool, `trinity:tools:artifact`
  for an `:artifact` one; `trinity:recall` an alias of the first for the SLICE's wording).
- **No token material in the model context.** The resource server hands the wrapper a *principal*
  (`iss`, `sub`, `scope`, `client_id`, the token's `jti` when present) and never the token; the principal
  rides in `Trinity.Tools.Context.principal`, a new field, and nowhere in a message, a prompt or a receipt's
  payload does a bearer appear. A census test holds that the only place the `authorization` header is read
  is the auth boundary, and that no module of `Trinity.MCP.Server` names it.
- **Receipts name issuer, subject and scope.** The decision and query receipts an MCP call leaves carry
  `subject.principal = %{iss, sub, scope, client_id}`; a refusal by the resource server (no bearer, wrong
  audience, expired, bad scope) is a decision receipt of outcome `deny` on the MCP session's scope naming what
  it could read of the principal and the reason.

### The client role (AC8)

`Trinity.MCP.Auth.Client`, above 060's transport: on a `401` with `WWW-Authenticate`, the driver reads
`resource_metadata`, the client fetches the PRM, the AS metadata (RFC 8414, OIDC fallback), and runs
authorization-code with PKCE and `resource` (RFC 8707) through a loopback redirect (`/oauth/callback` in
TrinityWeb, the owner opening the authorization URL from the `/mcp` page), checks `iss` (RFC 9207) on the
callback, exchanges the code, and stores the token per issuer under `<data dir>/secrets/oauth/` (mode 0600;
`Trinity.Secrets` is slice 100's keychain, and this file store is what stands until then, named as such).
The client identifies itself by a configured `client_id` (pre-registered at the enterprise AS: the production
path), by CIMD when `client_metadata_url:` is set, and by DCR only when the AS offers it and `dcr: true`.
060's `Client.Auth.bearer/1` reads this store before the environment variable; the driver performs no flow.

### The boundary (AC7)

`Trinity.MCP.Auth` is a boundary of its own under `Trinity.MCP` with `deps: []` on the tree (jose, Plug and
Req are externals): it takes its configuration as arguments (the key directory, the issuer, the resource
identifier), returns decisions (`{:ok, principal} | {:error, reason}`) and writes no receipt and reads no
session; the Plug and the server, in `Trinity.MCP`, receipt what it decides. The compiler holds the rule;
a census test names the modules and their references. That is what lets slice 123 extract it.

## G1 plan, 2026-09-22

Branch `slice/062-mcp-auth`; ROADMAP row 062 to `in_progress`; `jose ~> 1.11` in mix.exs and VERSIONS.md.
Each line names its test.

1. `Trinity.MCP.Auth` (the behaviour: `authorize(conn, config) :: {:ok, principal} | {:error, reason}`,
   `metadata(config)` for the PRM), `Auth.Config` (the profile and its fields, validated at boot),
   `Auth.Principal` (the struct: `iss`, `sub`, `scope`, `client_id`, `jti`, `profile`), `Auth.Token`
   (JWT validation over jose: the claim checks named in code and tests), `Auth.JWKS` (discovery, cache,
   refresh by `kid`), `Auth.Local` (061's bearer moved behind the behaviour). Tests: each claim check red
   on its own (wrong `iss`, missing `aud`, wrong `aud`, expired, `nbf` in the future, `alg` none, a key the
   JWKS does not hold), the personal-profile marker refused in production.
2. The fake enterprise AS in test/support (`Trinity.MCP.Auth.FakeAS`, a Plug behind Bandit: RFC 8414
   metadata, `/authorize` auto-consenting, `/token` with PKCE and `resource`, JWKS, key rotation on demand,
   RFC 7662 introspection). Tests AC1 (401 with `resource_metadata`; the PRM lists the AS; wrong `aud` and
   expired refused; each receipted), AC5 (rotate the fake AS's key: old tokens verify by `kid` until expiry,
   new tokens use the new key).
3. `Trinity.MCP.Server.Plug` runs the profile's `authorize/2` before the transport (the transport's own
   `:authorize` hook stays for the `:local` profile) and hands the principal to the wrapper through the
   request process (the transport dispatches in the conn's process; NOTES will say so as a deviation);
   `Trinity.MCP.Server` puts it in the context and refuses a scope that does not cover the tool
   (`Auth.Scopes`); `Trinity.Effects.Runner` writes `subject.principal`. Tests AC4 and the receipts.
4. `Auth.Embedded` (the personal profile's AS): metadata, authorize with the consent page (`/oauth/authorize`,
   `/oauth/consent` in TrinityWeb), token endpoint, CIMD fetch and check, DCR behind `dcr: true`, ES256 keys
   under `<keys dir>/mcp-as-<kid>.key`, JWKS, rotation (`mix trinity.mcp.rotate_key`), the marker claim, the
   refusal to start under an external authority adapter. Tests AC2 (a CIMD-registered test client completes
   the code flow with PKCE and `resource` and the RS accepts the token; DCR refused unless enabled; the marker
   refused in production; the profile refused under a non-Local authority).
5. `Auth.Client` (the client role) with the `/oauth/callback` route and the file store; `Client.Auth.bearer/1`
   reads the store. Tests AC8 against the fake AS (the token obtained is audience-bound and the RS accepts it;
   a callback with the wrong `iss` is rejected; the 060 driver presents it and performs no flow, by census).
6. The `/mcp` page: the auth profile shown; for a client row, "authorize" when a server answered 401 with a
   resource metadata URL. The settings page: the production profile's issuer and resource identifier (also
   configuration: `TRINITY_MCP_AUTH_*` in `config/runtime.exs`).
7. AC7's census; the no-token-material census; docs/08 (the rows: RS satisfied by this slice under the
   production profile; EMA per the owner's answer), docs/09 (the identity rows' status), docs/07 (the
   profiles and the three constraints), docs/mcp-server.md (connecting through an enterprise AS; the
   personal profile), README; PROOF.

Manual verification queue: **AC6** (a real MCP client that supports EMA connecting through the fake IdP): with
AC3 paused, AC6 is paused with it; if the owner's answer is (a), both leave the slice and the manual queue is
empty. Recorded now so the queue is known at G1.

Not built here: SAML, MCP Apps, refresh tokens for EMA, the OIDC upstream login for the personal profile's
consent (the local owner is the user), the keychain (slice 100), non-person X.509 identity (the SLICE's own
"later amendment").
