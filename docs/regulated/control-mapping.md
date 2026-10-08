<!-- SPDX-FileCopyrightText: Sudo Apt Holdings LLC -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
# Control mapping: NIST SP 800-53 Rev. 5 and SP 800-218

## What this mapping is not

This mapping is **not an assessment**. Nobody has assessed Trinity against SP 800-53 or
SP 800-218, and no row records an assessor's finding.

It is **not an authorization to operate (ATO)**, and it is not evidence that one exists or would be
granted. An ATO is an authorizing official's decision about a deployment, and this repository is
software, not a deployment.

It is **not a System Security Plan**. A System Security Plan describes one system: its boundary,
its baseline, its impact level and how each selected control is implemented there. That is the
deployment's document about its own system, and this one can be read beside it, not instead of it.

It is **not a claim that any baseline is met**, at any impact level, under any overlay. A row says
that a mechanism in this tree **contributes to** a control. Whether the control is satisfied is an
assessor's finding about a deployment, against a baseline that deployment chose, at an impact level
this tree cannot know. Nothing here claims compliance, certification or accreditation of any kind.

What it is: for each mechanism this tree has, the SP 800-53 control or SP 800-218 practice it
contributes to, where it lives, what in the tree proves it, and whose the rest of the control is.

## How to read a row

| Column | What it holds |
|---|---|
| Control | An SP 800-53 Rev. 5 control or enhancement, or an SP 800-218 practice or task, exactly as NIST prints it |
| Mechanism | What this tree does, in one sentence a reader can check against the path |
| Path | Where the mechanism lives in this repository |
| Check | The test, Mix task, function or script that proves it, or `none` |
| Ownership | **Trinity's**, **shared** or **the deployment's** |
| The deployment's part | What the deployment supplies that this tree cannot, or `none` |
| Authority | The responsibility matrix row or standards register row the ownership rests on, or `none` |

**Ownership** has three values and no others.

- **Trinity's**: the mechanism is in this tree, a check in this tree names it, and the row needs
  nothing from the deployment beyond running the software.
- **shared**: the mechanism is in this tree, and the control also needs something only the
  deployment can supply, which the row names. A check is named where the tree has one.
- **the deployment's**: nothing in this tree implements it. The row names the path that says so.

A control appearing in several rows is several mechanisms contributing to it; no single row is the
whole of a control.

**The authority column.** `customer-responsibility-matrix.md` is the authority for ownership, and
this document does not hold a second opinion: where a row cites a matrix row, its ownership is the
one that matrix row implies, and every row that gives the deployment a part cites the matrix row,
or a register row recording a real-world dependency, that says so. Where a row cites
`docs/09-standards-register.md`, it repeats the register's status for that row and claims no more:
`:unknown` stays `:unknown`, and a row resting on a real-world dependency or on something the
register does not claim is never Trinity's.

## SP 800-53 Rev. 5: the mapping

