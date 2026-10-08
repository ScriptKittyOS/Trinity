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

## Model

| Control | Trinity software | Customer | Host or AWS |
|---|---|---|---|
| Which model is called | Configuration only, `config/llm.exs:14` | **Yes.** You choose the endpoint and the provider | Network path |
| Enforcing that only an approved model may be called | **NOT IN TREE.** No allow-list mechanism exists in the tree; the model list is configuration and nothing refuses an unapproved one at runtime | **Yes.** Enforce by configuration control and egress policy | Egress filtering |
| Whether the model provider trains on your data | No | **Yes.** A contract question with your provider | No |
| Keeping the model inside your boundary | No | **Yes**, if required. Self-hosting is a customer deployment choice | **Yes** |

## Keys

| Control | Trinity software | Customer | Host or AWS |
|---|---|---|---|
| Receipt signing key generation and use | **Yes.** `lib/trinity/receipts/key_custody.ex`, seam at `lib/trinity/keys.ex` | No | No |
| Where key material lives | Default is a file in the secrets directory, outside the data directory and unreachable by any tool (`lib/trinity/paths.ex`, `secrets_dir/0` and `keys_dir/0`; `TRINITY_SECRETS_DIR`, slice 135) | **Yes.** Custody is a deployment decision | Filesystem permissions |
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
