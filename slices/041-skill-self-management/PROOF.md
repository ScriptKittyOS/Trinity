# Proof for slice 041: Skill self-management with staged approval + scanner

Agent: Trinity · Coding Agent · Date: 2026-09-21 · Branch: slice/041-skill-self-management · Final commit: (the commit carrying this file; named in the closing correction)

## Summary
The agent proposes skills and changes to them (`skill_manage`; the `learn` flow distils a document); every
proposal is staged as the whole target tree under the data directory's pending root with a unified diff, the
scanner's findings and a `skill_changes` row, and never loads. The one path that moves a staged tree into a
root is `Trinity.Skills.Promotion.swap/4`, which requires an allowed `skill_apply` approval naming the change's
id and digest, archives the previous version under `.history/`, renames the tree into place and writes an
effect receipt on the `skills` chain scope; the census holds the tree to that one caller and to two filesystem
writers, with a plant. The persona's auto-approval applies `none` and `low` only; `high` never. The `/skills`
page gained the pending list, the diff and findings view, approve and reject with a comment, and the learn
form. Nine findings in NOTES.md; the one that changed a schema was 021's approvals needing a session.

## Gate
```
$ mix gate                                   (this machine, OTP 28.5.0.5, Elixir 1.20.4, under a 32 GiB cgroup, tree ae200d7 with this file, NOTES, ROADMAP and coverage.tsv uncommitted on top)
2139 mods/funs, found no issues.
... SCAN COMPLETE ...
No retired or security advisory packages found
No vulnerabilities found.
Result: 448 passed, 18 excluded
plan_check: PASS
exit=0
```
The Postgres leg on this machine (`pgvector/pgvector:pg17` in a container), tree ae200d7:
```
$ TRINITY_DB=postgres DATABASE_URL=… MIX_ENV=test mix ecto.reset && mix test --exclude sqlite
Result: 428 passed, 38 excluded
exit=0
```
CI: named in the closing correction.

## Tests
```
$ mix test --cover                           (tree ae200d7)
Result: 448 passed, 18 excluded
|     40.00% | Trinity.Skills.Change                  |   (a schema: its accessor functions)
|     81.25% | Trinity.Skills.Manager                 |
|     83.67% | Trinity.Skills.Learn                   |
|     84.21% | Trinity.Skills.Scanner                 |
|     89.11% | Trinity.Skills.Staging                 |
|     92.09% | TrinityWeb.SkillsLive                  |
|     94.23% | Trinity.Skills.Promotion               |
|    100.00% | Trinity.Skills.Diff                    |
|    100.00% | Trinity.Skills.Tools.Learn             |
|    100.00% | Trinity.Skills.Tools.Manage            |
|     80.55% | Total                                  |
```
`coverage.tsv` row: `041  80.55  ae200d7  2026-09-21` (from 79.86 at 040).

The slice's 20 tests (`mix test test/trinity/skills/{staging,scanner,census,manage_tools}_test.exs test/trinity_web/live/skill_changes_test.exs --trace`):
```
test/trinity/skills/staging_test.exs
  * test AC1: a create is a row and staged files under the pending root, and the registry does not list it
  * test AC2: approve a create: the files land in the user root, the registry lists it at version 1, the receipt carries the digest and the approval
  * test AC3: a patch shows its diff; approved it is version 2 with version 1 in .history; a rejected one changes nothing
  * test write_file and remove_file; a bad path, a bad diff, an invalid result and an unknown skill are refused by name
  * test AC5: the registry and the gate restarted between staging and approval: the change and its files survive and it is still approvable
  * test AC8: swap/3 refuses without an approval, with a pending, denied, other-tool or other-change approval, and when the staged files changed
  * test the diff: equal texts are empty; an edit shows context, removal and addition; a patch replays it
test/trinity/skills/scanner_test.exs
  * test each rule fires on its shape and not on plain prose
  * test content the scanner skips is a low finding that names the file and why
  * test AC4: a proposal with curl | sh and an API-key-looking string is high; auto-approval is refused even when the persona allows it
test/trinity/skills/census_test.exs
  * test the callers of Promotion.swap/3 are the manager and the plant
  * test under lib/trinity/skills the filesystem writers are the proposer and the promotion, and nothing else
  * test the planted writer is caught by the writers' grep, and the plant is a real second path
  * test every write in the proposer targets the pending directory: its paths derive from pending_dir/0 or a change_dir under it
test/trinity/skills/manage_tools_test.exs
  * test registered as core writes in the skills toolset
  * test skill_manage stages a create and says so; the registry does not list it; the receipts are a decision and the effect pair
  * test with the persona's auto-approval on, a clean proposal is applied at once and a high one is staged
  * test learn: a file under the roots is distilled by the fake's scripted object into a staged skill with a reference; outside the roots is refused; a URL and text are accepted sources
test/trinity_web/live/skill_changes_test.exs
  * test the pending list, the change view with findings and diff, approve with a comment, reject
  * test the learn form stages a skill from a file under the project (the fake's object) and names a source it cannot read
```

## Acceptance criteria evidence

### AC1 [auto]: Agent `skill_manage.create` → `skill_changes` row + staged files; registry does not list it
`staging_test.exs` "AC1": a create is a `pending` row with the rationale, the digest of its tree, the diff
(`+++ proposed-skill/SKILL.md`, `+Step one.`), and its files under the pending root; `Trinity.Skills.get/1`
is nil before and after a rescan (the pending root is outside every root the registry scans).
`manage_tools_test.exs` "skill_manage stages a create…": the same through the runner in force with the
session as `proposed_by`, the tool's answer saying it is not applied, and the receipts of a write (a decision
and the effect pair).