| Control | Mechanism | Path | Check | Ownership | The deployment's part | Authority |
|---|---|---|---|---|---|---|
| `AC-2` | Trinity keeps no accounts for a deployment's users: under the production profile it is a resource server to the deployment's identity provider | `lib/trinity/mcp/auth.ex` | none | the deployment's | Account management, at the identity provider | CRM "Operating the IdP" |
| `AC-3` | An effect runs only through one boundary, which re-derives the approval's fingerprint from the arguments actually passed and refuses a mismatch; a census over the tree finds no other caller of a tool's `execute/2` | `lib/trinity/effects.ex`, `lib/trinity/permissions/fingerprint.ex` | `test/trinity/effects/membrane_test.exs` "AC4: arguments mutated after the decision are denied at execution with a receipt (M2 re-verify)"; `test/trinity/effects/census_test.exs` "the callers of execute/2 on a tool module are the two allowed and the one planted" | Trinity's | none | CRM "Refusing an effect that was not approved" |
| `AC-3` | A token's scope narrows which tools a caller may reach, and a scoped call still goes to the permission gate: identity answers who, never whether | `lib/trinity/mcp/auth/scopes.ex` | `test/trinity/mcp/auth/resource_server_test.exs` "AC4 and the receipts: read scope refused on an artifact tool, artifact scope reaches the gate, receipts name the principal, no token material" | shared | Which subject gets which scope, at the identity provider | CRM "Mapping a subject to an authorization decision"; Register "Identity is not authority": tree property |
| `AC-3` | The decision path never reads session or conversation state, so text in a conversation cannot argue with the gate; a census over the decision path holds it | `lib/trinity/permissions/`, `lib/trinity/authority/` | `test/trinity/permissions/session_state_census_test.exs` "only the planted reader reads session state from the decision path" | Trinity's | none | none |
| `AC-3` | Context only tightens a decision: no state, alone or combined, produces a result weaker than the decision without it | `lib/trinity/permissions/policy/` | `test/trinity/permissions/policy/state_test.exs` "no decision and no set of states produces a result weaker than the decision alone" | Trinity's | none | none |
| `AC-3` | Nothing the rule learner produces reaches a pending approval | `lib/trinity/permissions/learner.ex` | `test/trinity/permissions/learner_census_test.exs` "only the planted file lets the learner near a pending approval" | Trinity's | none | none |
| `AC-3` | An approval arriving on a chat channel may authorize at most a read, network or write effect; exec and destructive requests are refused by the channel's cap, whatever the profile | `lib/trinity/gateways/cap.ex` | `test/trinity/gateways/approvals_test.exs` "AC8: a destructive request is refused by the cap, receipted, and left for the desktop" | Trinity's | none | none |
| `AC-4` | Under `TRINITY_PROFILE=regulated` the node refuses to boot when a configured model's endpoint is not on `TRINITY_REGULATED_LLM_ENDPOINTS`, or states none. The check runs once, at boot, over the configured models | `lib/trinity/profile.ex`, `lib/trinity/application.ex` | `Trinity.Profile.check_llm_endpoints/3`; `test/trinity/regulated_boot_node_test.exs` "production mcp_auth and a non-Local authority, but no allow-list, does not start"; `test/trinity/profile_test.exs` "a model off the list is refused, naming the model and the endpoint" | shared | The allow-list itself, and the egress filtering that stops anything else leaving | CRM "Enforcing that only an approved model may be called" |
| `AC-4` | Under `TRINITY_PROFILE=regulated` every configured gateway adapter must be named in `TRINITY_REGULATED_GATEWAYS`, or the node refuses to boot | `lib/trinity/profile.ex` | `Trinity.Profile.check_gateways/3`; `test/trinity/regulated_boot_node_test.exs` "a configured adapter refuses without the allow-list and boots with it" | shared | Naming the channels, and authorizing each one | CRM "Which chat gateways may carry conversation text" |
| `AC-4` | Nothing in the tree decides what may leave the boundary; `data-flow.md` states what enters a prompt | `docs/regulated/data-flow.md` | none | the deployment's | The information flow policy, and the egress controls that enforce it | CRM "Deciding what may leave the boundary at all" |
| `AC-5` | Under `TRINITY_PROFILE=regulated` the node refuses to boot on the local authority, where one process would decide, act and record; an external adapter that changes the arguments it decided on is denied | `lib/trinity/profile.ex`, `lib/trinity/authority.ex`, `lib/trinity/effects.ex` | `Trinity.Profile.check_authority/2`; `test/trinity/regulated_boot_node_test.exs` "everything else correct, but TRINITY_AUTHORITY unset, does not start"; `test/trinity/effects/membrane_test.exs` "an adapter that rewrites the arguments in stage/2 is denied, with the fingerprint re-derived after stage" | shared | The external authority adapter. None ships in this tree, and it is assessed with the deployment | CRM "Who decides whether an effect may happen" |
| `AC-6` | The image runs as UID 10001, not root, which is checked on the built image; it writes only `/data` and `/tmp` | `ci/ironbank/Dockerfile`, `lib/mix/tasks/trinity.image.inspect.ex` | `mix trinity.image.inspect`; `test/mix/tasks/trinity_image_inspect_test.exs` "no user, root, UID 0 and a UID below 1000 are refused" | shared | A read-only root filesystem, dropped capabilities and no privilege escalation, set by the runtime that starts the container | CRM "Running the image read-only, with no capabilities and no privilege escalation" |
| `AC-16` | Content from outside the machine is marked untrusted, with its digest, and reaches the model only inside an untrusted block | `lib/trinity/tools/untrusted.ex` | `test/trinity/tools/provenance_test.exs` "the assistant's summary of a fetched page carries taint untrusted; the user's message stays trusted" | Trinity's | none | none |
| `AU-2` | The events recorded are a closed vocabulary of receipt kinds: decision, effect, query, boot and cap | `lib/trinity/receipts/receipt.ex`, `docs/receipt-scheme-mapping.md` | `test/trinity/receipts/scheme_mapping_test.exs` "AC3: the kinds the document names are exactly Receipt.kinds/0" | Trinity's | none | none |
| `AU-3` | Every receipt signs one field set: its kind, its subject, the decision, the fingerprint, the time, the key, and its place in the chain | `lib/trinity/receipts/chain_writer.ex`, `docs/receipt-scheme-mapping.md` | `test/trinity/receipts/scheme_mapping_test.exs` "AC3: every signed field has a row in the mapping table, and every row names a signed field" | Trinity's | none | none |
| `AU-4(1)` | Trinity emits telemetry and keeps its receipts locally; it forwards logs nowhere | `docs/telemetry.md` | none | the deployment's | Shipping logs and metrics to storage off the host | CRM "Shipping logs or metrics anywhere" |
| `AU-5` | When the signer is unavailable an alarm is raised and every effect is denied until a signer returns; under `TRINITY_PROFILE=regulated` the node does not boot at all | `lib/trinity/receipts/alarm.ex`, `lib/trinity/profile.ex` | `test/trinity/effects/membrane_test.exs` "AC5: the signing key removed mid-run: the next effect is denied, the alarm sounds, no unsigned receipt row exists; a read is refused too, because its decision cannot be receipted"; `Trinity.Profile.check_receipts/2`; `test/trinity/regulated_boot_node_test.exs` "case 4's configuration with case 1's broken key store does not start" | shared | Watching for the alarm, and alerting someone | CRM "Raising an alarm when the signer is unavailable" |
| `AU-8` | Each receipt carries a signed hybrid logical clock that never goes backwards within a chain; its reading is the host's own clock | `lib/trinity/receipts/clock.ex` | `test/trinity/receipts/clock_test.exs` "a wall clock that went BACKWARDS still produces a greater clock" | shared | A trusted time source, where the time itself must be authoritative | Register "Trusted time for receipts": real-world dependency |
| `AU-9(3)` | Receipts are hash-linked and signed before the row is written, and a verifier that does not need the application finds a gap, a wrong link, an altered byte or a forged signature | `lib/trinity/receipts/verifier.ex`, `bin/verify_receipt.exs` | `test/trinity/receipts/verifier_test.exs` "AC3: a chain with a gap, a wrong prev_hash, or a forged signature is 1"; `test/trinity/receipts/standalone_verifier_test.exs` "AC7: a stranger's run from an empty directory: verified is 0; the outcomes carry their codes" | Trinity's | none | CRM "Receipt signing key generation and use" |
| `AU-10` | Effect, decision, boot and cap receipts are signed one by one, and query receipts are covered by signed checkpoints. Standalone, one process decides, acts and signs, so a signature binds a record to a key, not to an independent party | `lib/trinity/receipts/chain_writer.ex`, `lib/trinity/receipts/key_custody.ex` | `test/trinity/receipts/chain_writer_test.exs` "rows chain: gapless seq, each prev_hash the previous receipt_hash, signed kinds verify, query rows unsigned"; `test/trinity/receipts/chain_writer_test.exs` "after N query receipts a checkpoint names the tail and its coverage; its signature verifies" | shared | An external authority, so that the party that decides is not the party that records, and custody of the signing key | CRM "Who decides whether an effect may happen"; Register "NIST SP 800-53 AU family: non-repudiation of every governed act (AU-10)": :unknown |
| `AU-11` | The chain writer is the only code that creates or removes a receipt row | `lib/trinity/receipts/chain_writer.ex` | `test/trinity/receipts/chain_writer_test.exs` "the census: ChainWriter is the only inserter into receipts; the planted bypass is named" | shared | How long the receipts store is kept | CRM "Receipt chain retention" |
| `AU-11` | There is no records schedule and no legal hold in the tree | `docs/regulated/customer-responsibility-matrix.md` | none | the deployment's | A records schedule, and legal hold | CRM "A records schedule, or legal hold" |
| `AU-12` | Every gate decision and every effect yields a receipt: a read gives a decision and a query receipt, an effect a decision, an admit and a done | `lib/trinity/effects.ex`, `lib/trinity/receipts/chain_writer.ex` | `test/trinity/effects/membrane_test.exs` "AC3: every gate decision and every effect yields a receipt: a read gives decision and query; an effect gives decision, admit and done" | Trinity's | none | none |
| `CM-5` | A skill change applies through one path only, behind an approval: a census finds no second caller of the swap, and the swap refuses without an approval | `lib/trinity/skills/promotion.ex`, `lib/trinity/skills/manager.ex` | `test/trinity/skills/census_test.exs` "the callers of Promotion.swap/3 are the manager and the plant"; `test/trinity/skills/staging_test.exs` "AC8: swap/3 refuses without an approval, with a pending, denied, other-tool or other-change approval, and when the staged files changed" | Trinity's | none | none |
| `CM-6` | Three MCP authorization profiles exist, and under `TRINITY_PROFILE=regulated` only the production profile boots; an unrecognised `TRINITY_PROFILE` raises rather than falling back to the default | `config/runtime.exs`, `lib/trinity/profile.ex` | `Trinity.Profile.check_mcp_auth/2`; `test/trinity/regulated_boot_node_test.exs` "personal and local are both refused, where case 4's configuration is otherwise met"; `test/trinity/profile_test.exs` "an unrecognised value raises rather than falling back to default" | shared | Setting both profiles, and the issuer, audience and resource | CRM "Choosing the profile" |
| `CM-6` | The image's STIG applicability statement is generated from OpenSCAP's evaluation of the built image, and every rule the DISA STIG profile selects has a disposition | `docs/regulated/stig-applicability.md`, `ci/headless/stig_dispositions.yaml` | `mix trinity.image.stig`; `test/mix/tasks/trinity_image_stig_test.exs` "a rule with no disposition fails the check (planted red), and passes once it has one" | shared | The rules the statement dispositions as the deployment's, and the STIG of the host that runs the image | CRM "STIG rules for the image" |
| `CM-7` | The effects the agent can cause are a closed catalogue: only a module attribute admits a catalogue tool, and the published catalogue must match the tree or the release check fails | `lib/trinity/tools/catalog.ex`, `docs/effects-catalog.md` | `test/trinity/tools/catalog_census_test.exs` "every :catalog tool in the tree is in the attribute, and the attribute names only :catalog tools"; `mix trinity.effects.catalog --check` | Trinity's | none | none |
| `CM-7` | The image carries no package manager, compiler, shell history, documentation, SUID file or key material beyond what is allowed by name; distribution is off and no cookie is baked in. Checked on the built image | `lib/mix/tasks/trinity.image.inspect.ex`, `ci/headless/image_allowances.yaml` | `mix trinity.image.inspect`; `test/mix/tasks/trinity_image_inspect_test.exs` "distribution not turned off is refused" | Trinity's | none | CRM "What the image contains" |
| `CP-9` | `mix trinity.export` writes a portable archive of the whole state, with a manifest of digests | `lib/mix/tasks/trinity.export.ex`, `docs/backup.md` | `test/trinity/archive/round_trip_test.exs` "AC1 and AC2: export, import into an empty directory, the rows and the chain come back, the tree's digests match the manifest" | shared | Running it | CRM "Producing a portable archive" |
| `CP-9` | Nothing schedules a backup, copies one offsite or keeps one for a period | `docs/backup.md` | none | the deployment's | Scheduling, offsite copies and retention | CRM "Scheduling, offsite copies, retention of backups" |
| `CP-9(8)` | An export's blobs are sealed with AES-256-GCM, a fresh data key each, when exports are sealed | `lib/trinity/vault.ex`, `docs/encryption-at-rest.md` | `test/trinity/vault_test.exs` "an export manifest is ciphertext on disk when exports are sealed" | shared | Where the archive is stored, and its protection there | CRM "Encrypting the archive at rest" |
| `CP-10` | `mix trinity.import` restores onto a fresh install, and refuses a tampered archive before anything is written | `lib/mix/tasks/trinity.import.ex` | `test/trinity/archive/round_trip_test.exs` "AC4: a tampered archive fails digest verification before anything is written" | shared | Running a restore, and testing that it works | CRM "Restoring onto a fresh install" |
| `IA-2` | Trinity is never the identity provider for a deployment's users; it validates the tokens the deployment's provider issues | `lib/trinity/mcp/auth.ex` | none | the deployment's | Operating the identity provider, and authenticating users there | CRM "Operating the IdP" |
| `IA-2` | An inbound MCP request is refused unless it carries a token the configured issuer signed for this resource: a wrong audience, an expired token and the static bearer are refused, each with a receipt | `lib/trinity/mcp/auth.ex`, `lib/trinity/mcp/auth/token.ex` | `test/trinity/mcp/auth/resource_server_test.exs` "AC1: 401 with resource_metadata; the PRM names the AS; wrong audience, expired and the static bearer are 401; each refusal receipted"; `test/trinity/mcp/auth/token_test.exs` "each claim check is its own refusal" | shared | The issuer, audience and resource Trinity is configured to accept | CRM "Validating a bearer token on an inbound MCP request" |
| `IA-2` | Under the production profile Trinity mints no token and holds no issuer key; the personal issuer refuses to start under an external authority, and under `TRINITY_PROFILE=regulated` | `lib/trinity/mcp/auth/embedded.ex`, `lib/trinity/profile.ex` | `Trinity.Profile.check_embedded_as/2`; `test/trinity/mcp/auth/embedded_test.exs` "the production profile holds no key material of its own: no keys, no JWKS, no AS metadata"; `test/trinity/mcp/auth/embedded_test.exs` "the personal profile refuses to start under an external authority adapter" | shared | The identity provider that does issue the tokens | CRM "Choosing the profile"; Register "Trinity issues no production authority": tree property |
| `IA-2` | The web pages, among them the permissions page where approvals are answered, carry no authentication of their own; the bearer is required on `/mcp` only, and the image binds every interface | `lib/trinity_web/router.ex`, `docs/mcp-server.md`, `ci/ironbank/Dockerfile` | none | the deployment's | An authenticating reverse proxy in front of the port, or a network that only the owner reaches | CRM "Authenticating access to the web pages" |
| `IA-5(7)` | The gate fails on a credential-shaped string anywhere in the tracked tree | `lib/mix/tasks/trinity.secrets.scan.ex` | `mix trinity.secrets.scan`; `test/secrets_scan_test.exs` "RED: a planted fake key of each shape is found" | Trinity's | none | none |
| `IA-11` | An expired token is refused, and with introspection enabled the issuer is asked about each token; a client then goes back to the identity provider | `lib/trinity/mcp/auth/token.ex`, `config/runtime.exs` | `test/trinity/mcp/auth/token_test.exs` "introspection: an opaque token is asked about at the issuer (RFC 7662), the answer's claims checked as a JWT's are" | shared | Token lifetime, revocation and re-authentication policy, at the identity provider | CRM "Token revocation and session lifetime" |
| `IR-6` | Trinity reports nothing to anyone; `incident.md` sets out the clocks that may apply and what the record gives an investigator | `docs/regulated/incident.md` | none | the deployment's | Reporting, within whatever clock applies | CRM "Reporting to a government customer within a clock" |
| `RA-5` | The gate audits every locked dependency on every push; the built image is scanned with grype, and a High or Critical finding without a justification fails. **The image's scan fails today**: OTP findings fixed in a later OTP release have no justification until the toolchain moves | `lib/mix/tasks/trinity.image.findings.ex`, `ci/headless/justifications.yaml` | `mix deps.audit`; `mix trinity.image.findings`; `test/mix/tasks/trinity_image_findings_test.exs` "AC3: a planted High finding with no row fails, and passes once justified" | shared | Scanning what is actually deployed, on the deployment's schedule | CRM "Scanning for known vulnerabilities" |
| `RA-5(11)` | A published process for reporting a vulnerability in this software. It is a document, and no check in the tree holds it | `SECURITY.md` | none | shared | Reporting to it | CRM "A published vulnerability disclosure process for this software" |
| `SA-4` | Nothing in the tree is a contract with a model provider | `config/llm.exs` | none | the deployment's | Whether the provider may train on or keep the data, settled in the contract | CRM "Whether the model provider trains on your data" |
| `SA-9` | The model in force is configuration: Trinity calls the endpoint it is pointed at, and under the regulated profile only one on the allow-list (the `AC-4` row above) | `config/llm.exs` | none | shared | Choosing the provider and the endpoint | CRM "Which model is called" |
| `SA-11` | The test suite cannot reach the network: outside the opt-in live run, a connect to a listener that is definitely there is refused | `test/support/network_guard.ex` | `test/network_guard_test.exs` "RED: the default test run refuses a connect to a listener that is definitely there" | Trinity's | none | CRM "Suppressing network access in the test suite" |
| `SC-7` | Nothing in the tree restricts which hosts the process may reach | `docs/regulated/authorization-boundary.md` | none | the deployment's | Security groups, an egress proxy or a firewall | CRM "Restricting which hosts the process may reach" |
| `SC-7` | The model endpoint is outside the boundary unless the deployment puts it inside | `docs/regulated/authorization-boundary.md` | none | the deployment's | Self-hosting the model, where that is required | CRM "Keeping the model inside your boundary" |
| `SC-8` | Connections Trinity makes offer TLS 1.2 and 1.3 and nothing older | `README.md` | `test/supply_chain_test.exs` "the runtime's default TLS versions are 1.2 and 1.3, and nothing older" | Trinity's | none | CRM "TLS on connections Trinity makes"; Register "TLS floor 1.2 in FIPS mode": :unknown |
| `SC-8` | The headless release serves plain HTTP on `TRINITY_BIND`: the loopback by default, every interface in the image | `config/runtime.exs`, `ci/ironbank/Dockerfile` | none | the deployment's | TLS in front of the process | CRM "TLS on connections made to Trinity" |
| `SC-12` | The receipt signing key is generated once, mode 0600, registered, and read at every signature by the custody module and by nothing else | `lib/trinity/receipts/key_custody.ex`, `lib/trinity/keys.ex` | `test/trinity/receipts/signer_test.exs` "boot generates the key once (0600), appends its registry row, and a second boot reuses it"; `test/trinity/keys/custody_census_test.exs` "no module outside the custody seam reads key material from disk" | Trinity's | none | CRM "Receipt signing key generation and use" |
| `SC-12` | Key material lives in the data directory's keys directory by default, sealed when a key source is configured | `lib/trinity/paths.ex`, `lib/trinity/keys/local.ex` | `test/trinity/keys/signer_seam_test.exs` "the signing key is ciphertext on disk and the registry says so" | shared | Where the keys live, and who can read them | CRM "Where key material lives"; Register "Exclusive deployment control of encryption keys": :unknown |
| `SC-12` | Keys pass through one behaviour, so a KMS or HSM adapter is a module and a configuration line; none ships in this tree | `lib/trinity/keys.ex` | `test/trinity/keys/signer_seam_test.exs` "a sealed key still signs, which is the point of sealing it" | shared | A KMS or HSM adapter, where one is required | CRM "A KMS or HSM adapter" |
| `SC-12` | Custody of the signing key is not addressed: a key in a file shows the records were not altered by anything without read access to it, and nothing about who held it | `docs/10-assurance-case.md` | none | the deployment's | Custody of the signing key | CRM "Custody of the signing key" |
| `SC-13` | Signing picks its algorithm by the runtime's mode: Ed25519 by default, ECDSA P-384 with SHA-384 in FIPS mode, where Ed25519 reports itself unavailable. The gate and the suite run in FIPS mode on every push | `lib/trinity/receipts/signer.ex`, `docs/fips-leg.md`, `docs/regulated/crypto-inventory.md` | `test/trinity/receipts/signer_test.exs` "outside FIPS mode the default is Ed25519; in FIPS mode (the fips leg) it is P-384"; `test/fips/receipts_test.exs` "the mode is on, Ed25519 reports unavailable, P-384 is selected and the boot receipt names it" | shared | A validated cryptographic module on the host, established from its certificate and the running binary | Register "FIPS 140-3 validated cryptography in FIPS mode": :unknown; Register "FIPS 140-2 certificates on the Historical list from 2026-09-22": real-world dependency |
| `SC-23` | The state an MCP client carries between rounds is sealed with AES-256-GCM: a replay, one tampered byte, an expired envelope and a state bound to other arguments are refused | `lib/trinity/mcp/server/envelope.ex` | `test/trinity/mcp/server_mrtr_test.exs` "a replay inside the partition, one tampered byte, an expired envelope and a state bound to other arguments are refused; a missing state is a first call" | Trinity's | none | Register "Envelope MAC in FIPS mode is an approved algorithm": :unknown |
| `SC-24` | Failure denies: an unavailable signer denies every effect, a tool absent from the catalogue or a decision other than allow is denied before anything runs, and an authority adapter that cannot be loaded refuses the boot | `lib/trinity/effects.ex`, `lib/trinity/authority/selection.ex` | `test/trinity/effects/membrane_test.exs` "a :catalog tool absent from the catalog, or a decision other than allow, is denied before anything runs"; `test/trinity/authority/selection_test.exs` "an absent module is refused as not loaded, by name" | Trinity's | none | Register "Nothing fails open": :unknown |
| `SC-28` | Anything SQLite indexes is left unencrypted by design, for the volume beneath it | `docs/encryption-at-rest.md` | none | the deployment's | Volume or page-level encryption below SQLite | CRM "Encryption of everything SQLite indexes" |
| `SC-28(1)` | Blobs nothing indexes (skill files, staged changes, archives) are sealed with AES-256-GCM under a fresh data key each | `lib/trinity/vault.ex` | `test/trinity/vault_test.exs` "a sealed blob is ciphertext: the plaintext does not appear in it"; `test/trinity/vault_test.exs` "every blob gets its own data key, so one compromise does not open the next" | Trinity's | none | CRM "Envelope encryption of blobs"; Register "Encryption of data at rest with deployment-controlled keys": :unknown |
| `SI-4` | Documented telemetry events an operator can subscribe to; Trinity emits them and alerts no one | `lib/trinity/telemetry.ex`, `docs/telemetry.md` | `test/trinity/telemetry/telemetry_test.exs` "every event the catalogue lists appears in docs/telemetry.md" | shared | Collecting the events, and alerting on them | CRM "Telemetry events an operator can subscribe to" |
| `SI-7` | A changed MCP tool definition is held, not called, until the owner accepts it; the first sighting is the baseline | `lib/trinity/tools/surface.ex`, `lib/trinity/tools/definition_digest.ex` | `test/trinity/mcp/surface_drift_test.exs` "a description change alone holds the tool, with the schema untouched" | Trinity's | none | none |
| `SI-7` | Every input to the image build that is not a UBI package is declared with its digest and copied only if declared, and the published bases are pinned by digest | `ci/ironbank/hardening_manifest.yaml`, `lib/mix/tasks/trinity.ironbank.lint.ex` | `mix trinity.ironbank.lint`; `test/ironbank_submission_test.exs` "copying a file no resource declares is refused"; `test/ironbank_submission_test.exs` "a published base pinned by tag and not by digest is refused (planted red)" | Trinity's | none | none |
| `SI-10` | Input from an MCP server is decoded and validated by one decoder and one validator, the client library's, and a census finds no second | `lib/trinity/mcp/client.ex`, `lib/trinity/mcp/client/` | `test/trinity/mcp/thin_driver_census_test.exs` "decoding and validation are the core's public functions; no decoder or validator of Trinity's own" | Trinity's | none | none |
| `SI-11` | Credential-shaped strings are masked on their way into a log, and boot refuses to continue without the filter. A last line, not the control | `lib/trinity/telemetry/redaction.ex`, `lib/trinity/application.ex` | `test/trinity/telemetry/redaction_chardata_test.exs` "verify_log_redaction!/0 raises when the filter is absent, so boot cannot continue unfiltered"; `test/trinity/telemetry/redaction_test.exs` "a provider key, by its shape rather than by its name" | Trinity's | none | CRM "Redacting credential-shaped strings from logs" |
| `SI-12` | Memory entries go stale at 30 days and are archived at 90, each step receipted, and nothing is deleted | `lib/trinity/memory/curator.ex` | `test/trinity/scheduler/curator_test.exs` "stale at 30 days with a query receipt, archived at 90 with an effect receipt, fresh untouched, nothing deleted; the archived entry leaves recall" | shared | The thresholds, against the deployment's retention policy | CRM "Ageing memory entries" |
| `SI-12(3)` | Nothing in the tree deletes on a schedule | `lib/trinity/memory/curator.ex` | none | the deployment's | Disposal, where policy requires deletion | CRM "Deleting anything on a schedule" |
| `SR-4` | The gate generates a CycloneDX bill of materials covering every locked dependency | `lib/mix/tasks/trinity.sbom.ex` | `mix trinity.sbom`; `test/supply_chain_test.exs` "covers the dependencies the lock file holds" | Trinity's | none | Register "Software bill of materials on every release": :unknown |

