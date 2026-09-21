# Proof for slice 030: Persona (SOUL) + always-on memory tier

Agent: Trinity · Coding Agent · Date: 2026-09-21 · Branch: slice/030-persona-always-on-memory · Final commit: (the commit carrying this file; named in the closing correction)

## Summary
Personas with a SOUL seeded from `priv/personas/default/SOUL.md`, a default model and quick settings; the
always-on tiers (`profile`, `always_on`) as rows with a scope chain (session, persona, global), a change log
every write appends to, a byte budget per persona and a consolidator that asks the model for a smaller set
and applies it under budget or holds it for review; the `memory` tool through the membrane, allowed by the
persona's rule with the basis named in the decision receipt; the prompt in three tiers with token budgets
measured at G1 and a query receipt for every cut; the snapshot frozen in the Session until refresh; the
personas pages, the memory page and the persona picker. Six findings in NOTES.md; four deviations stated at G1,
the one that shapes a criterion being the tool's default scope (deviation c), which AC2 and AC7 both rely on.

## Gate
```
$ mix gate                                   (this machine, OTP 28.5.0.5, Elixir 1.20.4, under a 32 GiB cgroup, tree c657da8)
1588 mods/funs, found no issues.
... SCAN COMPLETE ...
No retired or security advisory packages found
No vulnerabilities found.
Result: 350 passed, 17 excluded
trinity.coverage: 031 76.96% vs 024 76.55%: OK
plan_check: PASS
exit=0
```
CI, run 35549378616 on the tree at c657da8: `gate` success (350 passed, 17 excluded), `postgres` success
(342 passed, 25 excluded), `fips-tag` and `fips` success.

## Tests
```
$ mix test --cover                           (tree c657da8)
Result: 350 passed, 17 excluded
|     97.73% | Trinity.Memory.AlwaysOn                |
|    100.00% | Trinity.Memory.Budget                  |
|     88.00% | Trinity.Memory.Consolidator            |
|     82.98% | Trinity.Tools.Memory                   |
|    100.00% | Trinity.Personas                       |
|     91.94% | Trinity.Sessions.Prompt                |
|     85.45% | TrinityWeb.PersonasLive                |
|     84.52% | TrinityWeb.MemoryLive                  |
|     78.40% | Total                                  |
```
`coverage.tsv` row: `030  78.40  c657da8  2026-09-21` (from 76.96 at 031).

The slice's 24 tests in its four files (`--trace`):
```
* test registered as a core write tool with the artifact effect, in the memory toolset [L#22]
  * test registered as a core write tool with the artifact effect, in the memory toolset (9.7ms) [L#22]
  * test AC6: the write is allowed by the persona's rule without asking, and the decision receipt names the basis (13.4ms) [L#46]
  * test AC2: memory.add(always_on, editor, prefers neovim) leaves a row, and the next session's snapshot carries it (1.9ms) [L#27]
  * test replace, remove, a duplicate key, a bad key, and an action without its arguments (10.1ms) [L#120]
  * test without the persona rule a memory write asks, like any write (2.8ms) [L#65]
  * test AC7: a session-scoped entry is invisible to another session until promoted; the promotion is an effect with receipts (6.9ms) [L#76]
  * test the persona editor saves the soul, the model and the memory rule; the list creates one (77.1ms) [L#19]
  * test a pending consolidation is shown and can be applied or rejected (9.9ms) [L#80]
  * test the memory page adds, edits in place and deletes entries; every change is logged by ui and persists (7.8ms) [L#46]
  * test the index page picks a persona for the next session (8.6ms) [L#130]
  * test the system prompt is stable (soul, tool guidance), then volatile (memory, time, title); the context tier is empty until 040 (2.2ms) [L#14]
  * test AC1 (prompt half): a session of the default persona opens its system prompt with the seeded soul (0.6ms) [L#57]
  * test a tier over its budget is cut on a line boundary and reported with the tokens dropped (0.3ms) [L#40]
  * test the snapshot is frozen at session start: an entry added mid-session is not in the next turn's prompt until refresh; a truncation writes its receipt (21026.6ms) [L#66]
  * test AC4: two personas with different souls run concurrent sessions and their prompts differ (12013.2ms) [L#127]
  * test AC1: a fresh database seeds the default persona from priv/personas/default/SOUL.md with the memory rule; an edited soul is kept (1.7ms) [L#30]

  * test AC3: the budget and the consolidator a model that answers no entries leaves the tiers as they are, over budget, with no proposal (2.4ms) [L#236]
  * test AC7 (data): a session-scoped entry is absent from another session's chain; promoted, it is present (1.6ms) [L#63]
  * test the snapshot: profile before always-on, keys sorted, deterministic, empty when nothing (1.7ms) [L#48]
  * test AC3: the budget and the consolidator a proposal still over budget is held pending and nothing changes; the owner can apply or reject it (3.3ms) [L#175]
  * test writes are logged with before and after; add refuses a duplicate key; keys are validated (1.6ms) [L#86]
  * test AC3: the budget and the consolidator a pending proposal applied by the owner is logged under its id like an automatic one (1.7ms) [L#212]
  * test AC3: the budget and the consolidator over budget after a write, a proposal under budget is applied at once and every dropped key is in the log (2.4ms) [L#134]
  * test bytes count key and body (0.4ms) [L#246]
Result: 24 passed
```

## Acceptance criteria evidence

