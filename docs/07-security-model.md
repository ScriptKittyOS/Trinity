# 07: Security model

The structured argument that these mechanisms deliver what they claim, with the evidence for
each claim and the assumptions it rests on, is `docs/10-assurance-case.md`.

## Trust boundaries

```
[User] ── trusted
[Persona/SOUL, user-authored skills, config] ── trusted, but validated
[LLM output] ── UNTRUSTED (may be manipulated by anything it read)
[Tool results, web pages, files, MCP servers, gateway messages, hub skills] ── UNTRUSTED
```
Everything untrusted is wrapped when re-entering the prompt (`<untrusted source="web">…</untrusted>`) and the
system prompt states that instructions inside untrusted blocks are data, not commands.

## The mechanisms this model rests on

- **Content provenance.** Every content part carries `origin`, `source_ref`, `digest` and `taint`. Summaries and
  compactions inherit the maximum taint of their inputs; a blocked part becomes a safe placeholder and a receipt.
- **Approvals bind arguments, not names.** An approval binds a canonical hash of the exact call and is re-derived
  at execution. Divergence denies.
- **Loop caps are code-owned.** Iteration, token and wall-clock caps are module attributes; the loop takes no cap
  argument. Reaching one is a recorded outcome, not a crash. Every read emits a query receipt.
- **One side-effect boundary.** A compile-time effect catalog; runtime-registered tools can never enter it;
  malformed arguments are denied, never repaired.
- **Scope on skills and memory.** Every row carries a scope; retrieval enforces it; promotion across scopes is an
  audited, approved change carrying a content digest.
- **Overrides are adjudicated.** A click-through past a warning is input to a deterministic server-side decision,
  never authority in itself.
- **Reset is total.** Session state holds no authority. A reseeded session is born from the immutable core policy
  hash and inherits nothing.
- **Receipts chain.** Per-scope hash chains, signed, verifiable offline by a stranger with the public registry.
  The signature enters through one seam (`Trinity.Receipts.Signer`); the algorithm is selected once at boot,
  Ed25519 by default and ECDSA P-384 when FIPS mode is enabled, and is bound by the key registry row rather than
  by anything in the receipt. Effect, decision, boot and cap receipts are signed per receipt; query receipts are
  checkpointed. No approved algorithm available means the effect is denied, never signed with a refused one and
  never written unsigned.

## Project context (Slice 033, as built)

`AGENTS.md` is repository content, not owner-authored configuration. Every file on the path from the session's
project root to its working directory enters the prompt's context tier inside an
`<untrusted source="agents_md" path=... digest=...>` block, capped at 16,384 bytes in total with every cut
stated, and the untrusted rule already in the prompt covers it. The gate never reads the prompt: a file that
says approvals are off changes nothing about what asks (AC3, a test), and the same holds for anything else the
model reads.

## Permission gate (Slice 021)

Every `Trinity.Tools.Tool` declares `effect/0` (`:none | :artifact | :catalog`) and the gate derives risk from the tool **name only** via `Trinity.Permissions.tier/1` (`:read | :write | :exec | :network | :destructive`; unmapped → ask).

Name-only is deliberate: it makes the tier a code-owned function of a value no caller can influence. That holds only while the namespace is closed. Tools registered at runtime carry names chosen elsewhere, by an MCP server or a skill author, so **every dynamic tool is namespaced before the tier lookup**: `mcp:<server>:<tool>`, `skill:<name>`. Core tool names are reserved and cannot be claimed. Without this a hostile server naming its tool `fs_read` inherits the `:read` tier and its allow-by-default policy, and the unmapped-goes-to-ask fallback does not catch it, because the name is mapped.
`Trinity.Permissions.decide(session, tool, args, opts)` consults, in order: session grants → the newest unspent
decision for this fingerprint (an "allow once" or a denial, each spent by the execution that reads it) →
persona policy → global `tool_permissions` → default policy (`:read` allow, `:network` allow, `:write` ask,
`:exec` ask, `:destructive` ask; an unmapped name asks).
An `:ask` suspends the Session in `approval_wait`, broadcasts to `approvals:<id>` (and `approvals:all`), and
resumes on decision. Decisions are recorded (`approvals` table) and receipted (024). Approvals bind the canonical
fingerprint of `(tool, args, scope, cwd, canonicalization_version)` and are re-derived at execution; "allow for
this session" binds that fingerprint with an expiry; "always allow" is a rule, recorded as such.

