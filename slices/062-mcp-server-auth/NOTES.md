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

## Amendment: EMA leaves the slice, 2026-09-22

The owner's answer to the G1 question, quoted: "Remove Enterprise Managed Authorization from this slice.
Do not implement Trinity-as-issuer of production access tokens from an ID-JAG. The external enterprise AS
already issues audience-bound tokens the resource server accepts. ID-JAG/EMA stays out of 062; record it in
NOTES as deferred, not 'personal-profile EMA.'" And the profile table the owner set, as the tree holds it:

| Profile | Default | Trinity issues tokens? | Allowed under an external authority adapter |
|---|---|---|---|
| `:local` | yes | no (061's static bearer) | yes |
| `:production` | no | never | required for a regulated deployment |
| `:personal` | no | only the embedded AS, on the owner's machine | no: `Config.new/1` errors and the boot raises when `Trinity.Authority.impl/0` is not `Trinity.Authority.Local` |

Answer (a) of the G1 question, so: AC3 and AC6 are `[removed]` in SLICE.md in this commit (the slice
process: the amendment here, the criteria there, one commit); the SLICE's goal paragraph keeps its EMA
text as history under an amendment note. Nothing of EMA was built, in any profile.

**Deferred: Enterprise Managed Authorization (ID-JAG redemption at Trinity's authorization server).**
Owner: the product owner. Since: 2026-09-22. Lift condition, checkable by a stranger: a row in
docs/09-standards-register.md that asks Trinity to be the issuer of an access token for an enterprise
identity, carrying the owner's written reversal of the 2026-09-22 decision. Until then the standards row
for EMA reads "satisfied by the external authorization server" (docs/08), R23 in docs/06 is re-scoped to
that server, and no slice builds the redemption.

## Recovery, 2026-09-22

The session that built the tree above crashed mid-implementation. Found on `slice/062-mcp-auth` at
recovery: four commits past `b4a7bb9` (`git log --oneline main..HEAD`: `08c2014` the G1 plan, `34e56d2`
the boundary and the host, `e18e3c9` 061's test at 401, `a29dcb4` the fake AS with AC1, AC4, AC5 green) and
one untracked file, `test/trinity/mcp/auth/embedded_test.exs`, the AC2 test that was red. No stash. The
compile under `--warnings-as-errors` failed on one unused attribute (`@refresh_floor_ms` in JWKS, the
floor its moduledoc promised and the code never wired); a forced compile cleared a stale boundary manifest
naming the deleted `Server.Auth.Local`. The four AC2 failures had two causes, both in the tree and neither
in the test's flow: the personal profile's resource-server half checked `iss` against the resource
identifier while its issuing half wrote the resource's origin (`Embedded.issuer/1` is now the one source),
and the CIMD path accepted an `http://` document URL only under `dcr: true`, which the fake client on a
loopback port never had. The rotation test then found a tie: two keys made in one second sorted by file
name, so the older could stay the signer (`Keys.rotate!/1` now makes the new key strictly newer).

## Deviations from SLICE.md and the G1 plan (recorded before the commits that carry them)

1. **EMA and its admin UI (trusted IdPs, domain and group mapping) are out**, above. With them the
   SLICE's "admin UI for IdPs, clients (CIMD URLs), scopes": a CIMD client needs no registration (its id
   is its document's URL), DCR clients are a file beside the keys, and the scopes are the three
   `Trinity.MCP.Auth.Scopes` knows. No settings page was built for the profile either: the profile is
   configuration (`config :trinity, :mcp_auth`; `TRINITY_MCP_AUTH_*` in `config/runtime.exs`), and the
   `/mcp` page carries the client role's one control, "authorize" on a server that answered `401`. The
   owner's instruction at recovery: no product UI beyond that.
2. **`TrustedHeaders` (a gateway that authenticates ahead of Trinity) is not a profile.** The production
   profile has two modes, JWT validation and RFC 7662 introspection; a gateway that strips the bearer and
   asserts identity in headers would be the one profile where the token is not what the resource server
   reads, and the owner's constraint "no tool dispatch without an audience-bound token" is why it is not
   here. A follow-up if a deployment asks.
3. **The principal travels in the request process's dictionary** from `Trinity.MCP.Server.Plug` (which
   sees the connection) to `Trinity.MCP.Server` (which sees the message), because the core's transport
   dispatches in the conn's process and offers no per-request context. The G1 plan said NOTES would say
   so. It is set after authorization, read once into `Trinity.Tools.Context.principal`, and dies with the
   process; the wrapper never sees the conn.
4. **`Trinity.Tools.Context.principal` is a map in receipt form** (`%{"iss", "sub", "scope", "client_id",
   "profile"}`), not the `Principal` struct: `Trinity.Tools` does not depend on `Trinity.MCP.Auth` and
   need not; the map is what the receipts carry, so nothing converts on the way out.
5. **A CIMD document over `http://` is accepted on a loopback host and nowhere else.** The CIMD draft
   wants `https`; the personal profile runs on the owner's machine, where a local client publishing its
   metadata on `127.0.0.1` is a process of the owner's (RFC 8252 section 7.3's reasoning for loopback
   redirects, applied to the document). The `dcr: true` coupling the crashed session had is gone.
6. **No `mix trinity.mcp.rotate_key` task.** `Trinity.MCP.AuthHost.rotate_key!/0` rotates (the test
   drives it); a task is a follow-up, since the personal profile has no operator to hand it to yet.
7. **The keys and the client role's store are files**, under 024's key custody directory
   (`mcp-as-<kid>.jwk.json`, mode 0600) and `<data dir>/secrets/oauth/` (mode 0600, one file per
   resource), named in every moduledoc as what stands until slice 100's keychain.
8. **The JWKS cache is a `:persistent_term` per issuer**, refreshed on an unknown `kid` at most once a
   minute per issuer (the floor the moduledoc promised, wired at recovery). A flood of unknown kids is
   answered from the cache; a rotation is one fetch.

## Findings

- **F1.** The fake AS's token endpoint (`test/support/mcp/fake_as.ex`) replaced its whole state with the
  codes map on the first exchange (`Agent.get_and_update` with `Map.pop`'s tuple); the crashed session had
  not reached it. Found by the AC8 test, fixed in the same commit.
- **F2.** `URI.parse/1` gives `"::1"` as the host of `http://[::1]/…`, so a loopback list holding `"[::1]"`
  never matched it. One list (`@loopback_hosts`) holds the three now.
- **F3.** 060's client kept `auth_challenge` after a successful reconnect; the page would have offered
  "authorize" on a ready server. Cleared on connect.
- **F4.** The consent page's CSRF input renders `name="_csrf_token" type="hidden" hidden value=…`; the AC2
  test's first regex assumed `name … value` adjacent.

## Follow-ups

- A `mix trinity.mcp.rotate_key` task and a prune schedule for the personal profile's old keys
  (`Keys.prune!/2` exists; nothing calls it).
- Refresh tokens for the client role (the store holds an access token and its expiry; when it expires the
  owner authorizes again). The enterprise AS decides whether it issues them.
- The web pages' own authentication (the reverse proxy stands in; docs/07 "MCP server").
- The `TrustedHeaders` profile, only if a deployment asks (deviation 2).
- The `[::1]` origin in `Server.Plug.loopback_origins/0` is a browser `Origin` header (bracketed there,
  rightly); F2 is about `URI.host`, not that list.

## Correction, 2026-09-22, after the tag: the release build was broken

**F5, found by the `package` workflow at the `slice/062` tag** (run 35786247006, the first run of
that workflow over this slice: its push trigger is tags only). The linux and windows legs failed to
compile:

```
== Compilation error in file lib/trinity_web/endpoint.ex ==
** (ArgumentError) cannot escape #Function<0.132933281/1 in Trinity.MCP.Server.Plug.init/1>.
   The supported values are: lists, tuples, maps, atoms, numbers, bitstrings, PIDs and remote
   functions in the format &Mod.fun/arity
```

`Plug.Builder` calls a plug's `init/1` **at compile time** when `MIX_ENV=prod` and escapes what it
returns into the compiled endpoint. Slice 062 replaced 061's `authorize: &Auth.Local.authorize/1`
(a remote capture, which escapes) with an anonymous function closing over the process-dictionary
key (which cannot be escaped). `mix gate` runs in `MIX_ENV=test`, where `init/1` is called per
request, so the local gate and all three CI legs were green over a tree whose release could not
compile. Reproduced on `main` at `9859fbe` in one command, before any fix:

```
$ MIX_ENV=prod mix compile
== Compilation error in file lib/trinity_web/endpoint.ex ==
** (ArgumentError) cannot escape #Function<0.132933281/1 in Trinity.MCP.Server.Plug.init/1>. …
exit 1
```

Fixed in `fix(s062)` on `fix/s062-prod-compile`: the hook is `&__MODULE__.authorized/1`, a public
function with the same body, as 061's was a remote capture. The regression test is
`test/trinity/mcp/server_test.exs`, "every option the plug's init returns can be escaped, as a
compile-time init must be": it runs `Macro.escape/1` over `Plug.init([])`, which is the compile-time
step that failed. Demonstrated red against the closure first, with the same message CI printed.

The slice is not rewritten and the tag is not moved: this is a fix commit referencing the original,
as CLAUDE.md section 4 and docs/04 require.

**Follow-up (new, and the reason this was missed): the gate never compiles `:prod`.** Nothing in
`mix gate` or in the push-triggered CI builds a release, and `package.yml` only triggers on tags,
so a compile-time defect in a plug's options, a release-only config error, or anything else that
differs between `:test` and `:prod` is invisible until a tag exists, which is after approval. Two
candidate fixes, for the owner: add a `MIX_ENV=prod mix compile` step to the gate (about a minute
per run, catches this whole class), or give `package.yml` a `branches:` push trigger beside its
tags one (slower, but proves the bundle too). Owner's call; not done here, since the gate is every
slice's contract and this slice does not own it.

### F5 verified on all three platforms, 2026-09-22

The `package` workflow, dispatched by hand against `main` at `16be4d1` (the fix merged), is green
on every leg:

```
$ gh run view 35788732106 --json conclusion,jobs
{"conclusion":"success",
 "jobs":["windows x86_64: success","linux x86_64: success","macOS aarch64: success"],
 "sha":"16be4d16f7501309be315fe8f86cfeb0307cccf3"}
```

https://github.com/ScriptKittyOS/Trinity/actions/runs/35788732106 — each leg compiles the release,
builds the Burrito binary and the Tauri shell, and smokes it. The same workflow at the `slice/062`
tag (`9859fbe`, run 35786247006) failed all three on the compile step, so the pair is the before and
after. The tag is not moved: `slice/062` still names the tree as it was approved, and the fix is
`16be4d1` above it.