## SP 800-218 (SSDF 1.1): the mapping

For SP 800-218 the producer is this project, so **Trinity's** means the project's own practice,
held by a check in this tree.

| Control | Mechanism | Path | Check | Ownership | The deployment's part | Authority |
|---|---|---|---|---|---|---|
| `PO.3.1` | The toolchain is one command: `mix gate` runs every enforcer as its own step | `mix.exs` | `test/gate_alias_test.exs` "the gate runs every enforcer as its own step" | Trinity's | none | none |
| `PO.3.2` | Every CI workflow pins each third-party action to a full commit hash and grants no write permission at the top level | `.github/workflows/` | `test/workflows_test.exs` "every third-party action is pinned to a full commit hash, not a movable tag"; `test/workflows_test.exs` "every workflow declares a top-level permissions block, and it grants no write" | Trinity's | none | none |
| `PS.3.2` | Every gate run generates the CycloneDX bill of materials, and the third-party licence list is derived from it | `lib/mix/tasks/trinity.sbom.ex`, `THIRD_PARTY_LICENSES.md` | `mix trinity.sbom`; `mix trinity.third_party_licenses --check`; `test/supply_chain_test.exs` "covers the dependencies the lock file holds" | Trinity's | none | Register "Software bill of materials on every release": :unknown |
| `PW.4.1` | Dependencies are taken at pinned versions: every direct dependency has a row in `VERSIONS.md`, and the lock must agree with every pin | `VERSIONS.md`, `mix.lock` | `mix versions.verify`; `mix versions.gen --check`; `test/mix/tasks/versions_verify_test.exs` "the real project has no undocumented direct dependency" | Trinity's | none | none |
| `PW.4.4` | Every locked dependency is checked against published advisories and retired releases on every push | `mix.lock` | `mix deps.audit`; `mix hex.audit` | Trinity's | none | none |
| `PW.5.1` | No credential in the tree, and no evaluation of model output as code: both are gate checks over the tracked tree | `lib/mix/tasks/trinity.secrets.scan.ex`, `test/no_eval_on_model_output_test.exs` | `mix trinity.secrets.scan`; `test/no_eval_on_model_output_test.exs` "the family is exactly the six the moduledoc names" | Trinity's | none | none |
| `PW.6.2` | The compiler runs with warnings as errors, which makes the boundary rules and the type checker blocking; the release compiles under `MIX_ENV=prod`, assembles, and evaluates its runtime configuration | `mix.exs`, `scripts/prod_check.sh` | `mix compile --warnings-as-errors --force`; `scripts/prod_check.sh`; `test/gate_alias_test.exs` "the gate has a compile step and it carries --warnings-as-errors" | Trinity's | none | none |
| `PW.7.2` | Static analysis on every push: Credo in strict mode, and Sobelow, which blocks, with every skipped finding carrying a reason | `.credo.exs`, `.sobelow-skips`, `.sobelow-skips.reasons` | `mix credo --strict`; `mix sobelow --exit --skip`; `test/sobelow_skips_test.exs` "every skipped sobelow finding carries a reason"; `test/gate_alias_test.exs` "sobelow blocks rather than advises" | Trinity's | none | none |
| `PW.8.2` | The whole suite runs in the gate, and coverage may not fall more than three points below the previous slice's | `coverage.tsv`, `lib/mix/tasks/trinity.coverage.ex` | `mix test`; `mix trinity.coverage`; `test/coverage_gate_test.exs` "a drop of more than three points fails" | Trinity's | none | none |
| `PW.9.1` | Each tool's default comes from its risk tier: a read is allowed, a write asks the owner, and a tool the tier map does not name asks | `lib/trinity/permissions/policy.ex` | `test/trinity/permissions/gate_test.exs` "the default by tier: read allows, write asks, an unmapped name asks" | Trinity's | none | none |
| `PW.9.2` | The regulated profile is a group of settings implemented in code and documented in this pack; a node that does not meet it does not start, and a mistyped profile name raises | `lib/trinity/profile.ex`, `docs/regulated/authorization-boundary.md` | `test/trinity/regulated_boot_node_test.exs` "production mcp_auth, a non-Local authority, an allowed endpoint and a signer"; `test/trinity/profile_test.exs` "an unrecognised value raises rather than falling back to default" | Trinity's | none | none |
| `RV.1.1` | Advisories against locked dependencies are gathered on every push by the gate, and Dependabot watches the dependencies | `.github/dependabot.yml` | `mix deps.audit`; `test/workflows_test.exs` "every workflow and the Dependabot configuration parse as YAML" | Trinity's | none | none |
| `RV.2.2` | A High or Critical finding in the image is fixed, or carries a justification keyed to one version of one package; a justification for a finding no longer reported fails as stale | `ci/headless/justifications.yaml`, `lib/mix/tasks/trinity.image.findings.ex` | `mix trinity.image.findings`; `test/mix/tasks/trinity_image_findings_test.exs` "AC4: a planted row whose finding the scan no longer reports fails as stale" | Trinity's | none | none |

