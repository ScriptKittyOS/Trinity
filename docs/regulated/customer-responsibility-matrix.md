<!-- SPDX-FileCopyrightText: Sudo Apt Holdings LLC -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
# Customer responsibility matrix

Who owns each control. **Trinity software** means this repository implements it and a path is named.
**Customer** means your lab owns it and Trinity cannot do it for you. **Host or AWS** means the
operating system, the volume, or the cloud account underneath the process.

A row with no path says **NOT IN TREE**, which means the software does not implement it and you
should not plan as though it does.

## Identity provider

| Control | Trinity software | Customer | Host or AWS |
|---|---|---|---|
| Operating the IdP | No | **Yes.** Trinity is a resource server, never an authorization server for your users | No |
| Validating a bearer token on an inbound MCP request | **Yes.** `lib/trinity/mcp/auth.ex`, `lib/trinity/mcp/auth/token.ex` | Configure issuer, audience, resource | No |
| Choosing the profile | **Yes**, three exist: `:local`, `:production`, `:personal` at `config/runtime.exs:92-98` | **Yes.** `TRINITY_MCP_AUTH_PROFILE` is yours to set | No |
| Mapping a subject to an authorization decision | Scopes only, `lib/trinity/mcp/auth/scopes.ex` | **Yes.** Entitlement policy is yours | No |
| Token revocation and session lifetime | Introspection when enabled, `config/runtime.exs:105` | **Yes** | No |
| Authenticating a person on the web pages (IA-2) | **Yes**, since slice 136: an OpenID Connect login, `lib/trinity_web/auth/oidc.ex`; `:regulated` refuses to boot on a non-loopback bind without it, `lib/trinity/profile.ex` (`check_web_auth/3`) | **Yes.** Provide the issuer, register the client (`TRINITY_WEB_AUTH_*`), and grant the roles `view`, `approve`, `administer` in a claim the ID token carries | No |
| Enforcing a role on each page and action (AC-3, AC-6) | **Yes.** `lib/trinity_web/auth/require_role.ex`, `lib/trinity_web/auth/policy.ex` | **Yes.** Who holds which role is your entitlement policy | No |
| Logging the use of privileged functions (AC-6(9)) | **Yes.** Every approval and every privileged route or event is a signed receipt on the `access` chain with `sub`, `iss` and the role used, `lib/trinity_web/auth.ex` | **Yes.** Retain and review the chain | No |
| Refusing a request whose Host is not this deployment's | **Yes.** `lib/trinity_web/plugs/host_allow_list.ex`; set `PHX_HOST` | **Yes.** Set the host your users reach | No |
| Believing `x-forwarded-proto` | Only when `TRINITY_TRUSTED_PROXY=true`; `:regulated` refuses to boot otherwise | **Yes.** Your proxy must strip and set the header | **Yes** |

## Model

| Control | Trinity software | Customer | Host or AWS |
|---|---|---|---|
| Which model is called | Configuration only, `config/llm.exs:14` | **Yes.** You choose the endpoint and the provider | Network path |
| Enforcing that only an approved model may be called | **Yes, under `TRINITY_PROFILE=regulated`, at boot.** `lib/trinity/profile.ex` refuses to start when a configured model's endpoint is not on `TRINITY_REGULATED_LLM_ENDPOINTS`, or states none. Under the default profile nothing refuses an unapproved model | **Yes.** The allow-list is yours, and so is the egress policy that holds it at run time | Egress filtering |
| Whether the model provider trains on your data | No | **Yes.** A contract question with your provider | No |
| Keeping the model inside your boundary | No | **Yes**, if required. Self-hosting is a customer deployment choice | **Yes** |

## Regulated profile

`TRINITY_PROFILE=regulated` adds refusals at boot (`lib/trinity/profile.ex`). Each is a refusal, not
a capability: it stops a node starting in a configuration that cannot support a regulated
deployment, and it does not supply what the deployment has to.

| Control | Trinity software | Customer | Host or AWS |
|---|---|---|---|
| Which chat gateways may carry conversation text | **Yes, under the regulated profile, at boot.** Every configured adapter must be named in `TRINITY_REGULATED_GATEWAYS` (`lib/trinity/profile.ex`) | **Yes.** Naming the channels, and authorizing each one | No |
| Who decides whether an effect may happen | **Yes, as a refusal.** Under the regulated profile the node will not boot on the local authority (`lib/trinity/profile.ex`); no other adapter ships in this tree (`authorization-boundary.md`) | **Yes.** The external authority adapter, and its assessment | No |

## Keys

| Control | Trinity software | Customer | Host or AWS |
|---|---|---|---|
| Receipt signing key generation and use | **Yes.** `lib/trinity/receipts/key_custody.ex`, seam at `lib/trinity/keys.ex` | No | No |
| Where key material lives | Default is a 0600 file in the data directory, `lib/trinity/paths.ex` (`keys_dir/0`) | **Yes.** Custody is a deployment decision | Filesystem permissions |
| A KMS or HSM adapter | Seam exists (`lib/trinity/keys.ex`); **no KMS or HSM adapter is in the tree** | **Yes**, if required | **Yes** |
| Custody of the signing key | **No, and this is stated rather than implied.** `docs/10-assurance-case.md` C6 | **Yes** | **Yes** |
| Envelope encryption of blobs | **Yes.** AES-256-GCM, `docs/encryption-at-rest.md` | No | No |
| Encryption of everything SQLite indexes | **No, by design.** `docs/encryption-at-rest.md` | No | **Yes.** Volume or page level below SQLite |

