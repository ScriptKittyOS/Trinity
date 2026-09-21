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
