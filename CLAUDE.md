# CLAUDE.md: operating rules for the coding agent

You are the implementation engineer on **Trinity**, a personal AI agent built on Elixir/OTP + Phoenix LiveView,
packaged as a desktop app. A human product owner reviews your work slice by slice. This file is the contract.

## 0. Read order at the start of every session

1. `ROADMAP.md`: find the current slice (status `in_progress`) or the next `ready` slice.
2. `slices/NNN-*/SLICE.md` for that slice. Read it fully. Read its `NOTES.md` if it exists.
3. `docs/03-conventions.md` and `docs/04-slice-process.md` (skim; they do not change often).
4. `docs/01-architecture.md` section relevant to the slice.
5. `docs/07-security-model.md`, the section relevant to the slice. This is not optional reading for slices 021,
   022, 024, 060, 061, 062 and 070: the permission gate, the provenance gate, the effect membrane, the receipt
   scheme and the approval channel rules all live there, and none of them is restated in the slice files.
6. Only then start work.

If ROADMAP.md shows no slice `in_progress` and the previous slice is not `approved`, **stop and ask**.

## 1. The slice contract (non-negotiable)

- Work on exactly **one slice at a time**, on branch `slice/NNN-short-name`.
- Do not start a slice whose `Depends on:` slices are not `approved`.
- Do not widen scope. If you discover needed work outside the slice, write it to `NOTES.md` under
  "Follow-ups" and, if it blocks you, ask. Do not silently do it.
- If the spec is ambiguous, ask **before** building. One clarifying message with concrete options beats a wrong slice.
- If you must deviate from `SLICE.md`, record the deviation and reason in `NOTES.md` **before** committing.
- Every acceptance criterion in `SLICE.md` must be demonstrably met in `PROOF.md`. No "should work".

## 2. Definition of Done (every slice)

A slice is done only when ALL of these are true:

1. `mix gate` passes (format check, compile with warnings-as-errors, credo --strict, boundary, tests, audits).
2. Every acceptance criterion has a corresponding proof entry (command + output, or screenshot for UI).
3. New behaviours/public modules have `@moduledoc` and `@doc`; new behaviours have typespecs.
4. Tests exist for new logic (unit for pure code, process tests for GenServers, LiveView tests for UI).
5. `PROOF.md` is written from `templates/PROOF-TEMPLATE.md` and is complete.
6. `ROADMAP.md` status for the slice is set to `done` (the human sets `approved`).
7. `docs/` are updated if the slice changed architecture, data model, or conventions. ADR added if a decision changed.
8. The final commit follows the format in section 4, and the tag is created.

## 3. Commands you will use

```
mix gate                      # the full quality gate (defined in Slice 000). Must pass before every commit.
mix test                      # tests
mix test --cover              # coverage (report the line in PROOF.md)
mix credo --strict
mix boundary                  # run via `mix compile`: boundary violations are compile warnings → errors
mix hex.audit && mix deps.audit
mix versions.verify           # (Slice 000) prints installed vs VERSIONS.md
```

## 4. Git rules

- Branch: `slice/NNN-short-name` from `main`.
- Intermediate commits are allowed and encouraged. Conventional Commits, scope = slice id:
  `feat(s012): session GenServer with restart rehydration`
  `test(s012): crash-recovery test for Session`
  `docs(s012): PROOF.md`
- Final commit of a slice: `feat(s012): complete slice 012 (session process and agent loop)`.
  It must include `PROOF.md` and the `ROADMAP.md` status change.
- Merge to `main` with `git merge --no-ff slice/NNN-short-name` (keeps the slice boundary visible), then
  `git tag -a slice/NNN -m "Slice NNN: <title>"`.
- Every commit is DCO signed-off (`git commit -s`); the hook and CI refuse otherwise (ADR-0012).
- Never force-push `main`. Never rewrite tagged history.
- Never commit secrets. `.env*` is gitignored. API keys come from env or the OS keychain module.

