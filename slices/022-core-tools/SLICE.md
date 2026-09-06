# Slice 022 — Core tools: filesystem, web, shell

| Field | Value |
|---|---|
| Phase | 2 Tools |
| Milestone | M2 Acts |
| Size | L |
| Depends on | 021 |

## Goal
The first useful toolset: read/write/list/search files with the write-validation hook and backups; fetch and
extract web pages; web search via a pluggable search provider; run shell commands under MuonTrap with timeouts,
output caps, and dangerous-pattern detection. All risk-tagged and gated.

## Why
M2 "Acts". Also closes the placeholder-overwrite class of data loss by design.

## Scope
**In:**
- `Trinity.Tools.FS.{Read, Write, Edit, List, Glob, Grep}` — root allowlist from config + session cwd; `Write`/`Edit` risk `:write`; atomic writes; backup ring (last 5 per file under data dir); **write-validation hook** rejecting truncation markers unless `allow_placeholders: true` (which is `:destructive` risk).
- `Trinity.Tools.Web.Fetch` (Req + Floki readability-style extraction, size cap, timeout, content-type handling, `<untrusted>` wrapping) and `Trinity.Tools.Web.Search` behind `Trinity.Tools.Web.SearchProvider` behaviour with one implementation (a provider chosen by the human: Brave/Tavily/Exa/DuckDuckGo-HTML; keyed via env) and a fake for tests.
- `Trinity.Tools.Shell.Run` — MuonTrap; cwd jail; env scrubbing (no secrets); timeout default 120 s; output cap 1 MB with tail retention; `:exec` risk; dangerous patterns → `:destructive`; background processes killed on Task exit (MuonTrap guarantees).
- Untrusted-content wrapping applied to all tool results that originate outside the app (web, shell output, file content) via `Trinity.Tools.Untrusted.wrap/2`.
- Toolsets: `:fs`, `:web`, `:shell`.
**Out:**
- Browser automation (future slice), code-interpreter (110), image tools.

## Design notes
- FS paths are normalised and checked against the allowlist *after* symlink resolution.
- `Edit` is search/replace with uniqueness check (like `str_replace`), returning a diff in the result.
- Shell runs `["/bin/sh", "-c", cmd]` on POSIX; on Windows `cmd /C` (document limits); prefer `MuonTrap.cmd/3`.

## Deliverables
- `lib/trinity/tools/fs/*`, `lib/trinity/tools/web/*`, `lib/trinity/tools/shell/*`, `lib/trinity/tools/untrusted.ex`, config toolsets, tests (with tmp dirs and a local Bandit test server for web), docs/07 updates.

## Acceptance criteria
1. [auto] `Read` outside the allowlist → permission `:ask` (not silent failure); inside → content (tests).
2. [auto] `Write` with content containing `/* ... */` or `// ... rest of file` → rejected with an explanatory error; same content with `allow_placeholders: true` → approval required, then written (tests).
3. [auto] `Write` is atomic (temp+rename) and creates a backup; `Trinity.Tools.FS.restore/2` restores the previous version (test).
4. [auto] `Edit` fails when the search string is not unique; succeeds and returns a diff otherwise (tests).
5. [auto] `Web.Fetch` against a local test server: extracts main text, caps size, wraps in `<untrusted>`; binary content-type → descriptive error (tests).
6. [manual] `Web.Search` fake returns structured results; live-tagged test hits the real provider (redacted output).
7. [auto] `Shell.Run "sleep 10"` with 1 s timeout → killed; no orphan process remains (`ps` check in test on POSIX).
8. [auto] `Shell.Run "rm -rf /"`-like command → risk escalates to `:destructive` and requires approval (test via Mox on Permissions).
9. [auto] Secrets in env are not visible to the child (`env | grep KEY` returns nothing in test).
10. [manual] End-to-end manual: ask the agent to "list the files in the project and summarise the README" → works with approvals as expected (GIF).
11. [auto] **A summary of an untrusted page is itself tagged untrusted (test), and an instruction inside it is not treated as a command by the prompt builder (test).**

## Proof required
- Tests, `ps` evidence, GIF.

## Definition of Done
- [ ] gate green · [ ] AC1–11 proven · [ ] docs/07 synced · [ ] VERSIONS (muontrap, floki ✅) · [ ] ROADMAP → done · [ ] commit + tag

## Commit & tag
`feat(s022): complete slice 022 — core tools (fs, web, shell)` · tag `slice/022`

## Risks / open questions
- **Windows shell: decide before this slice, not inside it.** Windows is first class elsewhere (001 AC3, 100 AC1).
  MuonTrap is POSIX-focused, and the guarantee that justified choosing it in `docs/02` is that the child dies when
  the Task dies. That is exactly the guarantee the `System.cmd` fallback does not give. A shell tool that can leave
  orphaned processes is a different safety claim from one that cannot, so `docs/07` states the guarantee per
  platform, and the approval card says which one applies on the machine it is running on. It already promises to
  say plainly that the BEAM is not an OS sandbox; this is the same honesty about a narrower claim.
- MuonTrap is at 2.0.0 while the plan pinned `~> 1.8` (H6). Read the 2.0 API against this design before starting.

## Platform alignment (appended 2026-09-05)
- **M1 provenance gate replaces plain `<untrusted>` wrapping.** Every content part is `%Trinity.Content.Part{origin,
  source_ref, digest, taint, text}`; taint ∈ `{trusted, untrusted, blocked}`; summaries/compactions carry the
  maximum taint of their inputs; a `blocked` part is replaced by a safe placeholder and a local receipt. The
  model-facing rendering states provenance explicitly. This is AC11 in the list above.
- Artifact writes (`FS.Write`, `FS.Edit`, skill files, memory) are `:artifact` effects: gated and receipted even
  whichever authority is in force, and never folded into an external adapter's catalog.
- Shell is a `:catalog` effect at risk `:exec` under local authority. Under an external adapter it is available
  only if that adapter's catalog names it, which is the adapter's decision, not Trinity's.
