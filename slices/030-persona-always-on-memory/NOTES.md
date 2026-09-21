# Slice 030: NOTES

## Measured 2026-09-20 before any code: the tier budgets

SLICE.md's per-tier token budgets (stable 800, context 300, volatile 200 to 500) are "starting values to be
replaced by measurement at G1". Measured with the tree's own estimator (`Trinity.Memory.Tokens.estimate/1`,
bytes over three, calibrated high at slice 023) over the default SOUL written this slice
(`priv/personas/default/SOUL.md`, 1,391 bytes) and the untrusted rule the prompt already carries (255 bytes):

| tier | what it holds | measured | budget set |
|---|---|---|---|
| stable | the SOUL and the tool guidance (the untrusted rule) | 464 + 85 = 549 tokens | **800** (the starting value holds: the default SOUL fits with room for a persona's own) |
| context | the skills index placeholder (040 fills it) | 0 today | **300** (unchanged; nothing to measure until 040) |
| volatile | the memory snapshot, the time, the session facts | the 8 KB byte budget is 2,731 tokens by this estimator | **2,800** |

The volatile starting value (200 to 500) would clip a memory tier the byte budget allows, so the two budgets
would fight: consolidation keeps the tier under 8 KB, and the token cap at 2,800 is the backstop above it, so
a truncation receipt in the volatile tier means the estimator and the byte budget disagree, which is worth a
receipt. All three are configuration (`config :trinity, :prompt_budgets`), not code, per the amendment.

## G1 plan, 2026-09-20

Tree at `df4b567` on `main` (031 approved); branch `slice/030-persona-always-on-memory`; ROADMAP row 030 to
`in_progress` in this commit. Each line names its test.

1. Migrations: `memories` (docs/05: `tier`, `scope`, `key`, `body`, `source_message_id`, `confidence`,
   `last_used_at`, plus `persona_id` for the budget; unique `(tier, scope, key)`), `memory_changes` (the log:
   `action` add/replace/remove/promote/consolidate, `tier`, `scope`, `key`, `before`, `after`, `by`, `session_id`,
   `proposal_id`) and `memory_proposals` (a consolidation the budget could not apply: `persona_id`, `entries`,
   `bytes_before`, `bytes_after`, `status` pending/applied/rejected). Test: the unique key; the log grows with
   every write.
2. `Trinity.Personas` (a context over the `Sessions.Persona` schema, which stays where 010 put it: deviation a):
   `list/0`, `get/1`, `create/1`, `update/2`, `seed_default/0` reading `priv/personas/default/SOUL.md` into the
   default persona when its soul is empty, and the default persona's `settings["permissions"]["memory"]` set to
   `"allow"` (the persona-level rule). `Sessions.default_persona/0` calls it. Test AC1: a fresh database seeds the
   default persona with the file's soul and a session's system prompt starts with it.
3. `Trinity.Memory.AlwaysOn`: `snapshot(session_id | {persona_id, session_id})` renders the deterministic block
   (tier, then key, sorted; `profile` first, then `always_on`) over the session's scope chain
   `[session:<id>, persona:<id>, global]`; `write/1`, `replace/1`, `remove/1`, `promote/2`, `list/1`, every
   change a `memory_changes` row. `Trinity.Memory.Budget`: bytes of profile + always_on per persona against
   `config :trinity, :memory, budget_bytes: 8_192`. Tests: the snapshot's order and determinism; AC7 (a
   session-scoped memory in A is absent from B's snapshot; promoted to the persona scope it is present, and the
   promotion is an effect receipt).
4. `Trinity.Memory.Consolidator`: over budget after a write, the LLM (`generate_object/3`) is given the entries and
   asked for a smaller set under the budget; applied at once when under budget (every removal and change
   logged with the proposal id), else a pending `memory_proposals` row for review. Test AC3 with the fake
   provider's scripted object: totals under budget after, every dropped key in the log, and the over-budget
   answer queued rather than applied.
5. The `memory` tool (`Trinity.Tools.Memory`, risk `:write`, effect `:artifact`): `action` add/replace/remove/
   promote/list, `tier`, `key`, `body`, `scope` (default `persona`; `session` for this session only). Through the
   membrane like any artifact effect; allowed by the persona rule without asking. Test AC2 (add, then the next
   session's prompt carries it) and AC6 (the decision receipt names the basis `persona`: `Permissions.Policy`
   gains an optional `decide_with_basis/4`, which `Layered` implements and the runner records).
6. `Prompt.build/4` takes the frozen snapshot from the Session's state (computed at start and on
   `Session.refresh_memory/1`) and orders the system prompt stable → context → volatile, each tier cut at its
   token budget with a query receipt naming the tier and the tokens dropped (the Session writes it, Sessions
   gains the Receipts edge: deviation b). Tests: the order; a snapshot edited mid-session does not change the
   prompt until refresh; a truncation writes its receipt; AC4 (two personas, two concurrent sessions, prompts
   differ).
7. UI: `/personas` (list, picker on new session) and `/personas/:id` (SOUL editor, model, quick settings);
   `/memory` (profile and always-on lists with inline edit and delete, the pending proposals with apply and
   reject). LiveView tests; screenshots for AC5.
8. docs/05 synced (the three tables as built); docs/01's Sessions row gains Receipts.

Manual verification queue (one item, for the owner at G4):
- **AC5**: edit the SOUL, add and delete memory entries, and see them persist. Screenshots under `proof/`
  from the test registry server; the owner repeats on their own build if they wish.

Deviations stated before any code: (a) the persona schema stays `Trinity.Sessions.Persona`; `Trinity.Personas`
is the context over it (moving the schema touches every slice since 010 for no gain); (b) the truncation
receipt is written by the Session, so Sessions depends on Receipts (docs/01's row is updated as built); (c) the
`memory` tool's default scope is the persona's, so AC2's three-argument add is visible to the next session, and
AC7 uses the explicit `session` scope and `promote`; (d) the volatile budget is 2,800 tokens, not 200 to 500,
for the reason measured above.
