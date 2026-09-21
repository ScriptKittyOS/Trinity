# Slice 041: NOTES

## Read before code, 2026-09-21

The pieces this slice joins are all built: 021's `Trinity.Permissions` (a request is a row and a broadcast,
a decision writes the grant or rule it implies), 024's receipts (`Trinity.Receipts.append/2` on a chain scope),
040's registry (the filesystem canonical, the `skills` rows an index, the user root
`<data dir>/skills`), the effects census pattern (024 AC1: `git ls-files` grepped, a planted bypass in
`test/support` that must be found). docs/07's Skills section: agent-authored skills land in
`pending_approval` with a diff and rationale; the scanner's list; hub skills default to disabled (hub install
is out of this slice).

No new dependency: the unified diff is a small line-based LCS of Trinity's own (`Trinity.Skills.Diff`), since no
Hex package for it is in VERSIONS.md and the need is one function.

## G1 plan, 2026-09-21

Tree at `0f46141` on `main` (040 approved); branch `slice/041-skill-self-management`; ROADMAP row 041 to
`in_progress` in this commit. Each line names its test.

1. Migration `skill_changes` (docs/05): `skill_name`, `action` (`create | patch | write_file | remove_file |
   delete`), `source` (the target root: `user`), `change_dir`, `diff` (text), `rationale`, `destructive`
   (a whole-file replace or a delete), `digest` (SHA-256 over the staged tree's paths and bytes), `status`
   (`pending | approved | rejected | applied | failed`), `severity` (`none | low | medium | high`), `findings`
   (the scanner's), `proposed_by` (session id), `approval_id`, `decided_by`, `decided_at`, `comment`,
   `receipt_hash`, `applied_version`.
2. `Trinity.Skills.Staging` (the proposer): every action writes the whole target tree as it would be after
   the change into `<data dir>/pending/skills/<name>/<change id>/` (a copy of the current skill directory
   with the change applied; `delete` an empty tree with a marker), never anywhere else; `Trinity.Skills.Diff`
   renders a unified diff per changed text file, and a non-text or oversized file is "replaced, N bytes"
   (SLICE risk); the scanner runs on the pending tree; the row is written. Tests AC1 (a `create` is a row and
   staged files, and `Trinity.Skills.list/0` does not show it: the pending directory is outside the roots) and
   the proposer census half of AC8 (the only `File` writes under `lib/trinity/skills/` outside promotion are
   `Staging`'s, and all of them target the pending directory; a planted write in `test/support` is flagged).
3. `Trinity.Skills.Promotion` (the one apply path): `swap/3` takes the change, an approval id and the
   deciding party; verifies the approval row (decided, not denied, tool `skill_apply`, its arguments naming
   this change's id and digest), recomputes the pending tree's digest, archives the current directory to
   `<data dir>/skills/.history/<name>/v<version>/`, moves the pending tree into place (a rename, atomic per
   directory), rescans the registry, writes an `effect` receipt on the `skills` chain scope carrying the change's
   digest and the approval id, and marks the row `applied` with the version. Tests AC2 (approve a create: files
   in the user root, listed, version 1), AC3 (a patch: the diff; approve: version 2 and `.history/…/v1`; reject:
   nothing changed), AC8 (the census: exactly one caller of `Promotion.swap/3` in the tree, plus the planted
   one in `test/support`; `swap/3` refuses a missing, pending, denied or mismatched approval by name).
4. The approval: `Trinity.Skills.Manager.approve(change, opts)` requests a `skill_apply` approval through
   `Trinity.Permissions.request_approval/4` (risk `:write`, the change id and digest as its arguments, so the
   fingerprint binds them and gateways see it on `approvals:all`), decides it (`:once`, `by:` the deciding
   party), and calls `Promotion.swap/3`; `reject/2` marks the row and removes the staged files.
   Auto-approval: `persona.settings["skills"]["auto_approve"]` (`"off"` by default, `"low"` to allow) applies
   a change whose severity is `none` or `low` at once with `decided_by: "auto"`; `high` (and `medium`) never.
   Tests AC4 (a proposal with `curl … | sh` and an API-key-looking string is `high`; auto-approval enabled and
   refused) and AC5 (the registry and the gate restarted between staging and approval; the row and the files
   survive; approval applies).
5. `Trinity.Skills.Scanner`: every text file of a pending tree against the heuristics (shell pipes to a
   shell and destructive commands: high; credential shapes: high; instructions to ignore or disable: high;
   plain shell commands, network calls and external URLs: medium; base64 blobs: medium); a file skipped
   (binary, over 256 KB, not UTF-8) is a low finding naming it and why. Findings carry file, line, rule,
   severity, the matched text truncated. Tests per rule and for the exclusion.
6. The `skill_manage` tool (`Trinity.Skills.Tools.Manage`, risk `:write`, effect `:artifact`; actions and
   arguments validated by its schema) stages and answers with the change id, the severity and "awaiting
   approval on /skills". The `learn` tool (`Trinity.Skills.Tools.Learn`, risk `:write`, effect `:artifact`):
   a source (a file under the session's roots through `Trinity.Tools.FS.Read`, a URL through
   `Trinity.Tools.Web.Fetch`, or pasted text) distilled by the session's model (`generate_object/3`) into a
   SKILL.md and a `references/` file, then staged as a `create`. Tests through the runner with the fake
   provider (the object scripted); the manual GIF and the sample skill for AC6 on the real model.
7. `/skills` gains the pending changes: the list with severity, a diff view, the findings, approve and reject
   with a comment; the learn form. LiveView tests; screenshots for AC7.
8. docs/07 (the section as built), docs/05, docs/01. Manual queue: AC6 (the learned skill's SKILL.md and
   reference in `proof/`, under 200 lines), AC7 (the three screenshots).

Manual verification queue (two items, for the owner at G4):
- **AC6**: `/learn` on a local markdown file: the staged skill's `SKILL.md` and `references/` file in
  `proof/learned/`, the line count named.
- **AC7**: `proof/ac7-*.png`: the pending list, the diff, the findings.

Decisions stated before code: (a) the proposer is `Trinity.Skills.Staging` and it writes under
`<data dir>/pending/skills` only; the apply path is `Trinity.Skills.Promotion.swap/3` and nothing else moves
files into a root (AC8, the census); (b) `skill_manage` and `learn` are `:write` tools like `fs_write`: under
the default policy the staging call itself asks (an approval to propose), and the staged change asks again
to apply; an "always allow" on `skill_manage` makes proposing free while the promotion stays gated, which
is the point of staging; (c) the promotion's receipt is written on a `skills` chain scope, not a session's,
because a change may be approved from a page with no session and outlives the session that proposed it;
(d) "medium" severity is neither auto-approved nor blocked from a human's approval; only `high` is named on
the card as blocking auto-approval; (e) cross-scope promotion (project to global) is not built: the target
root is always the user root, and a project skill's edit stages against the user root under the same name
(the platform alignment's second approval waits for a slice that has two targets).

## Findings at G3, 2026-09-21

1. **An approval needs no session.** 021's `approvals.session_id` was NOT NULL and its changeset required
   it; a staged change approved from the page has no session, and the platform alignment wants the promotion
   to go through `Trinity.Permissions` all the same. Migration `20260921161000` drops the constraint (Postgres
   in place; SQLite by rebuilding the table with the same columns, foreign key and indexes, rows copied), the
   changeset no longer requires it, and `Permissions.topic(nil)` is `approvals:none` (the scope was already
   `session:none`). A gateway (070) listening on `approvals:all` sees these like any other.
2. **The comment did not persist.** The manager set the decider's comment on the struct before the
   promotion, and `Change.changeset/2` saw no change against its own data: the row stayed `nil` while the
   returned struct said otherwise, which the staging test's assertion on the struct did not catch and the page
   test's reload did. `Promotion.swap/4` takes the comment as an argument now; the staging test reloads.
3. **The learn cannot run inside `handle_event/3`.** nemotron-3.5 took 151 s to distil `docs/backup.md`;
   a view blocked that long misses its heartbeats, the client reconnects, the view dies and its in-flight
   call with it (the first run's row appeared only because the call finished before the socket gave up).
   The learn is the view's `start_async` task now, with a "learning from …" line and the flash on completion;
   the page test waits with `render_async`.
4. **The model's first answer was one run-on line** (two spaces where its line breaks should have been, and
   a stray `, category:` on the end). The prompt now asks for real line breaks in `body` and `reference` and
   names the shape (a heading, numbered steps, a blank line between paragraphs), and `Learn` unflattens an
   answer without a newline at its headings, steps and bullets. The second run answered a 32-line SKILL.md
   and a 16-line reference (`proof/learned/`).
5. **A skills page edit lost its 040 clauses.** Inserting the learn handler cut the `view`, `close`,
   `set_status` and `reindex` clauses; the gate's page test caught it (a `FunctionClauseError` on "view").
   Restored from the previous commit; noted because the failure mode (a text edit dropping neighbouring
   code) is one a reviewer should know the tests cover.
6. **The compaction test sized itself.** Two more tool schemas moved the retry past the hard threshold
   again (as 040's three had); the crossing message is now computed from the registered tool surface and the
   window, so a tool added later does not turn a compaction into a fork in that test.
7. **The secret scan reads test fixtures.** The scanner's own tests carried an AWS key shape and a private
   key header as literals; `mix trinity.secrets.scan` flagged them in the gate. The samples are concatenated
   at run time; the scanner still sees the shape.
8. **One pending create per name.** A second `create` of a name with a pending create is `{:pending, name}`;
   other actions may stack (each approval recomputes the digest of its own tree, and a patch staged against
   a version that has since changed still applies as its own whole tree, which is the design's blunt edge:
   the diff shown is against the skill as it was when staged).
9. **The proposing tool asks, then the change asks.** Under the default policy `skill_manage` (a `:write`
   tool) needs an approval to run, and the staged change needs another; the manage test sets an allow rule
   for the tool so it measures the staging. A persona that proposes often wants that rule; the second gate is
   the one that matters.

## Follow-ups

- **Hub installation** (docs/07: scanned, `disabled` until enabled) and the `agent` and `hub:<url>` sources
  of docs/05: not built; a skill dropped by hand into the user root loads unscanned. The scanner runs on
  pending trees only.
- **Cross-scope promotion** (project to global) as a second approval: the target root is always the user
  root here (decision e).
- **A stale patch.** A patch staged against version N and approved after N+1 applies its whole tree over
  N+1 (finding 8); a rebase or a refusal when the base digest moved is the better behaviour.
- **`allowed-tools` as a permission hint** and the persona's auto-approval on the persona page (it is a
  setting today, set through `Trinity.Personas.put_setting/3`, with no control on `/personas/:id`).