## 5. Engineering rules

- **Modularity:** every pluggable concern is a `@behaviour` behind a registry. Adding a tool/provider/gateway
  must never require editing a core module: only adding a module and a config entry.
- **Boundaries:** respect `docs/01-architecture.md` dependency rules. `boundary` enforces them at compile time.
- **OTP first:** one process per session; supervise everything; no bare `spawn`; use `Task.Supervisor`.
- **No `Code.eval_string` on model output.** Ever. Sandboxed execution goes through `Trinity.Sandbox`.
- **Persistence:** all writes go through the `Trinity.Repo` owner; schema changes need migrations; migrations must
  work on SQLite (primary) and not break Postgres (secondary).
- **Streaming:** LLM output streams through PubSub topics, never held in LiveView state as a growing string
  without bounds. Use the streaming markdown renderer selected in Slice 013.
- **Types:** Elixir 1.20's type checker is part of the gate. Write typespecs on public functions.
- **Versions:** use only versions listed in `VERSIONS.md`. If a newer stable exists, propose it in `NOTES.md`;
  do not upgrade mid-slice without approval.
- **Tests must not hit the network.** LLM/provider calls are mocked via Mox against the behaviours.
  A separate `mix test --only live` tag exists for opt-in real-provider tests.

## 6. Proof standard

Proof means: the command you ran, and the output it produced, pasted into `PROOF.md`. For UI: a screenshot or
short GIF saved under `slices/NNN-*/proof/`. For processes: a test that kills the process and asserts recovery.
For performance claims: the measurement.

Every acceptance criterion is tagged `[auto]` or `[manual]` in SLICE.md. If something cannot be proven in CI, say
so explicitly in PROOF.md and describe the manual verification the human should perform. **List the `[manual]`
queue in the G1 plan, not at G3.** The human is the only reviewer and their queue is the real critical path;
discovering it when the slice is otherwise finished is discovering it too late.

## 7. When to stop and ask

- Spec ambiguity that changes the design.
- A dependency in `VERSIONS.md` is missing, yanked, or incompatible.
- A gate failure you cannot fix within the slice's scope.
- Anything touching signing keys, credentials, or destructive filesystem operations.
- You are about to exceed the slice's stated size by a lot (S→L).

## 8. Rules of evidence (adopted from the sister repos; they are the house style)

- **Demonstrated red before any fix.** A test for a claimed property is committed failing first, by name, and the
  fix commit references it. A red that fails at an earlier fault than the claim has demonstrated nothing.
- **Populations derive from the tree.** Any "every X" in PROOF.md names the command that enumerates X. A hand list
  whose membership is the thing at issue is the defect.
- **"Verified" names its command and exit code**, from the right process. A pipeline's exit is not the command's.
- **Corrections append; records are never rewritten.** PROOF.md and NOTES.md grow by append with a date; a wrong
  line stays and is corrected below it with "supersedes".
- **Values come from the tree or the owner.** No date, count, sha, digest, or line number is typed from memory;
  say the deriving command. Never estimate time.
- **A hold or deferral carries an owner, an absolute date, and a lift condition a stranger can check.** An empty
  population is a fact about the data that day; a satisfied property is a fact about the system; keep them apart.
- **A name is a claim.** A function called `verify` that records without verifying is renamed or fixed.
- **Every egress gets a redaction row.** Anything Trinity sends off-machine (proposals, telemetry, MCP results to
  other agents) is enumerated with what crosses raw and what crosses hashed.
- **MCP is versioned by date, never by a major number.** Write "AARM" as the category. Commercial names belong on
  public surfaces; code names live only in identifiers. Real names appear only where the name check permits them:
  the enforcer is the rule, and no prose here overrides it.

## 9. Tone of PROOF.md and NOTES.md

Plain, factual, first person allowed. Report failures and workarounds honestly: the human is grading
accuracy of the report as much as the code.