## Gate steps that serve no practice

Every step of `mix gate` is either cited by a row above or listed here. These four are real
checks; they hold project rules that are not security practices, and mapping them to one would
overstate them.

| Step | Why it maps to no practice |
|---|---|
| `mix format --check-formatted` | A formatting rule. It keeps review readable; it finds no weakness |
| `mix trinity.version_form` | A writing rule: the protocol is versioned by date |
| `mix trinity.names` | A naming rule for this repository's text |
| `mix trinity.reuse` | Per-file copyright and licence headers: a licensing obligation, not a security check |

## Families with no row

Every SP 800-53 family either has a row above or is listed here with the reason.

| Family | Why there is no row |
|---|---|
| `AT` | Awareness and training is of people, and the people are the deployment's |
| `CA` | Assessment, authorization and monitoring are acts performed on a deployment. This document is an input to an assessment, not an instance of one |
| `MA` | Maintenance of the system is performed by whoever operates it |
| `MP` | Media protection concerns the physical and digital media the deployment handles |
| `PE` | Physical and environmental protection belongs to the facility |
| `PL` | Planning, including the System Security Plan, is the deployment's |
| `PM` | Program management is organizational |
| `PS` | Personnel security concerns the deployment's staff |
| `PT` | Nothing in the tree identifies personally identifiable information or tracks the purpose it is processed for. `data-flow.md` states what enters a prompt; the processing policy is the deployment's |

