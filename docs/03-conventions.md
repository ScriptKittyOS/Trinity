# 03: Conventions

## Code

- `mix format` with the project `.formatter.exs`. No exceptions.
- `credo --strict` clean. Disable a check only with an inline justification.
- `mix compile --warnings-as-errors`. Elixir 1.20 type warnings are errors.
- `@moduledoc` on every public module (`false` for internal ones), `@doc` + `@spec` on public functions.
- Context modules (`Trinity.Sessions`, `Trinity.Tools`, …) are the only cross-context entry points.
- Behaviours declare `@callback` with specs; implementations use `@impl true`.
- Options validated with `NimbleOptions`; the schema is the documentation.
- Errors: return `{:ok, _} | {:error, %Trinity.Error{}}` from public functions; raise only for programmer errors.
- Logging: `Logger` with metadata `session_id`, `tool`, `provider`; never log secrets or full prompts at `:info`.
- Telemetry events named `[:trinity, <context>, <event>]` with documented measurements/metadata.

## Tests

- Unit tests for pure modules; process tests for GenServers/gen_statem (start under a test supervisor, send
  messages, assert state via public API, not `:sys.get_state` except in recovery tests).
- LiveView tests use `Phoenix.LiveViewTest`; prefer `element/3` with text filters.
- All external I/O behind behaviours, mocked with Mox. `test/support/mocks.ex` defines them.
- Tagged tests: `@tag :live` (real providers, opt-in), `@tag :desktop` (needs Tauri), `@tag :slow`.
  Default `mix test` excludes `:live` and `:desktop`.
- Every crash-safety claim has a test that actually kills a process.
- Coverage: reported in PROOF.md each slice and written to `coverage.tsv` in the repo root, one row per slice,
  so there is a baseline to compare against. The gate reads that file: a drop of more than 3 points against the
  previous slice fails until a NOTES.md justification names the reason. The rule as originally written stored no
  baseline, so nothing could check it, which is the pattern CLAUDE.md §8 forbids.

## Git

- `main` is always green (gate passes) and always releasable.
- Branch per slice: `slice/NNN-short-name`. Delete after merge.
- Conventional Commits with the slice id as scope: `feat(s022): …`, `fix(s022): …`, `test(s022): …`, `docs(s022): …`,
  `chore(s000): …`, `refactor(s012): …`.
- Final slice commit message: `feat(sNNN): complete slice NNN (<title>)`.
- Merge: a pull request, merge-commit method only, `gate` green on the branch head (repository ruleset, no
  bypass). Tag: `slice/NNN` (annotated), pushed after the merge; tags are protected against update and
  deletion. Never rebase or force-push `main`; the ruleset refuses it anyway.
- `mix.lock` is committed. Dependency changes are their own commit: `chore(sNNN): add req_llm ~> 1.10`.

## Definition of Done

See `CLAUDE.md` §2. The short version: gate green, every acceptance criterion proven, tests present, docs updated,
PROOF.md written, ROADMAP updated, final commit + tag.

## Proof standard

`PROOF.md` follows `templates/PROOF-TEMPLATE.md`. Each acceptance criterion gets:
- the command(s) run,
- the relevant output (trim long output; keep the lines that prove the point),
- for UI: a screenshot/GIF path under `slices/NNN-*/proof/`,
- for process/crash behaviour: the test name and its output.
Plus: `mix gate` output, `mix test --cover` summary line, `git log --oneline main..HEAD`.

## ADRs

Any decision that changes architecture, stack, data model, or process gets an ADR in `docs/adr/` using
`templates/ADR-TEMPLATE.md`, numbered sequentially, status `proposed` / `accepted` / `superseded by ADR-XXXX`. `proposed` is a real state: ADR-0004, 0007 and 0009 each wait on a measurement from a named slice.

## Documentation hygiene

- `docs/01-architecture.md` supervision tree and context table are updated in the slice that changes them.
- `docs/05-data-model.md` is updated in the slice that adds a migration.
- `VERSIONS.md` is updated in the slice that adds/updates a dependency.
