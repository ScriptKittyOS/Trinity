# Slice 041 — Skill self-management with staged approval + scanner

| Field | Value |
|---|---|
| Phase | 4 Skills |
| Milestone | M4 Learns |
| Size | M |
| Depends on | 040, 021 |

## Goal
The agent can propose new skills and edits to existing ones (`skill_manage` tool: create/patch/write_file/
remove_file/delete) — staged as `skill_changes` with diff and rationale, scanned for dangerous content, shown in an
approval UI, and applied to the filesystem only on approval. Plus a `/learn` flow that distils a document/URL into
a knowledge skill (SKILL.md + `references/`).

## Why
Vision goal 4: "grows safely". A self-improving skills library is only safe if the approval step is not optional.

## Scope
**In:**
- `skill_manage` tool with actions and args validated; risk `:write`; always routed through staging regardless of permission rules (design decision: skills are code-adjacent).
- `Trinity.Skills.Staging`: writes proposals to `<data_dir>/pending/skills/<name>/<change_id>/`; `skill_changes` rows; diff generation; apply/reject; versioning (`skills.version++`, previous version archived under `<data_dir>/skills/.history/`).
- `Trinity.Skills.Scanner`: heuristics (shell commands, network calls, credential patterns, "ignore previous instructions", external URLs, base64 blobs) → findings with severity; high severity blocks auto-approval even if a rule would allow.
- Approval UI: pending skill changes list, side-by-side diff, scanner findings, approve/reject with comment; reuses `Trinity.Permissions.Gate` topics so gateways (070) can approve too.
- `/learn` command (UI + tool `learn(source)`): fetch/parse source (URL via Web.Fetch, local file via FS.Read, pasted text) → LLM distils into a lean SKILL.md + reference files → staged like any other change.
- Auto-approve option per persona for low-severity changes (default off).
**Out:**
- Hub/tap installation, Lua scripts execution (110), skill evals.

## Design notes
- Staging dir is outside the registry's scan roots, so pending skills never load.
- Applying a change is atomic per skill dir (write to temp dir, swap).

## Deliverables
- `lib/trinity/skills/{staging,scanner,manager,learn}.ex`, tool, migration, UI, tests with fixture proposals.

## Acceptance criteria
1. [auto] Agent `skill_manage.create` → `skill_changes` row + staged files; registry does **not** list it (test).
2. [auto] Approve → files land in `<data_dir>/skills/<name>/`, registry lists it, version = 1 (test).
3. [auto] Patch an existing skill → diff shown; approve → version 2; `.history` has version 1; reject → nothing changed (tests).
4. [auto] Scanner flags a proposal containing `curl … | sh` and an API-key-looking string as high severity; auto-approve is refused even when enabled (test).
5. [auto] Killing the app between staging and approval → pending change survives and is still approvable (restart test).
6. [manual] `/learn` with a local markdown file produces a staged knowledge skill with a `references/` file and a SKILL.md under ~200 lines (live/eval tag; sample in proof).
7. [manual] UI screenshots: pending list, diff view, findings.
8. [auto] **A census over `Trinity.Skills.*` finds exactly one apply path and it requires an approval id. Plant a second path; the census must fail.**

## Proof required
- Tests, screenshots, sample learned skill.

## Manual verification queue
Every `[manual]` criterion below needs a person. Listed here so the owner sees the queue at G1 rather
than at review time.
- **AC6** — `/learn` with a local markdown file produces a staged knowledge skill with a `references/` file and a SKILL.md under ~200 lines (live/eval tag;….
- **AC7** — UI screenshots: pending list, diff view, findings.

## Definition of Done
- [ ] gate green · [ ] AC1–8 proven · [ ] docs/07 synced · [ ] ROADMAP → done · [ ] commit + tag

## Commit & tag
`feat(s041): complete slice 041 — skill self-management with approval` · tag `slice/041`

## Risks / open questions
- Diff quality for binary/reference files — treat non-text as replace-whole with a size note.

## Platform alignment (appended 2026-09-05)
- **Promotion is a gated artifact effect:** approve/reject of a staged change goes through
  `Trinity.Permissions` and yields a receipt carrying the change's digest; no code path applies a change without
  an approval id. This is AC8 in the list above.
- Cross-scope promotion (project → global) is a second, separate approval.