## Practices with no row

Every SP 800-218 practice either has a row above, for itself or one of its tasks, or is listed here
with the reason. A practice the project follows but no check in the tree holds is listed here,
because a row needs a check.

| Practice | Why there is no row |
|---|---|
| `PO.1` | Security requirements for development are written in the slice records, which are not in this tree |
| `PO.2` | Roles and training are organizational; `GOVERNANCE.md` names roles, and no check holds it |
| `PO.4` | The gate's steps are the criteria for a security check (the `PO.3.1` row), and nothing in the tree tracks them through the lifecycle beyond the coverage floor |
| `PO.5` | The development environment and the CI runners are configured outside this tree |
| `PS.1` | Who may change the code is the forge's configuration, not this tree's. `test/dco_test.exs` establishes who signed off each change, which is provenance rather than protection |
| `PS.2` | The standards register records signed releases as not claimed, and no release has been published |
| `PW.1` | The threat model is `docs/10-assurance-case.md`; no check in the tree holds it |
| `PW.2` | A design review by someone not involved in the design is not yet possible: the register records `two_person_review` as outstanding |
| `RV.3` | Root-cause analysis is recorded in the slice records, which are not in this tree |

## The catalogues the identifiers are checked against

Both from NIST's OSCAL content, `usnistgov/oscal-content`, pinned to one commit, under the
repository's CC0 dedication.

