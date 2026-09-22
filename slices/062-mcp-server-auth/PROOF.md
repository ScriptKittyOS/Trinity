# Proof for slice 062: MCP authorization (client role, resource server, personal-profile authorization server)

Agent: Claude Opus 5 (1M context) · Date: 2026-09-22 · Branch: slice/062-mcp-auth · Final commit: written at the close, below

## Summary

Trinity's MCP server is an OAuth 2.1 resource server (`:production`, against an external
authorization server the deployment names) with a small authorization server of its own for the
owner's machine (`:personal`, non-default) and 061's static bearer as the default (`:local`).
Trinity's client role obtains tokens from a protected server and 060's driver presents them. What
was hard: a crashed session had to be recovered first (NOTES, "Recovery"), and two claims the tree
made turned out not to hold until this slice made them: the personal profile's resource server
checked an issuer its own issuing half never wrote, and the authorization package's `deps: []` was
a claim the compiler never checked because a sub-boundary inherits its ancestors' deps (fixed as a
top-level boundary; the refusal is pasted under AC7). Deferred: Enterprise Managed Authorization
leaves the slice under the owner's decision of 2026-09-22 (AC3 and AC6 removed; NOTES,
"Amendment"), with a lift condition; follow-ups are in NOTES.

## Gate

```
$ mix gate
Compiling 250 files (.ex)
Generated trinity app
Checking 362 source files (this might take a while) ...
Analysis took 0.4 seconds (0.04s to load, 0.4s running 69 checks on 362 files)
2913 mods/funs, found no issues.
##############################################
#          Running Sobelow - v0.15.0         #
##############################################
... SCAN COMPLETE ...
Finished in 116.7 seconds (0.6s async, 116.1s sync)
Result: 524 passed, 18 excluded
trinity.coverage: 050 80.31% vs 061 80.05%: OK
== 1. Acceptance criteria numbered contiguously from 1 ==
== 2. Definition of Done range equals the criterion count ==
== 3. Manual verification queue section present ==
== 4. ROADMAP size and status agree with SLICE.md ==
== 5. Change-log slice count equals the tree ==
== 6. No reference to a plan path absent from git ls-files ==
== 6b. No slice depends on a slice that does not exist ==
== 7. No board identifiers in the tree ==
== 8. Commit messages: no attribution trailers, every commit signed off ==
== 10. No reference to the pre-move owner path ==
== 9. Secrets are ignored, as CLAUDE.md claims ==
== 11. Slice lifecycle matches the branch ==
== 12. Every workflow and Dependabot file parses as YAML ==
plan_check: PASS
gate exit 0
```

Sobelow's traversal findings on this slice's file paths are skipped in the source with a reason
each (`# sobelow_skip reason:` above every `@sobelow_skip`, which `test/sobelow_skips_test.exs`
requires): every path is the host's own (the data directory, the key directory, the token store),
never a request's.

## Tests

```
$ mix test --cover
Finished in 106.4 seconds (0.7s async, 105.7s sync)
Result: 524 passed, 18 excluded
| Percentage | Module                                 |
|     80.92% | Total                                  |
```

The slice's own files and the two MCP suites it touches:

```
$ mix test test/trinity/mcp/auth test/trinity/mcp/server_test.exs test/trinity_web/live/mcp_live_test.exs test/trinity/mcp/boundary_test.exs
Finished in 0.9 seconds (0.1s async, 0.8s sync)
Result: 37 passed
```

## Acceptance criteria evidence

Every criterion below is `[auto]`. AC3 and AC6 were removed on 2026-09-22 under the owner's
decision (SLICE.md and NOTES.md, "Amendment"); nothing of Enterprise Managed Authorization is
built, so nothing of it is proven here.

### AC1: RS: unauthenticated → 401 with `resource_metadata`; PRM lists our AS; wrong `aud`/expired → 401; each receipted

