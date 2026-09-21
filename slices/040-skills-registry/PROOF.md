# Proof for slice 040: Skills registry, SKILL.md format, progressive disclosure

Agent: Trinity · Coding Agent · Date: 2026-09-21 · Branch: slice/040-skills-registry · Final commit: (the commit carrying this file; named in the closing correction)

## Summary
Skills as directories with a `SKILL.md` in the agentskills.io format (its specification read and held to,
Trinity's keys under `trinity:`), found under three roots in precedence order (a project's `.trinity/skills`,
the data directory's `skills`, the bundled `priv/skills`), parsed with a per-file digest manifest, indexed in
the `skills` table by a registry over ETS that watches the roots, and shown to the model by progressive
disclosure: the index in the context tier under the 338-token reserve slice 033 left, the body on
`skill_view`, a file on `skill_file` behind a symlink-resolving jail. Conditional activation by the tools and
toolsets registered; enable, disable and reindex on `/skills`; three bundled skills. Seven findings in
NOTES.md; the one that shaped the design was the test sandbox's ownership of the one connection at boot,
which moved the index writes to the first read.

## Gate
```
$ mix gate                                   (this machine, OTP 28.5.0.5, Elixir 1.20.4, under a 32 GiB cgroup, tree dc9dc6b with this file, NOTES, ROADMAP and coverage.tsv uncommitted on top)
2007 mods/funs, found no issues.
... SCAN COMPLETE ...
No retired or security advisory packages found
No vulnerabilities found.
versions.verify: OK. 102 locked packages, none disagreeing with 53 pins
Result: 428 passed, 18 excluded
plan_check: PASS
exit=0
```
CI: named in the closing correction. Run 35623752961 on `ccb3747` failed AC3 on the gate and fips legs
(no `inotifywait` there: NOTES finding 3), passed on postgres; the fix is `dc9dc6b`.

## Tests
```
$ mix test --cover                           (tree dc9dc6b)
Result: 428 passed, 18 excluded
|      0.00% | Mix.Tasks.Trinity.Skills.Reindex       |   (a mix task; run below)
|     66.67% | Trinity.Skills.Row                     |
|     81.25% | Trinity.Skills.Sources                 |
|     81.82% | Trinity.Skills.Skill                   |
|     88.89% | Trinity.Skills.Parser                  |
|     89.47% | Trinity.Skills.Registry                |
|     92.59% | Trinity.Skills.Tools.File              |
|     93.75% | Trinity.Skills.Tools.List              |
|     94.20% | TrinityWeb.SkillsLive                  |
|     94.44% | Trinity.Skills.Tools.View              |
|    100.00% | Trinity.Context.SkillsIndex            |
|    100.00% | Trinity.Skills                         |
|    100.00% | Trinity.Skills.Index                   |
|     79.86% | Total                                  |
```
`coverage.tsv` row: `040  79.86  dc9dc6b  2026-09-21` (from 78.99 at 032).

The slice's 19 tests (`mix test test/trinity/skills test/trinity/context/skills_index_test.exs test/trinity_web/live/skills_live_test.exs --trace`):
```
test/trinity/skills/parser_test.exs
  * test AC1: the bundled fixture parses: frontmatter, category from metadata, body, references, digest and manifest
  * test AC1: malformed frontmatter is refused with a descriptive reason, one per fault
  * test the three bundled skills parse and carry their Trinity keys
  * test the spec's constraints on name, description, compatibility, metadata, allowed-tools and the trinity keys
  * test a skill whose files do not match its manifest is refused by the source loader, not the parser
  * test a scan keeps the good skills beside the bad ones' errors
test/trinity/skills/registry_test.exs
  * test AC2: the same name in user and bundled: user wins and the bundled one is listed as shadowed; the rows carry both
  * test AC2: a project skill wins over the user's, and is visible only to a caller naming that project
  * test AC3: a SKILL.md edited on disk is in the registry within 2 s without a rescan (1426.8ms)
  * test AC5: conditional activation hides a skill whose tool or toolset is absent and shows a fallback only when its toolset has no tool
  * test the index rows: a status survives a rescan, a body change bumps the version, a removed skill's row goes
  * test a skill whose manifest does not match its files is refused and named in the errors
test/trinity/skills/tools_test.exs
  * test registered as core reads in the skills toolset, the catalog untouched
  * test AC4: with 50 fixture skills the index stays under the cap and says it was cut; skill_view returns the body; skill_file reads a reference and refuses ../secrets
  * test the prompt's index: categories alone and the hint when the list does not fit; the whole list when it does
test/trinity/context/skills_index_test.exs
  * test AC6: the prompt snapshot carries the skills index in the context tier, after the project instructions
  * test a session without a project still carries the global skills, and none when every skill is disabled
test/trinity_web/live/skills_live_test.exs
  * test lists the skills with source badges and shadows, views one, disables and enables it, reindexes
  * test names the directories that did not load
```
Fixtures: `test/support/fixtures/skills/{bundled,user,bad,mismatch}` (`find test/support/fixtures/skills -type f | wc -l` → 14).

## Acceptance criteria evidence

### AC1 [auto]: A fixture skill dir is parsed into a `%Skill{}` with correct frontmatter/body/refs; malformed frontmatter → descriptive `{:error, ...}`
`test/trinity/skills/parser_test.exs`: `bundled/echo-skill` parses to name, description, category (from
`metadata.category`), body, `references/notes.md`, the body's digest and a manifest of both files with their
digests; the five `bad/` fixtures answer `{:no_frontmatter, _}`, `{:name, "\"Bad_Name\": lowercase a-z…"}`,
`{:name, "\"other-name\" does not match its directory \"wrong-dir\""}`, `{:description, "longer than 1024
characters"}`, `{:yaml, "Unfinished flow collection"}`; a missing directory `{:no_skill_md, _}`. The
specification's constraints (name grammar and length, description bounds, compatibility bound, metadata
shape, allowed-tools shape, the `trinity` keys and `risk` vocabulary) each refuse by name, and unknown keys are
ignored, not refused. The three bundled skills parse with their `trinity` keys.