### AC1 [auto]: new install seeds the default persona; a session uses its SOUL in the system prompt (prompt snapshot test)
`AC1: a fresh database seeds the default persona from priv/personas/default/SOUL.md with the memory rule; an
edited soul is kept` (always_on_test.exs: the row deleted, `default_persona/0` recreates it with the file's soul
and `settings["permissions"]["memory"] == "allow"`; an edited soul survives; a pre-030 row with no soul is
seeded on its next read) and `AC1 (prompt half): a session of the default persona opens its system prompt with
the seeded soul` (prompt_tiers_test.exs: `String.starts_with?(request.system, "# Trinity\n\nYou are Trinity, a
personal agent")`).

### AC2 [auto]: agent calls `memory.add("always_on", "editor", "prefers neovim")` → row exists → next session's prompt contains it (test)
`AC2: memory.add(always_on, editor, prefers neovim) leaves a row, and the next session's snapshot carries it`
(memory_test.exs): the tool through `Trinity.Effects.Runner`, the row at the persona's scope (deviation c),
a new session's snapshot `"## Always in mind\n- editor: prefers neovim"`, and the change logged `by: "tool"` with
the session. The snapshot is what the prompt's volatile tier carries (prompt_tiers_test.exs, the frozen
snapshot test: "- before: known at start" in the request the fake received).

### AC3 [auto]: budget exceeded → Consolidator produces a smaller set; totals ≤ budget; no entry silently dropped without appearing in the consolidation log (test with FakeProvider returning a scripted merge)
always_on_test.exs, the "AC3" block with the budget at 200 bytes: `over budget after a write, a proposal under
budget is applied at once and every dropped key is in the log` (three entries merged to one by the fake's
scripted object; `used <= budget`; the proposal `applied` with `bytes_before > budget` and `bytes_after <=
budget`; the log under the proposal id is exactly add ab, remove a, remove b, remove c, every row `by
"consolidator"`); `a proposal still over budget is held pending and nothing changes; the owner can apply or reject
it`; `a pending proposal applied by the owner is logged under its id like an automatic one`; `a model that answers
no entries leaves the tiers as they are, over budget, with no proposal`.

### AC4 [auto]: two personas with different SOULs run concurrent sessions; prompts differ accordingly (test)
`AC4: two personas with different souls run concurrent sessions and their prompts differ` (prompt_tiers_test.exs):
two sessions alive at once, one turn each, the fake's last request opening with `# Alpha` then `# Beta`, and the
beta persona's profile entry in its prompt alone.

### AC5 [manual]: UI: edit SOUL, add/delete memory entries (screenshots); changes persist
Automatic half (memory_pages_test.exs): `the persona editor saves the soul, the model and the memory rule; the list
creates one`; `the memory page adds, edits in place and deletes entries; every change is logged by ui and
persists` (a fresh mount shows the log and no entry); `a pending consolidation is shown and can be applied or
rejected`; `the index page picks a persona for the next session`. Manual half, for the owner:
`proof/ac5-soul-edited.png` (the SOUL edited and saved on `/personas/<default>`, the "saved" pill, the memory rule
at allow), `proof/ac5-memory-added.png` (`/memory`: the profile entry `name`, two always-on entries added, the
budget `67 / 8192 bytes`, the change log), `proof/ac5-memory-after-delete-reload.png` (`city` deleted, the page
reloaded: one entry left and the removal in the log). The driver then reopened the persona page and read the
edited soul back (`soul persisted: true` in its output).

### AC6 [auto]: memory tool writes appear in the permissions audit as allowed-by-rule (test)
`AC6: the write is allowed by the persona's rule without asking, and the decision receipt names the basis`
(memory_test.exs): no approval row (nothing asked), and the decision receipt's signed body carries
`{"outcome" => "allow", "basis" => "persona", "reason" => nil}`, followed by the admit and done effect receipts.
`without the persona rule a memory write asks, like any write` is the control. The audit is the decision receipt
(slice 024); the `/permissions` page shows requests, of which an allowed-by-rule write makes none.

### AC7 [auto]: a memory written in session A is not retrievable in unrelated session B unless promoted (test)
Data: `AC7 (data): a session-scoped entry is absent from another session's chain; promoted, it is present`
(always_on_test.exs). Through the tool: `AC7: a session-scoped entry is invisible to another session until
promoted; the promotion is an effect with receipts` (memory_test.exs): `scope: "session"` in A, `list` in B
answers "Nothing is kept yet." and `remove` in B is `not_found`; `promote` in A is a decision, admit and done
receipt triple and the entry appears in B's `list`; the change log's newest row is the promotion with its scopes.

## Manual verification for the reviewer
- AC5: open the three screenshots under `proof/`; or `scripts/dev_chat_on_test_registry.sh`'s recipe (the test
  registry, the screenshots database) and open `/personas`, `/personas/<id>` and `/memory`.

## Deviations from SLICE.md
(a) to (d) stated in NOTES.md before code: the persona schema stays in Sessions with `Trinity.Personas` over it;
the truncation receipt is the Session's (Sessions depends on Receipts); the tool's default scope is the persona's;
the volatile budget is 2,800 tokens from the measurement. Found during the build: none beyond NOTES.md's findings.

## Versions touched
`VERSIONS.md` updated: no; no dependency changed.

## Git
```
$ git log --oneline main..HEAD
c657da8 style(s030): the formatter converges once the map is bound before the call
fccfc8b feat(s030): the personas pages, the memory page, the persona picker; docs/05 and docs/01 as built
168fa44 feat(s030): the prompt's tiers with their budgets and the truncation receipt; the frozen snapshot in the Session
00b88bb feat(s030): the memory tool; the decision basis in the receipt
e5a879b feat(s030): memories, the change log and proposals; Personas; AlwaysOn, Budget and the Consolidator
391ef44 docs(s030): G1 plan with the tier budgets measured, the default SOUL, and the slice opens
```