### AC2 [auto]: Approve → files land in `<data_dir>/skills/<name>/`, registry lists it, version = 1
`staging_test.exs` "AC2": `Manager.approve/2` requests a `skill_apply` approval whose arguments carry the
change's id and digest, decides it, and the promotion puts the tree in the user root; the registry lists it at
version 1 from source `user`; the staged directory is gone; the effect receipt on the `skills` scope carries
the digest and the approval id (`subject_ref` `skill:proposed-skill@<digest>`) and its hash is on the row with
the decider's comment.

### AC3 [auto]: Patch an existing skill → diff shown; approve → version 2; `.history` has version 1; reject → nothing changed
`staging_test.exs` "AC3": a patch by unified diff shows `-Step two.` / `+Step two, carefully.` and is not
destructive; rejected, the row says who and why, the staged files are gone and the skill is unchanged at
version 1; the same patch approved is version 2 with the previous `SKILL.md` at `.history/proposed-skill/v1/`;
a whole-body replace and a delete are destructive and say so; the delete applied removes the skill and
archives v2.

### AC4 [auto]: Scanner flags `curl … | sh` and an API-key-looking string as high; auto-approve refused even when enabled
`scanner_test.exs` "AC4": the proposal's severity is `high` with `shell_pipe` and `credential` among its
rules; with the persona's `skills.auto_approve` at `"low"`, `Manager.auto/2` leaves it pending and the skill
never loads; a clean proposal under the same persona is applied at once as `"auto"`. "each rule fires…"
covers every rule and plain prose; "content the scanner skips…" the low finding for a binary and an
oversized file.

### AC5 [auto]: Killing the app between staging and approval → pending change survives and is still approvable
`staging_test.exs` "AC5": after staging, `Trinity.Skills.Registry` and `Trinity.Permissions.Gate` are
terminated and restarted under the application supervisor; the row is still `pending`, its `SKILL.md` on
disk, and the approval applies it at version 1. (The row and the files are the persistence; nothing about a
staged change lives in a process.)

### AC6 [manual]: `/learn` with a local markdown file produces a staged knowledge skill with a `references/` file and a SKILL.md under ~200 lines
On the real model (nvidia:nemotron), `docs/backup.md` (62 lines) through `Trinity.Skills.Learn.learn_for/3`,
2026-09-21:
```
learn took 151385 ms
staged trinity-backup-restore-skill 01a0c527-10c2-73b0-bda5-cdb640d95679 severity=none
  32 SKILL.md
  16 references/backup-reference.md
```
The staged skill is in `proof/learned/` (the `learned_from` path shortened). The first attempt's answer was
one run-on line (NOTES finding 4); the prompt and the unflattening are from that. The automatic half:
`manage_tools_test.exs` "learn: a file under the roots…" and the page test, with the fake's scripted object.

### AC7 [manual]: UI screenshots: pending list, diff view, findings
`proof/ac7-1-pending.png` (the list: the planted high-severity `installer` and the learned skill, each with
its severity, action, rationale and time), `proof/ac7-2-diff.png` (the learned skill's change opened: the
diff of `SKILL.md` and the reference, the approve form), `proof/ac7-3-findings.png` (the installer opened:
"High severity: never auto-approved", the findings `shell_pipe` at line 10, `credential` at line 11,
`external_url`, and the diff). The automatic half: `skill_changes_test.exs`.

### AC8 [auto]: A census over `Trinity.Skills.*` finds exactly one apply path and it requires an approval id; a planted second path fails the census
`census_test.exs`: over every `lib/*.ex` and `test/support/*.ex` that `git ls-files` names, the callers of
`Promotion.swap(` are `lib/trinity/skills/manager.ex` and the planted `test/support/skills/bypass.ex`
(which must be there or the census is not looking); under `lib/trinity/skills/` the filesystem writers are
`staging.ex` and `promotion.ex` and nothing else, the plant's write caught by the same grep; the proposer's
writes derive from `pending_dir/0`. `staging_test.exs` "AC8": `swap` refuses `nil`, a missing approval, a
pending one, a denied one, one for another tool, one for another change, and a staged tree whose digest
moved, each by name; a promoted change cannot be promoted again.

## Manual verification for the reviewer
- **AC6**: read `proof/learned/SKILL.md` and its reference; or put a markdown file under a project root,
  open `/skills?project=<root>`, type its name in the learn form (the persona's model answers in a minute
  or two; the page says "learning from …" meanwhile) and decide the staged change.
- **AC7**: the three screenshots.

## Deviations from SLICE.md
NOTES.md, the five stated before code (the proposer and the one apply path; `skill_manage` and `learn` as
`:write` tools that ask under the default policy; the promotion's receipt on a `skills` scope; `medium` neither
auto-approved nor blocked from a human; no cross-scope promotion) and, found building: 021's approvals may
have no session (finding 1: a migration and a changeset change), the learn as the view's async task
(finding 3).

## Versions touched
`VERSIONS.md` updated: no (no new dependency; the diff is Trinity's own). `mix versions.verify`: OK.

## Git
```
$ git log --oneline main..HEAD
(named in the closing correction, after the final commit)
```
