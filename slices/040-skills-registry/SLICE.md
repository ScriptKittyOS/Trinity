# Slice 040 — Skills registry, SKILL.md format, progressive disclosure

| Field | Value |
|---|---|
| Phase | 4 Skills |
| Milestone | M4 Learns |
| Size | M |
| Depends on | 020 |

## Goal
Skills as directories with `SKILL.md` (agentskills.io format, ADR-0006) discovered from `priv/skills`,
`<data_dir>/skills`, and project `.trinity/skills`; parsed into a DB index; exposed to the agent through three
progressive-disclosure tools (`skills_list`, `skill_view`, `skill_file`); precedence and conditional activation;
hot reload on filesystem change; a skills UI. No agent-authored changes yet (041).

## Why
Vision goal 4. Procedural memory that costs ~nothing until used.

## Scope
**In:**
- `Trinity.Skills.Skill` struct + `Trinity.Skills.Parser` (YAML frontmatter via `yaml_elixir`, body, `references/`, `scripts/` listing); validation with clear errors; Trinity extensions under `trinity:` key (`requires_tools`, `requires_toolsets`, `fallback_for_toolsets`, `risk`, `lua_entry`).
- `Trinity.Skills.Registry` (GenServer + ETS) scanning sources in precedence order project → user → bundled; `FileSystem` watcher for hot reload; `mix trinity.skills.reindex`.
- `skills` table as index (name, version, source, path, frontmatter, body_hash, status, scan_result) — filesystem canonical.
- Tools: `skills_list()` → compact index (name + one-line description, grouped by category; token-capped), `skill_view(name)` → SKILL.md body, `skill_file(name, path)` → reference file (path jailed to the skill dir). All `:read`.
- Prompt: the skills index goes into the context tier with a cap (e.g. 2–3k tokens); over cap → categories only + hint to call `skills_list`.
- Conditional activation: skills whose `requires_tools` are unavailable are hidden; `fallback_for_toolsets` shown only when those toolsets are disabled.
- 3 bundled skills to prove the format (e.g. `git-workflow`, `elixir-project-conventions`, `web-research`).
- UI: `/skills` list with source badges, view, enable/disable, reindex button.
**Out:**
- Agent authoring/approval (041), hub install (follow-up), Lua execution (110).

## Design notes
- Parser must be strict on frontmatter schema but tolerant of unknown keys (forward compat with other agents' skills).
- `skill_file` must resolve symlinks and reject `..`.

## Deliverables
- `lib/trinity/skills/{skill,parser,registry,sources,tools/*}.ex`, `lib/trinity/skills.ex`, migration, watcher config, bundled skills in `priv/skills/`, UI, tests with fixture skill dirs.

## Acceptance criteria
1. [auto] A fixture skill dir is parsed into a `%Skill{}` with correct frontmatter/body/refs; malformed frontmatter → descriptive `{:error, ...}` (tests).
2. [auto] Precedence: same-named skill in project and bundled → project wins (test).
3. [manual] Hot reload: modifying a SKILL.md on disk updates the registry within 2 s without restart (test with watcher; or manual proof if watcher unavailable in CI).
4. [auto] `skills_list` output stays under the cap with 50 fixture skills; `skill_view` returns the body; `skill_file` rejects `../secrets` (tests).
5. [auto] Conditional activation hides a skill requiring a disabled toolset (test).
6. [auto] Prompt snapshot includes the skills index in the context tier (test).
7. [manual] Manual: agent, asked to do a git task, calls `skill_view("git-workflow")` then follows it (GIF).
8. [manual] An agentskills.io skill written for another agent, downloaded by the human, parses and appears (proof: name + source).

## Proof required
- Tests, GIF, external skill parse output.

## Definition of Done
- [ ] gate green · [ ] AC1–8 proven · [ ] docs/05 synced · [ ] ROADMAP → done · [ ] commit + tag

## Commit & tag
`feat(s040): complete slice 040 — skills registry and progressive disclosure` · tag `slice/040`

## Risks / open questions
- `file_system` watcher on Windows/macOS inside a packaged app — verify in 100; reindex button is the fallback.

## Platform alignment (appended 2026-09-05)
- **Content digest:** `skills.body_hash` plus a per-file digest manifest under the skill dir; the
  registry refuses to load a skill whose files do not match its manifest; the scan result is keyed by digest so
  "what was audited is what is loaded" is a check, not a claim.
- **Scope tag (M6):** `scope ∈ {project, account, global}` from the source dir; retrieval enforces it.
- Honour the agentskills.io `allowed-tools` frontmatter as a permission *hint* (never a grant).