### AC2 [auto]: Precedence: same-named skill in project and bundled → project wins
`test/trinity/skills/registry_test.exs`: `echo-skill` in the user fixtures shadows the bundled one (`source:
"user", shadows: ["bundled"]`, the user's body), and both rows are in the index; a project's `echo-skill`
under `.trinity/skills` wins over both (`shadows: ["user", "bundled"]`, `scope: "project"`) for a caller
naming that project root and is invisible to one that does not.

### AC3 [manual]: Hot reload: modifying a SKILL.md on disk updates the registry within 2 s without restart
The test "AC3: a SKILL.md edited on disk is in the registry within 2 s without a rescan" runs in the suite on
every leg. On this machine (inotify):
```
AC3: the edit was in the registry after 316 ms
```
Under the polling fallback the registry uses where `inotifywait` is absent (the gate's runners), forced here:
```
$ TRINITY_SKILLS_POLL=1 mix test test/trinity/skills/registry_test.exs:118      (three runs)
AC3: the edit was in the registry after 1219 ms
AC3: the edit was in the registry after 1218 ms
AC3: the edit was in the registry after 1219 ms
```
The owner's half: edit a bundled `SKILL.md` while the dev server runs and reload `/skills`; the change is
there, and the version bumps once the index row is rewritten (`body_hash` is the whole file's digest).

### AC4 [auto]: `skills_list` output stays under the cap with 50 fixture skills; `skill_view` returns the body; `skill_file` rejects `../secrets`
`test/trinity/skills/tools_test.exs` "AC4": 50 fixture skills in five categories; `skills_list` through the
runner in force answers under 338 tokens (`Tokens.estimate`), with a `limit_tokens` of 60 under 65, filtered
by category to 10; `skill_view("fixture-07")` returns the body with the file listing and the digest in its
meta; `skill_file` reads `references/notes.md` (21 bytes) and refuses `../secrets`, `../../secrets`,
`/etc/passwd`, `references/../../secrets` and a symlink out of the directory, each as
`{:outside_skill, path}`; a missing file is `{:no_such_file, _}`, a disabled skill `{:no_such_skill, _}`.
Every call leaves a decision and a query receipt and nothing else.

### AC5 [auto]: Conditional activation hides a skill requiring a disabled toolset
`test/trinity/skills/registry_test.exs` "AC5": `needs-missing-tool` (`requires_tools: [no_such_tool]`) and
`needs-web` (`requires_toolsets: [teleport]`) are never active; `needs-shell` is active exactly when the shell
toolset has a registered tool, and `no-shell-fallback` (`fallback_for_toolsets: [shell]`) exactly when it has
none, so the same test is right on Linux and on Windows. Read as "a toolset with no registered tool" (NOTES,
deviation b).

### AC6 [auto]: Prompt snapshot includes the skills index in the context tier
`test/trinity/context/skills_index_test.exs` "AC6": the block `## Skills` with the categories and one line a
skill sits after the AGENTS.md block in the context tier, a project's skill included for that project's
session, under 338 tokens; through a Session the fake provider's last request carries it; with every skill
disabled the block is gone. `tools_test.exs` "the prompt's index…": over the cap, the whole lines that fit
and the hint; at 40 tokens, the categories with their counts and the hint.

### AC7 [manual]: agent, asked to do a git task, calls `skill_view("git-workflow")` then follows it (GIF)
`proof/ac7-git-workflow.gif` (five frames, 3 s each; the stills beside it), the dev server on this machine,
`nvidia:nemotron`, a scratch repository with one uncommitted file as the session's project root:
1. `ac7-1-skills.png`: `/skills`, the three bundled skills with their badges.
2. `ac7-2-skill-view.png`: `git-workflow` opened on the page.
3. `ac7-3-skill-view-call.png`: the session: "Check your skills for the git procedure first and follow it":
   `skills_list`, then `skill_view("git-workflow")`.
4. `ac7-4-approval.png`: the shell request (`git commit -m "feat: add greet function…"`) at the permission gate.
5. `ac7-5-done.png`: the commit made and `git log --oneline -3` shown; the answer names the skill it followed.
The transcript (session `01a0c4bc-6f47-73af-bd34-f1c719bd6da5`, the dev database): `skills_list` →
`skill_view` (once with a stray `path` argument, refused by the schema, then correctly) → `git status --short`
→ `fs_read greet.ex` → `git log --oneline -10` → `git add` → `git commit` → `git log`. The scratch
repository: `92d55bd feat: add greet function` over `a79418b chore: initial`. NOTES finding 5 has what the
driver got wrong in the middle (an approval it did not click); the skill was followed throughout.

### AC8 [manual]: An agentskills.io skill written for another agent, downloaded by the human, parses and appears
The agent's dry run, 2026-09-21: `anthropics/skills`' `skill-creator/SKILL.md` (33,168 bytes, fetched from
GitHub) through `Trinity.Skills.Parser.parse_dir/1`:
```
%{name: "skill-creator", category: "general", references: [], scripts: [],
  body_hash: "dcd4803e61e913e6fc27294184cd3a71f09f5e924ff20c8a9a20173e7b3c2bcf",
  description: "Create new skills, modify and improve existing skills, and measure skill perform…"}
```
For the owner: download a skill directory from another agent's collection into `<data dir>/skills/<name>/`
(the directory name equal to its `name`), open `/skills` or run `mix trinity.skills.reindex`; its name and
`user` source appear. A skill whose `name` does not match its directory is refused by name, and `/skills` says so.

## The reindex task
```
$ mix trinity.skills.reindex                 (dev, 2026-09-21)
reindexed 3 skills in 7 ms
  elixir-project-conventions  bundled/global  v1  active  …/_build/dev/lib/trinity/priv/skills/elixir-project-conventions
  git-workflow  bundled/global  v1  active  …/_build/dev/lib/trinity/priv/skills/git-workflow
  web-research  bundled/global  v1  active  …/_build/dev/lib/trinity/priv/skills/web-research
```
Not under `MIX_ENV=test` (NOTES finding 1).

## Manual verification for the reviewer
- **AC3**: the tagged test's output above, on both backends; or the live edit on the dev server.
- **AC7**: watch `proof/ac7-git-workflow.gif`.
- **AC8**: drop a downloaded skill into `<data dir>/skills` and open `/skills`.

## Deviations from SLICE.md
NOTES.md, the three stated before code (the index cap is 033's 338-token reserve, not 2–3k; "disabled
toolset" read as "no registered tool"; no `embedding` column), and three found building: the index rows
written on the first read rather than at boot (finding 1), watchers dropped rather than restarting the
registry (finding 2), and a compaction test's message shortened for the three new tool schemas (finding 4).

## Versions touched
`VERSIONS.md` updated: yes (yaml_elixir ~> 2.12 and file_system ~> 1.1, both already in the lock as
transitive dependencies). `mix versions.verify`: OK, 102 locked packages, none disagreeing with 53 pins.

## Git
```
$ git log --oneline main..HEAD
(named in the closing correction, after the final commit)
```