As built at slice 021: the tier table is written once, by the registry, from the `risk/0` of the modules
`config :trinity, :tools` names, so a tier comes from code and config and never from a runtime registration; the
runner asks the policy at execution and the Session never pre-checks, so the decision that runs a call is the one
made against the arguments actually passed; a request left undecided expires into a denial decided by
`"expiry"`; the card's buttons and the `/permissions` page call `decide_request/3` and nothing else.

## Shell (Slice 022)

- MuonTrap-supervised; command killed when the Task dies; timeout default 120 s; output capped (1 MB) with truncation marker.
- Dangerous-pattern allowlist/denylist (rm -rf /, curl|sh, sudo, chmod 777 …) forces `:destructive`.
- Working directory jailed to configured roots unless approved.

As built at slice 022, the guarantee per platform. **POSIX (Linux, macOS):** `/bin/sh -c` under a MuonTrap port,
SIGTERM at the timeout and SIGKILL 500 ms later, the child gone when the port is; the environment scrubbed to
`PATH`, `HOME`, `LANG`, `LC_ALL`, `TERM`, `TMPDIR` and `USER` (every other name unset, since a port's `env` adds
to the inherited environment); the timeout at most 600 s; the output capped at 1 MB with the head and the tail
kept; `Trinity.Tools.Shell.Dangerous` is the pattern list, a tripwire over text and stated as such. **Windows:**
no runtime in the tree keeps the kill guarantee, so the shell tool answers `available?/0` false and the registry
does not register it; a `System.cmd` fallback that could orphan a process would be a different tool under the
same name and is not offered. The approval card states which applies on the machine it runs on, and that the
BEAM is not an OS sandbox. The shell is a `:catalog` effect (`Trinity.Effects.Catalog`) at risk `:exec`.

## Filesystem (Slice 022)

- Path allowlist (project roots + data dir). Writes outside → ask.
- **Write-validation hook**: reject writes whose content contains truncation markers (`/* ... */`, `// ...`,
  `# ... rest unchanged`) unless the file is new or the tool is called with `allow_placeholders: true` after approval.
- Atomic writes (temp + rename) and a per-file backup ring (last 5) under the data dir.

As built at slice 022: the roots are `config :trinity, :fs, roots:` (`TRINITY_FS_ROOTS` at runtime), the data
directory always, and the session's working directory; a path is judged after normalisation and symlink
resolution through its nearest existing ancestor; outside the roots every filesystem tool escalates the call to
`:ask` (the tier can only rise: `Tool.escalate/2`, `Permissions.effective_tier/2`); the placeholder hook is
`Trinity.Tools.FS.Placeholders`, applied to `fs_write`'s content and `fs_edit`'s replacement, and
`allow_placeholders` raises the call to `:destructive`; backups live under `<data dir>/backups/<sha256 of the
path>/`, five per file, `Trinity.Tools.FS.restore/2` puts one back through the same atomic write.

## Provenance (Slice 022, M1 as built)

Every tool result that came from outside the app is a `Trinity.Content.Part` tainted `untrusted` with a SHA-256
digest, stored on the `tool` row (`parts.content_parts`, `parts.taint`); the prompt builder renders it inside
`<untrusted source= ref= digest=>` and the system prompt states that instructions inside such blocks are data;
a turn's assistant row carries the maximum taint of everything the model read (its history and the turn's tool
results), so a summary of an untrusted page is itself untrusted, and every later turn in that session is too.
A compaction (slice 023) is a summary the model wrote over rows that may have been untrusted, so its row carries
the maximum taint of its inputs and the digests of the parts it summarised, and an untrusted compaction is
rendered into the system prompt inside an `<untrusted>` block like any other outside content.
`blocked` parts are rendered as a placeholder; nothing writes one yet (024's receipts and the sentinel are where
a block comes from). `web_fetch` refuses no page by content, runs no JavaScript, and escalates a URL whose host
is not public (loopback, private, link-local) to `:ask`.

## Skills (Slice 041)

- Agent-authored skills land in `pending_approval` with a diff and rationale; nothing is active until approved.
- Scanner flags: shell commands, network calls, credential-looking strings, instructions to disable safety, external URLs.
- Hub-installed skills are scanned and default to `disabled` until the human enables.

