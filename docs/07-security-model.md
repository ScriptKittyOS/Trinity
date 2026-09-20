# 07: Security model

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

## Permission gate (Slice 021)

Every `Trinity.Tools.Tool` declares `effect/0` (`:none | :artifact | :catalog`) and the gate derives risk from the tool **name only** via `Trinity.Permissions.tier/1` (`:read | :write | :exec | :network | :destructive`; unmapped → ask).

Name-only is deliberate: it makes the tier a code-owned function of a value no caller can influence. That holds only while the namespace is closed. Tools registered at runtime carry names chosen elsewhere, by an MCP server or a skill author, so **every dynamic tool is namespaced before the tier lookup**: `mcp:<server>:<tool>`, `skill:<name>`. Core tool names are reserved and cannot be claimed. Without this a hostile server naming its tool `fs_read` inherits the `:read` tier and its allow-by-default policy, and the unmapped-goes-to-ask fallback does not catch it, because the name is mapped.
`Trinity.Permissions.decide(session, tool, args)` consults, in order: session grants → persona policy → global
`tool_permissions` → default policy (`:read` allow, `:network` allow, `:write` ask, `:exec` ask, `:destructive` ask).
An `:ask` suspends the Session in `approval_wait`, broadcasts to `approvals:<id>`, and resumes on decision.
Decisions are recorded (`approvals` table) and receipted. Approvals bind the canonical fingerprint of `(tool, args, scope, cwd, canonicalization_version)` and are re-derived at execution; "allow for this session" binds that fingerprint with an expiry; "always allow" is a rule, recorded as such.

## Shell (Slice 022)

- MuonTrap-supervised; command killed when the Task dies; timeout default 120 s; output capped (1 MB) with truncation marker.
- Dangerous-pattern allowlist/denylist (rm -rf /, curl|sh, sudo, chmod 777 …) forces `:destructive`.
- Working directory jailed to configured roots unless approved.

## Filesystem (Slice 022)

- Path allowlist (project roots + data dir). Writes outside → ask.
- **Write-validation hook**: reject writes whose content contains truncation markers (`/* ... */`, `// ...`,
  `# ... rest unchanged`) unless the file is new or the tool is called with `allow_placeholders: true` after approval.
- Atomic writes (temp + rename) and a per-file backup ring (last 5) under the data dir.

## Skills (Slice 041)

- Agent-authored skills land in `pending_approval` with a diff and rationale; nothing is active until approved.
- Scanner flags: shell commands, network calls, credential-looking strings, instructions to disable safety, external URLs.
- Hub-installed skills are scanned and default to `disabled` until the human enables.

## Sandbox (Slice 110)

- Luerl with reduction limits, no `os`/`io`/`require`, no filesystem; explicit host functions only.
- Native/shell code is never "sandboxed" by the BEAM: the UI says so plainly when approving `:exec`.

## Secrets

- Env vars in dev; OS keychain via `Trinity.Secrets` from Slice 100 (Tauri stronghold/store or a keychain NIF).
- Never in DB, never in logs, never in prompts. `mix gate` runs a regex secret scan on the diff.
- Provider keys are read at call time by the provider module; not held in Session state.

## Gateways

- Allowlist of external user ids; DM pairing code flow (Slice 070). Unknown senders get a pairing prompt, nothing else.
- Rate limits per external user.
- **Channel trust cap.** The allowlist, pairing and rate limits control *who may talk to the bot*. They do not
  control *what an approval arriving from that channel may authorise*, and an approval surface is exactly as
  trustworthy as the account behind it. So each channel carries a cap on the risk tier it can approve, and the
  cap is applied after the gate's own decision, never instead of it. Default: `:read`, `:network` and `:write`
  are approvable from any paired gateway; `:exec` and `:destructive` are **desktop or console only**. The cap is
  configurable and the default is the safe one. A capped request is not silently dropped: the requester is told
  the decision must be made on the desktop, and the refusal is receipted like any other.

## Data at rest

- SQLite file under the OS data dir with 0600 perms. Optional at-rest encryption is a later slice (SQLCipher via exqlite build flag), noted rather than planned.