| Catalogue | File | Commit | SHA-256 of the file |
|---|---|---|---|
| SP 800-53 Rev. 5 (version 5.2.0) | `nist.gov/SP800-53/rev5/json/NIST_SP-800-53_rev5_catalog.json` | `78650f02ad9321bb7b817846f8fbd4f2bcd620de` | `01f37cf90ea99d92242c936cbfbdebcc338eef1f71454e2acac36cc56e9bc062` |
| SP 800-218, SSDF 1.1 | `nist.gov/SP800-218/ver1/json/NIST_SP800-218_ver1_catalog.json` | `78650f02ad9321bb7b817846f8fbd4f2bcd620de` | `b01634a5fdb382e7a12660c379a4d0bc3a2b8e29abccf2861834880005137117` |

The catalogues themselves are not in the tree. `scripts/nist_catalogues.exs` derives the identifier
lists in `test/support/fixtures/nist/` from them, refuses a file whose SHA-256 is not the one above,
and with `--check` confirms the committed lists are what the pinned files derive.

## How this document is checked

`test/control_mapping_test.exs`, in the gate. It fails when:

- a row's identifier is not in NIST's catalogue, or is withdrawn there;
- a path a row names, or a test file or script in its Check cell, is not in the tree;
- a `Trinity's` row names no check, or any row names a test, Mix task or function that does not
  exist. A test is found by its literal name in its file. **Stated limit:** a test whose body is
  emptied while its name is kept still passes here; what a test asserts is that test's own red;
- a row's ownership differs from the responsibility matrix row it cites, or a row giving the
  deployment a part cites nothing that says so;
- a row repeats a register status the register does not record, or claims Trinity's where the
  register records a real-world dependency or something not claimed;
- this document stops opening with what it is not, or uses, outside that opening, the words of a claim a
  mapping cannot make;
- a member of a population derived from the tree is cited by no row: a row of the responsibility
  matrix, a register row naming an SP 800-53 control, a refusal of the regulated profile
  (`Trinity.Profile`'s `check_*` functions), a census test, or a step of `mix gate`; or a family or
  practice in NIST's catalogue has neither a row nor a reason here.
