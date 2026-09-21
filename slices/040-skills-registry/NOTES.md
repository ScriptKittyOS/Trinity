# Slice 040: NOTES

## Measured 2026-09-21 before any code

**The dependency line.** `yaml_elixir` 2.12.2 (2026-05-30, 27.8 M downloads, over `yamerl` 0.10.0) and
`file_system` 1.1.1 (2025-09-08, 89.6 M downloads) are both in `mix.lock` already as transitive dependencies
(sobelow's and phoenix_live_reload's); this slice declares them directly and adds their VERSIONS rows
(`curl -s https://hex.pm/api/packages/<name>`). `ymlr` (5.1.6) is the writer, not needed: skills are read.

**The format.** agentskills.io's specification, read 2026-09-21 (https://agentskills.io/specification):
`SKILL.md` is YAML frontmatter and a Markdown body. `name` (required: 1 to 64 characters, lowercase
`a-z0-9` and single hyphens, not at either end, and it must match the parent directory's name),
`description` (required, 1 to 1,024 characters), `license`, `compatibility` (1 to 500 characters),
`metadata` (a map of string to string), `allowed-tools` (experimental, a space-separated string). Optional
`scripts/`, `references/`, `assets/` directories. ADR-0006 adds Trinity's keys under `trinity:`.

**The context tier's reserve.** Slice 033 set the context budget at 5,800 tokens: the AGENTS.md cap (16,384
bytes, 5,462 tokens under the estimator) plus 338 tokens it reserved for the skills index. SLICE.md's "e.g.
2–3k tokens" would push AGENTS.md out of its own tier, so the index's cap is the reserve: 338 tokens, and over
the cap the index becomes the category names and a hint to call `skills_list`. Recorded as a deviation.

## G1 plan, 2026-09-21

Tree at `f54e636` on `main` (030 to 034 approved, M3 reached; the README at M3); branch
`slice/040-skills-registry`; ROADMAP row 040 to `in_progress` in this commit. Each line names its test.

1. `Trinity.Skills.Skill` (the struct: name, description, source, scope, path, frontmatter, body, references,
   scripts, body_hash, manifest, status) and `Trinity.Skills.Parser`: the frontmatter through `yaml_elixir`
   (strict on the spec's constraints, tolerant of unknown keys), the `trinity:` extension keys
   (`requires_tools`, `requires_toolsets`, `fallback_for_toolsets`, `risk`, `lua_entry`), the body, the
   `references/` and `scripts/` listings, and a per-file SHA-256 manifest of the directory; every refusal a
   descriptive `{:error, {reason, detail}}`. Tests AC1 with fixture directories under `test/support/fixtures/skills`.
2. `Trinity.Skills.Sources`: the three roots in precedence order, project (`<project_root>/.trinity/skills`),
   user (`<data dir>/skills`), bundled (`priv/skills`), each tagged with its `source` and `scope`
   (`project | account | global`, the M6 tag). `Trinity.Skills.Registry` (GenServer over ETS) scans them,
   resolves same-named skills by precedence, writes the `skills` index table (name, version, source, path,
   frontmatter, body_hash, status, scan_result with the manifest), and refuses a skill whose files do not match
   a manifest it carries (`.trinity-manifest.json`, written by 041's scanner; absent at 040 for every bundled
   and user skill, so nothing is refused yet and the check is a test with a planted mismatch). Hot reload: a
   `FileSystem` watcher per root that exists, debounced, calling `rescan/0`; `mix trinity.skills.reindex`.
   Tests AC2 (precedence) and AC3 (the watcher: a fixture SKILL.md edited on disk is in the registry within
   2 s; tagged so a runner without inotify skips by name, and the manual proof stands beside it).
3. The tools `skills_list` (the index: name and one-line description grouped by category, token-capped),
   `skill_view(name)` (the body) and `skill_file(name, path)` (a file under the skill's directory: the path
   resolved with symlinks followed and refused outside the directory), all `:read`, registered like 031's.
   Conditional activation in the registry's `active/1`: a skill whose `requires_tools` are not registered or
   whose `requires_toolsets` have no registered tool is hidden; `fallback_for_toolsets` shows a skill only
   when those toolsets have no tool. Tests AC4 (50 fixture skills under the cap; the body; `../secrets`
   refused) and AC5.
4. The prompt: `Trinity.Context.skills_index/1` renders the index into the context tier after the AGENTS.md
   block under its 338-token cap (categories only and the hint over it). Test AC6 (the prompt snapshot).
5. Three bundled skills under `priv/skills`: `git-workflow`, `elixir-project-conventions`, `web-research`,
   each a valid SKILL.md with a `references/` file.
6. `/skills`: the list with source and scope badges, view, enable and disable (the `status` column), reindex.
   LiveView tests.
7. docs/05 (the table as built), docs/01 (the registry as built), VERSIONS rows, `docs/07` unchanged (041's
   section stands). Manual queue: AC3 (the GIF or the tagged test's output), AC7 (the agent on a git task
   calling `skill_view("git-workflow")`, a GIF on the real model), AC8 (a skill written for another agent,
   downloaded by the owner, parsed and listed: its name and source in PROOF).

Manual verification queue (three items, for the owner at G4):
- **AC3**: hot reload within 2 s; the tagged test runs where inotify exists (this machine, the gate's runner)
  and PROOF carries its output; the owner may edit a bundled SKILL.md while the dev server runs and reload
  `/skills`.
- **AC7**: the GIF: "commit this with a conventional message" or similar, the agent calls `skill_view`
  on `git-workflow` and follows it.
- **AC8**: an agentskills.io skill from another agent's repository (the owner picks; a public one from the
  agentskills.io showcase is the default), dropped into `<data dir>/skills`, its name and source on `/skills`.

Deviations stated before code: (a) the index's prompt cap is the 338-token reserve slice 033 left in the
context tier, not SLICE.md's "2–3k" (which would push AGENTS.md out of its tier); (b) "disabled toolset" is
read as "a toolset with no registered tool" (the shell on Windows, a toolset removed from configuration):
there is no separate disable switch and this slice adds none; (c) the `skills.embedding` column in docs/05 is
not added: nothing in this slice retrieves skills by vector, and 032's rule (a vector records its embedder)
would apply when one does.