```
$ mix test test/trinity/mcp/auth/token_test.exs test/trinity/mcp/auth/resource_server_test.exs --trace
  * test AC1: an audience-bound token the issuer signed is a principal with issuer, subject, scope and client (3.2ms)
  * test each claim check is its own refusal (4.3ms)
  * test AC1: 401 with resource_metadata; the PRM names the AS; wrong audience, expired and the static bearer are 401; each refusal receipted (20.3ms)
  * test introspection: an opaque token is asked about at the issuer (RFC 7662), the answer's claims checked as a JWT's are (7.4ms)
  * test the configuration refuses an incomplete production profile (5.7ms)
  * test the issuer's metadata is refused when it names another issuer (2.3ms)
```

The refusals, each its own named error, are asserted in `token_test.exs` one at a time: wrong
`iss`, missing `aud`, wrong `aud`, expired, no `exp`, `nbf` in the future, `alg` outside the allow
list, a key the JWKS never held, a malformed token, and the personal profile's mark in production;
`Config.new/1` refuses `none` and any `HS*` in the allow list, and refuses a production profile
with no issuer or no resource. Through the endpoint (`resource_server_test.exs`) the same refusals
are `401` with `WWW-Authenticate: Bearer resource_metadata="…/.well-known/oauth-protected-resource/mcp"`,
the PRM at that URL names the fake enterprise AS as the authorization server, 061's static bearer
is refused in this profile, each refusal leaves a decision receipt of outcome `deny`, basis `auth`,
with the reason and the caller's unverified `iss`/`sub` marked as unverified, and no receipt of the
session matches `eyJ`.

The same endpoints on a running application, in the personal profile
(`scripts/dev_mcp_auth_consent.sh`; full transcript in `proof/personal-profile-endpoints.txt`):

```
$ curl -si -X POST http://127.0.0.1:35717/mcp -H 'content-type: application/json' \
    -H 'mcp-protocol-version: 2026-07-28' -H 'mcp-method: server/discover' \
    -d '{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{}}'
HTTP/1.1 401 Unauthorized
www-authenticate: Bearer resource_metadata="http://127.0.0.1:35717/.well-known/oauth-protected-resource/mcp"
content-type: application/json; charset=utf-8

{"jsonrpc":"2.0","id":null,"error":{"code":-32001,"message":"Unauthorized"}}
```

### AC2: AS: a CIMD-registered client completes code + PKCE with a resource indicator and receives an audience-bound token the RS accepts; DCR only when enabled

```
$ mix test test/trinity/mcp/auth/embedded_test.exs --trace
  * test AC2: the code flow with PKCE and a resource indicator issues an audience-bound token the RS accepts; the metadata and JWKS are published; iss rides the redirect (8.1ms)
  * test a wrong resource, an unknown scope and a denied consent are refusals; DCR is 404 unless enabled; an unknown client is refused (34.1ms)
  * test DCR registers a client when enabled, and the registered client completes the flow (5.0ms)
  * test the personal profile refuses to start under an external authority adapter (9.5ms)
  * test the production profile holds no key material of its own: no keys, no JWKS, no AS metadata (4.4ms)
  * test rotating the signing key: a token the old key signed verifies by kid; new tokens use the new key (10.1ms)
```

The AC2 test drives the real endpoints over HTTP: the RFC 8414 metadata (`S256` only, CIMD
supported, no `registration_endpoint` while DCR is off), the JWKS, the PRM, a `401` with no token,
then `GET /oauth/authorize` with `code_challenge`/`S256`/`resource`/`state`, the owner's consent
form posted with its CSRF token, the redirect carrying `code`, `state` and RFC 9207 `iss`, the
token endpoint with the verifier and the resource, and the resulting token accepted by the resource
server at `/mcp` (200). The code is single use, a wrong verifier is `invalid_grant`, a wrong
`resource` is an `invalid_target` redirect, an unknown scope `invalid_scope`, a denied consent
`access_denied`, an unreachable client document a refusal, and `POST /oauth/register` is `404`
until `dcr: true`. The issued token carries `"profile": "personal"`, `aud` = this server and `iss`
= this server, and the production profile refuses that claim.