As built at slice 041: the agent's `skill_manage` (and the `learn` flow) never writes a skill root. Every
change is staged by `Trinity.Skills.Staging` as the whole target tree under `<data dir>/pending/skills/<name>/<change id>/`,
outside every root the registry scans, with a unified diff, the scanner's findings (`Trinity.Skills.Scanner`:
shell pipes into a shell, destructive commands, credential shapes and instructions to ignore or disable safety
are `high`; plain shell commands, network calls, external URLs and base64 blobs `medium`; a file it cannot read
as text is a `low` finding naming it) and a `skill_changes` row. The one path that moves a staged tree into a
root is `Trinity.Skills.Promotion.swap/4`, and it requires an allowed `skill_apply` approval whose arguments
name the change's id and digest (021's fingerprint binds them), recomputes the staged tree's digest, archives
the previous version under `.history/`, renames the tree into place and writes an `effect` receipt on the
`skills` chain scope carrying the digest and the approval id. The census (`test/trinity/skills/census_test.exs`)
holds the tree to one caller of `swap` and two filesystem writers under `lib/trinity/skills/`, with a plant.
Auto-approval is the persona's (`settings.skills.auto_approve`, off by default, `"low"` applies `none` and
`low`); `medium` and `high` are never auto-approved, whatever a rule says. Proposing is itself a `:write` tool
call under the default policy (an approval to propose); "always allow" on `skill_manage` makes proposing free
while the promotion stays gated. An approval may have no session (a change approved from the page): its topic
is `approvals:none` and `approvals:all`. Hub installation is not built; a skill dropped by hand into the user
root loads as any other and is not scanned (a follow-up in the slice's NOTES).

## Sandbox (Slice 110)

- Luerl with reduction limits, no `os`/`io`/`require`, no filesystem; explicit host functions only.
- Native/shell code is never "sandboxed" by the BEAM: the UI says so plainly when approving `:exec`.

## Scheduled tasks (Slice 050, as built)

- **A run is an ordinary turn** in a fresh session with `origin: "cron"`, the persona the task names, the
  task's prompt as the user message. It reaches tools through the same gate and the same membrane, and
  every call it makes leaves the same receipts; the session's history is the run's record and the tasks
  page links to it.
- **Nobody is at the desk.** A tool call that asks for approval in a cron session waits its expiry on the
  permissions page (021, ten minutes by default) and is denied when it passes; the turn goes on and the
  run's summary shows the denial. A rule the owner writes beforehand is what lets a scheduled task write.
- **The curator deletes nothing.** Marking stale is a query receipt; archiving is an effect receipt written
  by the curator itself (as 041's promotion writes its own); both on the persona's memory scope.
- **Oban's dashboard** at `/oban` is in the browser pipeline with no authentication, as every page is
  until 062; it is mounted in development and where `config :trinity, :oban_web` says so.

## MCP client (Slice 060, as built)

- **Every tool a server lists is a dynamic tool under `mcp:<server>:<tool>`**, registered through one bridge
  module with the server's own description and `inputSchema` as its definition (digested like any other). The
  tier is `:ask`, because the gate maps core names alone and answers `:ask` for the rest; a row cannot lower it,
  and the owner allows a tool the way every tool is allowed, with a rule on the permissions page. The effect is
  `:none` unless the row says `:artifact` for that tool; `:catalog` is refused at write by the changeset and at
  load by the registry, with a decision receipt of outcome `deny` on the server's chain scope `mcp:<server>`.
- **Every result is untrusted.** The server's content parts become one `Trinity.Content.Part` tainted
  `:untrusted` with origin `tool:mcp:<server>:<tool>` and source `mcp://<server>/<tool>`; an image or audio
  part is a line naming its type and size (the bytes never reach the model); `isError` is a marked line the
  model reads as the server's error, not a crash.
- **A stdio child sees an allow-listed environment.** A Port's `env:` adds to the inherited environment, so the
  driver unsets by name every variable this VM holds outside PATH, HOME, the locale and temp variables and the
  row's `env_refs`; provider keys are the first thing that must not cross. `env_refs` are names, never values.
  The child's stderr is the VM's; its stdout is the wire, and a line that is not JSON-RPC is dropped with a
  warning.
- **A server's question is an approval, never an automatic answer.** A `tools/call` result with `resultType`
  `input_required` (the revision's multi-round-trip pattern) holds the call: the server's `inputRequests` go
  into an approval row's `request` column, the card renders the server's message and a form from its
  `requestedSchema`, and the owner's answer travels with the decision (`answer`) to the retry. The client
  declares form elicitation alone in its capabilities, so a server may not ask Trinity to sample a model or
  list roots. The server's `requestState` is held in the client process, keyed by session and call, and
  echoed byte-for-byte on the retry; it is never in a row, never shown, never parsed (the revision's MUST
  NOT). A server that answers `input_required` forever is a server whose every round asks the owner again.
- **The driver is thin.** It builds the outbound request and nothing else of the protocol; decoding and
  argument validation are the core's public functions (`BeamMCP.JSON.decode/1`, `BeamMCP.Schema.validate/2`),
  and a census test holds the population to that (060 AC7).

## MCP server (Slice 061, as built)

- **A stateless Plug above beam_mcp's core**, handed to the transport through its `:server` option;
  the core answers every method but `tools/call`, which Trinity answers through the same gate and
  membrane as the assistant's own calls. Will-not-implement entry 12 stands on the core: the approval
  loop lives above it.
- **Every call is attributed** to one session with `origin: "mcp"` and a persona of its own (no
  permission settings: an MCP client inherits none of the default persona's allowances), and every
  decision and query receipt carries `"origin" => "mcp"`. A `traceparent` in the request's `_meta`
  rides into the receipts' meta.
- **Exports are a closed list** the operator configures: core entries with effect `:none` or
  `:artifact`; `:catalog` is refused at boot and never listed; the list is sorted, so `tools/list` is
  deterministic.
- **A bearer before the body.** At 061 `Trinity.MCP.Server.Auth.Local`: the token from the environment or
  the generated file, compared in constant time in the transport's `:authorize` hook; a refusal decodes
  nothing. Since 062 that module is `Trinity.MCP.Auth.Local`, the `:local` profile behind the
  authorization boundary (next section), and the plug authorizes ahead of the transport; a refusal is
  `401` with a challenge rather than 061's `403`. Loopback is the default bind; a wider bind is the
  operator's setting and belongs behind a proxy that authenticates the web pages too.
- **Approvals over the wire are the owner's, never the client's.** A held call answers `input_required`
  with a `requestState` sealed by `Trinity.MCP.Server.Envelope`: AES-256-GCM under
  `<keys dir>/mcp-state.key`, binding the approval id, the session, the call id, the tool, a digest of
  the arguments, a nonce and an expiry (15 minutes by default). The client's `inputResponses` decide
  nothing: the decision is the row on the permissions page. A retry opens the envelope and is refused
  when expired, tampered, replayed or bound to another call, with a reason that names only which; a
  retry before the decision is held again on the same approval under a fresh state and never re-enters
  the gate; a retry after it runs under the envelope's call id, so the decision consumed is the one
  made and a second run is the membrane's duplicate effect.
- **Replay defence is at-most-once per partition plus idempotent effects**, stated as such:
  `Trinity.MCP.Server.Replay` holds every nonce this instance has seen until its expiry window passes;
  another instance has its own table, and across instances the gate's consumed "once" and the
  membrane's idempotency key are the backstop (a replayed state there asks the owner again rather than
  running twice). Tests hold the four reds: a replay inside the window, a replay across partitions, an
  expired envelope, one tampered byte.
- **stdio has no bearer**, as the core's page says: whoever writes to the process's standard input
  already has the host's privileges. Its standard output is the wire and the VM's log is moved to
  standard error.

## MCP authorization (Slice 062, as built)

Identity is not authority (ADR-0008 decision 4). Everything in this section answers *who is calling and
with what scopes*; whether an effect happens is the gate's answer, or the selected authority adapter's,
and nothing here changes that. The owner's decision of 2026-09-22 shapes the profiles: production is an
OAuth client and resource server against an external enterprise authorization server; the embedded
authorization server is a non-default personal profile that cannot be the path minting authority for a
regulated effect.

- **Three profiles, one behaviour.** `config :trinity, :mcp_auth, profile:` names `:local` (the default:
  061's static bearer on the loopback, no JWT anywhere), `:production` (Trinity as an OAuth 2.1 resource
  server for the external issuer the configuration names; Trinity issues nothing) or `:personal` (the same
  resource server plus a small authorization server for the owner's own clients on the owner's machine).
  `Trinity.MCP.Auth` is the boundary: `authorize/2` answers with a principal (issuer, subject, scopes,
  client, profile) and never with the token; `deps: []` on the tree, so nothing of sessions, tools or
  receipts is reachable from it (AC7, held by the boundary compiler and a census test).
- **Audience-bound or 401.** In the production and personal profiles a bearer is a JWT validated before
  the body is read: `alg` in the allow list (ES256, ES384, EdDSA, RS256; never `none`, never a shared
  secret), the signature under the issuer's published key by `kid` (RFC 8414 or OIDC discovery of the
  issuer, its JWKS cached and refreshed once on an unknown `kid`), `iss` equal to the configured issuer,
  `aud` holding this server's resource identifier, `exp` present and future, `nbf` honoured when present.
  With `introspection: true` an opaque token is asked about at the issuer's RFC 7662 endpoint and its
  answer is checked the same way. A refusal is `401` with `WWW-Authenticate: Bearer resource_metadata=…`
  (RFC 9728; the metadata names the issuer), a decision receipt of outcome `deny`, basis `auth`, on the
  MCP session's scope, naming the reason and what could be read of the caller (an unverified `iss` and
  `sub`, marked so), and nothing decoded. 061's static bearer means nothing in these profiles.
- **The personal profile cannot mint production authority.** It refuses to start (the configuration
  errors, the boot raises) when `Trinity.Authority.impl/0` is not `Trinity.Authority.Local`: a regulated
  deployment has no embedded issuer by construction. Every token it mints carries `"profile": "personal"`,
  and the production profile refuses that claim whatever key signed it. Under the production profile no
  signing key exists, the JWKS and the authorization-server metadata answer `404`, and the token and
  registration endpoints do too.
- **The personal profile's authorization server**, when chosen: RFC 8414 metadata, authorization code with
  PKCE (S256 only), RFC 8707 `resource` required and equal to this server, RFC 9207 `iss` on every
  response, the owner's consent in the browser as the login, Client ID Metadata Documents (the client id is
  the `https` URL of its document; `http` only on a loopback host) with RFC 7591 registration only behind
  `dcr: true`, ES256 tokens of ten minutes bound to this server, keys under the custody directory rotated
  by `kid` (an old key's tokens verify until they expire; AC5).
- **Scope before the gate.** A `tools/call` under a principal is checked against the tool's effect before
  the gate is asked: `trinity:tools:read` (or `trinity:recall`) for a `:none` tool, `trinity:tools:artifact`
  for an `:artifact` one, nothing for `:catalog` (never exportable). A miss is a JSON-RPC error and a
  decision receipt of outcome `deny`, basis `scope`; the gate is not consulted. A hit reaches the gate as
  any call does: a scope is what the token may ask for, never an allow rule.
- **No token material past the boundary.** The principal rides in `Trinity.Tools.Context.principal` in
  its receipt form; every decision and query receipt of the call carries `subject.principal` with `iss`,
  `sub`, `scope`, `client_id` and `profile`. The one reader of the `Authorization` header under `lib/` is
  `Trinity.MCP.Auth.bearer/1` (a census test); the tests scan receipts, the MCP session's messages and the
  client's state for a JWT prefix and find none.
- **The client role** (`Trinity.MCP.Auth.Client`, above 060's driver): on a `401` naming resource metadata
  the driver records the challenge and the `/mcp` page offers "authorize"; the host fetches the PRM and the
  issuer's metadata (its `issuer` must equal the one asked for), begins the code flow with PKCE, `state`
  and `resource`, sends the owner to the authorization server, and finishes at `/oauth/callback` (`iss`
  checked against the issuer, the code exchanged with the verifier). The token is stored per resource
  under `<data dir>/secrets/oauth/` (mode 0600, until slice 100's keychain) and the driver presents it,
  performing no flow of its own (a census over its files). The client identifies itself by the configured
  `client_id` (pre-registered at the enterprise server), by a Client ID Metadata Document URL, or by
  registering once when the server offers it and `dcr: true`.

## Secrets

- Env vars in dev; OS keychain via `Trinity.Secrets` from Slice 100 (Tauri stronghold/store or a keychain NIF).
- Never in DB, never in logs, never in prompts. `mix gate` runs a regex secret scan on the diff.
- Provider keys are read at call time by the provider module; not held in Session state.

## Gateways (Slice 070, as built)

- **An unknown sender gets a pairing prompt and nothing else.** No session is created, no model is
  called and nothing of the message is read but the code it might be: `Trinity.Gateways.Router`
  asks `Identities.admit/3` before anything else happens. The code is six characters from an
  alphabet without the pairs a person misreads, lives ten minutes, and is compared in constant
  time. It is shown on `/gateways` and nowhere else, which is the whole of the proof: a sender
  who can read it is at the owner's desktop. A configured allowlist
  (`config :trinity, :gateways, allowlist: [{adapter, id}]`) pairs a known id at first sight.
- **An identity is `(adapter, external_user_id)`**, because an id means nothing outside the
  platform that issued it, and a revoked row is kept rather than deleted: turning someone away is
  a thing the page records rather than a thing it forgets.
- **Rate limits per external user**: a token bucket in the router's own state, above the session,
  so a flood costs a row lookup and nothing more. A throttled sender is told, not dropped.
- **An adapter carries text and nothing else.** It never calls the LLM, never touches a session
  and never decides an approval; that rule is what lets a platform be added as one module and a
  configuration entry. A command that raises costs its own message: the router holds every
  conversation's binding and rescues rather than dying with them.
- **Channel trust cap.** The allowlist, pairing and rate limits control *who may talk to the bot*. They do not
  control *what an approval arriving from that channel may authorise*, and an approval surface is exactly as
  trustworthy as the account behind it. So each channel carries a cap on the risk tier it can approve, and the
  cap is applied after the gate's own decision, never instead of it. Default: `:read`, `:network` and `:write`
  are approvable from any paired gateway; `:exec` and `:destructive` are **desktop only**. The cap is
  configurable per adapter (`config :trinity, :gateways, caps: %{"console" => :write}`) and the default is the
  safe one. A capped request is not silently dropped: the requester is told the decision must be made on the
  desktop, and the refusal is receipted like any other (`Trinity.Gateways.Receipts`, basis `channel_cap`, on the
  session's own chain).

  **Amended at 070**: this paragraph read "desktop or console only" when it was written, before there was a
  console adapter. There is one now, and it is capped like every other channel rather than exempted: an
  in-process adapter is still a channel, and making it the one that may approve a destructive effect would be a
  hole shaped exactly like the thing the cap exists for. `Trinity.Gateways.Cap` applies the ceiling to every
  adapter, `Console` included, and an unknown tier is refused rather than waved through.

## Effects and receipts (Slice 024, as built)

The runner in force is `Trinity.Effects.Runner`. For every validated call it asks the gate once and writes a
decision receipt before anything runs; a decision that cannot be receipted (no approved signer) refuses the call,
reads included, and the alarm `:trinity_receipts_signer` sounds with a telemetry event. An `effect: :none` call
then runs directly and leaves a query receipt (chained, unsigned, checkpointed every 100 rows, 5 s after the
first uncovered row, on shutdown and on rehydrate); every other call becomes a `Trinity.Authority.Staged` and
crosses `Trinity.Effects.execute/2`, which denies with a receipt, in this order, when: the decision is not
`:allow`; the effect class is not admitted, or a `:catalog` tool is absent from `Trinity.Tools.Catalog`; the
fingerprint re-derived over the arguments it holds is not the one the decision bound (M2); an effect receipt
already names this session and call id (the idempotency key, read from the chain); the authority in force refuses.
Then the admission receipt is signed and written, `Trinity.Authority.Local.execute/3` runs the tool's `execute/2`
(the only such caller for effectful tools; a census over `git ls-files` with a planted bypass holds it), and the
outcome receipt follows with the result's digest.

The signature is over DSSE's PAE of a payload type and the canonical body, the type carrying the scheme
(`trinity/receipt/receipt_v2_ed25519`), so a signature made for a receipt cannot be presented as anything else the
same key signs. `key_id` is the RFC 7638 thumbprint of the public key and sits inside the signed body; the
registry row binds one algorithm to it and the verifier takes the algorithm from there, refusing a scheme whose
family is not the row's before any signature check, and refusing schemes the caller did not allow. The key is a
0600 file under the data directory's `keys/`, read on every sign and never cached, so a key removed mid-run is a
signer unavailable at the next receipt. What a file-backed key establishes: that the chain was not altered after
the fact by anything lacking read access to that file, and nothing more. Selection is once, at boot: P-384 when
`crypto:info_fips/0` is `enabled` (proven on the `fips` leg), Ed25519 otherwise, ML-DSA-87 by configuration
where the runtime carries it; the boot receipt names the choice and the authority in force, with the core policy
hash in unsigned metadata (the R21 default). `bin/verify_receipt.exs` verifies an export with `elixir` alone,
from an empty directory, with the exit vocabulary 0, 1, 2, 5, 6.

## Data at rest

- SQLite file under the OS data dir with 0600 perms. Optional at-rest encryption is a later slice (SQLCipher via exqlite build flag), noted rather than planned.