## Egress

| Control | Trinity software | Customer | Host or AWS |
|---|---|---|---|
| Suppressing network access in the test suite | **Yes.** `test/network_guard_test.exs` | No | No |
| Refusing an effect that was not approved | **Yes.** `lib/trinity/effects.ex` re-derives the fingerprint before admitting | No | No |
| Restricting which hosts the process may reach | **NOT IN TREE** | **Yes** | **Yes.** Security group, egress proxy, firewall |
| Redacting credential-shaped strings from logs | **Yes**, as a last line. `lib/trinity/telemetry/redaction.ex` | No | No |
| Deciding what may leave the boundary at all | No | **Yes.** See `data-flow.md` | **Yes** |

## Transport and access

| Control | Trinity software | Customer | Host or AWS |
|---|---|---|---|
| TLS on connections Trinity makes | **Yes.** The runtime offers TLS 1.2 and 1.3 and nothing older, `test/supply_chain_test.exs`. That test checks the versions offered and nothing else: not peer verification, not the trust store | **Yes.** The trust store peers are verified against (in a DoD deployment, the DoD roots) | No |
| TLS on connections made to Trinity | **No.** The headless release serves plain HTTP on `TRINITY_BIND`: the loopback by default (`config/runtime.exs`), every interface in the image (`ci/ironbank/Dockerfile`). `config/prod.exs` sets `force_ssl` with `rewrite_on: [:x_forwarded_proto]`, so a request carrying `x-forwarded-proto: https` is treated as HTTPS, and any client can send that header unless a proxy strips it | **Yes.** Terminate TLS in front of it, and strip inbound `x-forwarded-*` headers at that proxy | **Yes** |
| Authenticating access to the web pages | **Partial.** MCP endpoints require a token from the external issuer (implemented). The web pages, among them the permissions page where approvals are answered, carry no authentication of their own (`lib/trinity_web/router.ex`, `docs/mcp-server.md`): a product gap, tracked as slice 136, which authenticates them against the same issuer. The image binds every interface | **Yes.** The OIDC issuer. Until slice 136 lands, an authenticating reverse proxy in front of the port, or a network only the owner reaches, as an interim compensating control with a POA&M entry, never the sole mitigation | **Yes** |

## Backups

| Control | Trinity software | Customer | Host or AWS |
|---|---|---|---|
| Producing a portable archive | **Yes.** `mix trinity.export`, `lib/mix/tasks/trinity.export.ex`, `docs/backup.md` | Run it | No |
| Restoring onto a fresh install | **Yes.** `lib/mix/tasks/trinity.import.ex` | Run it and test it | No |
| Scheduling, offsite copies, retention of backups | **NOT IN TREE** | **Yes** | **Yes** |
| Encrypting the archive at rest | Archive blobs are encrypted, `docs/encryption-at-rest.md` | Storage of the archive | **Yes** |

## Retention

| Control | Trinity software | Customer | Host or AWS |
|---|---|---|---|
| Ageing memory entries | **Yes.** Stale at 30 days, archived at 90, `lib/trinity/memory/curator.ex` | Tune the thresholds | No |
| Deleting anything on a schedule | **No. The curator deletes nothing**, it marks and archives in place (`lib/trinity/memory/curator.ex`) | **Yes**, if your policy requires deletion | No |
| Receipt chain retention | **Append only. Nothing in the tree deletes a receipt** | **Yes.** How long you keep the store | **Yes** |
| A records schedule, or legal hold | **NOT IN TREE** | **Yes** | No |

## Incidents

| Control | Trinity software | Customer | Host or AWS |
|---|---|---|---|
| Raising an alarm when the signer is unavailable | **Yes.** `lib/trinity/receipts/alarm.ex`, and every effect is denied until one is | Monitor it | No |
| Telemetry events an operator can subscribe to | **Yes.** `docs/telemetry.md`, `lib/trinity/telemetry.ex` | Collect and alert | **Yes** |
| Shipping logs or metrics anywhere | **NOT IN TREE.** Trinity emits; it does not forward | **Yes** | **Yes** |
| Reporting to a government customer within a clock | No | **Yes.** See `incident.md` | No |
| A published vulnerability disclosure process for this software | **Yes.** `SECURITY.md` | Report to it | No |

## Container image

The headless image, `docs/regulated/headless-image.md`.

| Control | Trinity software | Customer | Host or AWS |
|---|---|---|---|
| What the image contains | **Yes.** No package manager, compiler, shell history or key material beyond what is allowed by name; distribution off and no baked cookie. Checked on the built image by `mix trinity.image.inspect` | No | No |
| Running the image read-only, with no capabilities and no privilege escalation | The image runs as UID 10001 and writes only `/data` and `/tmp`, so it needs nothing more (`ci/ironbank/Dockerfile`) | **Yes.** Set them in the runtime that starts it | **Yes** |
| STIG rules for the image | **Yes.** `stig-applicability.md`, generated by `mix trinity.image.stig`, gives every rule of the profile a disposition | **Yes.** The rules it dispositions as the deployment's, and the host's own STIG | **Yes** |
| Scanning for known vulnerabilities | **Yes.** `mix deps.audit` in the gate; `mix trinity.image.findings` over a grype scan of the built image, which fails today on OTP findings that have no justification (`headless-image.md`) | **Yes.** Scanning what you run, on your schedule | **Yes** |