Manual view for the owner: `proof/personal-profile-consent.png` (the consent page as it renders,
naming the client, the resource, the scopes asked and what a personal token is not good for).

### AC4: Scope mapping: `trinity:recall` cannot call an `:artifact` tool; `trinity:tools:artifact` can, subject to the gate

```
$ mix test test/trinity/mcp/auth/resource_server_test.exs --trace
  * test AC4 and the receipts: read scope refused on an artifact tool, artifact scope reaches the gate, receipts name the principal, no token material (30.7ms)
```

A token scoped `trinity:tools:read` calling the `memory` tool (`:artifact`) is answered
`insufficient scope: this tool needs trinity:tools:artifact` and leaves a decision receipt of
outcome `deny`, basis `scope`, reason `needs trinity:tools:artifact`, with the principal; the gate
is never asked. The same call under `trinity:tools:artifact` reaches the gate and is held for the
owner (`input_required`), which is the point: a scope is not an allow rule. A read tool under an
allow rule runs, and both its decision and its query receipt carry
`principal = %{iss, sub, scope, client_id, profile}`. No receipt and no message of the MCP session
matches `eyJ`.

### AC5: Key rotation: old tokens verify until expiry via JWKS `kid`; new tokens use the new key

```
$ mix test test/trinity/mcp/auth/token_test.exs --trace
  * test AC5: after the issuer rotates its key, old tokens verify by kid until expiry and new tokens use the new key; a key no longer published fails (3.9ms)
```

Against the external issuer (the fake enterprise AS): after a rotation the new `kid` is unknown to
the cache, one JWKS fetch follows (asserted by counting the fake's fetches), both tokens then
verify, and a key withdrawn from the JWKS makes its token `{:unknown_kid, …}`. For the personal
profile's own keys the same property is driven through the endpoints (`embedded_test.exs`,
"rotating the signing key"): after `AuthHost.rotate_key!/0` the JWKS publishes both kids, a token
signed before the rotation is still accepted at `/mcp`, and a token issued after it carries the new
`kid`.

### AC7: `Trinity.MCP.Auth.*` has no dependency on `Trinity.Sessions`/`Trinity.Tools` (boundary check)

The compiler holds it. Planting the line in `test/support/mcp/planted_auth_reference.ex.txt` inside
`lib/trinity/mcp/auth/scopes.ex` and compiling:

```
$ printf '\n  def planted, do: Trinity.Sessions.history("x")\n' >> …/scopes.ex   # inside the module
$ mix compile --force --warnings-as-errors
warning: forbidden reference to Trinity.Sessions
  (references from Trinity.MCP.Auth to Trinity.Sessions are not allowed)
  lib/trinity/mcp/auth/scopes.ex:33
compile exit 1
```

That refusal only appears since this slice made the package a **top-level** boundary: a
sub-boundary inherits its ancestors' deps unless it says otherwise, and `Trinity.MCP` depends on
`Trinity`, so the package's `deps: []` compiled clean with the same planted line before the fix.
`Trinity.MCP` now names `Trinity.MCP.Auth` as a dependency, which is the only way in.

The census and the no-token-material rule:

```
$ mix test test/trinity/mcp/auth/boundary_test.exs --trace
  * test the boundary is top level, lists no dependency, and exports the package (2.8ms)
  * test the population is the package's files, and no file of it names a module of the tree in code (3.1ms)
  * test the one reader of the Authorization header under lib/ is the boundary; the server side never names a token (14.0ms)
  * test a principal's receipt form carries issuer, subject, scope, client and profile, and nothing else (0.00ms)
  * test the planted line the proof compiles is a real call from the package into the tree (0.1ms)
```

The population is `git ls-files lib/trinity/mcp/auth.ex lib/trinity/mcp/auth` (thirteen files,
listed in the test); the census reads each file with its comments and docs stripped and refuses any
`Trinity.*` reference outside the package. Demonstrated red with the same planted line:

```
$ mix test test/trinity/mcp/auth/boundary_test.exs
  1) test the population is the package's files, and no file of it names a module of the tree in code
     lib/trinity/mcp/auth/scopes.ex reaches the tree: ["Trinity.Sessions.history"]
Result: 3/4 passed
```

The header census derives its population from `git ls-files lib/*.ex lib/**/*.ex lib/**/*.heex`
(over a hundred files, asserted) and holds that `lib/trinity/mcp/auth.ex` is the only reader of the
`Authorization` header, and that no file of `lib/trinity/mcp/server*` names the header, a token or
`Auth.bearer`.

### AC8: Client role: against a test AS the client obtains an audience-bound token the RS accepts; wrong `iss` rejected; the 060 driver performs no flow

```
$ mix test test/trinity/mcp/auth/client_role_test.exs --trace
  * test AC8: 401 to challenge, PKCE against the AS, the token stored and presented, the RS accepts it (9.0ms)
  * test a callback from another issuer is refused; an unknown state is refused; DCR once when allowed and offered; no identity, no flow (7.0ms)
  * test the driver performs no flow: the census over its files (5.7ms)
```

060's driver connects to Trinity's own `/mcp` in the production profile, is refused `401`, and
records the challenge (`auth_challenge` in its info). The host begins the flow: the authorization
URL names the fake enterprise AS, `response_type=code`, the configured `client_id`, `S256` with a
43-character challenge, the resource and a state; the pending request on disk is mode `0600`. The
AS consents, the callback is fetched as a browser would fetch it, and afterwards the token file is
mode `0600`, the pending file is gone, `Client.Auth.bearer/1` returns the token, and the resource
server admits it as a principal with the expected issuer, subject, scope and client. The driver
then reconnects and reaches `ready` at 2026-07-28. Neither the client's info, nor the receipts, nor
the MCP session's messages match `eyJ`. A callback carrying another `iss` is
`{:wrong_issuer, …}`, an unknown `state` is refused, an AS error is surfaced as such, a missing
client identity refuses to begin the flow, and DCR registers once and is then remembered per
issuer. The census over `git ls-files lib/trinity/mcp/client.ex lib/trinity/mcp/client` holds that
no file of the driver names a verifier, a challenge, an authorization or token endpoint, the
client-role functions or the store.

The page (`/mcp`), which is all of the UI this slice added:

```
$ mix test test/trinity_web/live/mcp_live_test.exs --trace
  * test a server that answered 401 with resource metadata shows the challenge; authorize sends the owner to the AS (162.1ms)
```

## Manual verification for the reviewer

Nothing in the acceptance criteria requires a person: AC6, the slice's only `[manual]` criterion,
was removed with AC3. Two artefacts are in `proof/` for the owner's eye rather than as criteria:

- `proof/personal-profile-consent.png`: the consent page in the personal profile.
- `proof/personal-profile-endpoints.txt`: the PRM, the RFC 8414 metadata, the JWKS, the `401` with
  its challenge and the `404` from the registration endpoint, from a running application.

To see either again: `scripts/dev_mcp_auth_consent.sh` prints `PORT=` and the `URL=` a client would
open (its database is `trinity_screenshots.db`, never the suite's). Kill it by the pid
`pgrep -af beam.smp` prints.

## Deviations from SLICE.md

See NOTES.md, "Deviations from SLICE.md and the G1 plan": eight, the first being the amendment that
removed Enterprise Managed Authorization and its admin UI from the slice.

## Versions touched

`VERSIONS.md` updated: yes, one row, `jose ~> 1.11` (1.11.12, MIT), added by the G1 commit and
verified by the gate's `versions.verify` and `versions.gen --check` steps. No other dependency
changed; `joken` was considered and not taken (NOTES, "Read before code").

## Git

```
$ git log --oneline main..HEAD
```

(The branch's commits, in order, are listed by that command; the closing commit's sha is appended
below when the slice closes, as the house rule requires.)
