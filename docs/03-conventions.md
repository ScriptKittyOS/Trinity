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

### The policy

Stated as a policy rather than left as a habit, because a habit cannot be pointed at in a review.

1. **Major new functionality is accompanied by tests for it in the automated suite, in the same
   change.** Not afterwards, not in a follow-up. A change that adds behaviour and no test for that
   behaviour is incomplete, and the reviewer's question is "which test fails if this is reverted?"
2. **A fixed bug gets a regression test naming the defect**, so the same defect cannot return
   silently. The test is committed failing first, by name, and the fix commit refers to it.
3. **A claimed property has a test that could fail.** A test that passes whatever the code does
   proves nothing; where it is not obvious that a test discriminates, it is demonstrated red once
   and the output recorded.
4. **The population comes from the tree.** Any claim about "every X" is tested against a list the
   command produces, not against a list someone typed.

The gate enforces what can be enforced mechanically: the suite runs on every commit and every push,
and the coverage floor in `coverage.tsv` refuses a drop. The rest is enforced in review, and this
section is what review points at.

### The practice

- Unit tests for pure modules; process tests for GenServers/gen_statem (start under a test supervisor, send
  messages, assert state via public API, not `:sys.get_state` except in recovery tests).
- LiveView tests use `Phoenix.LiveViewTest`; prefer `element/3` with text filters.
- All external I/O behind behaviours, mocked with Mox. `test/support/mocks.ex` defines them.
- Tagged tests: `@tag :live` (real providers, opt-in), `@tag :desktop` (needs Tauri), `@tag :slow`.
  Default `mix test` excludes `:live` and `:desktop`.
- Every crash-safety claim has a test that actually kills a process.
- Coverage: written to `coverage.tsv` in the repository root, one row per increment,
  so there is a baseline to compare against. The gate reads that file: a drop of more than 3 points against the
  previous increment fails until a justification names the reason. The rule as originally written stored no
  baseline, so nothing could check it, which is the pattern the rules of evidence forbid.

## Tools (slice 020)

- A tool is a module implementing `Trinity.Tools.Tool` (`name/0`, `description/0`, `schema/0` as a JSON Schema
  map with string keys, `risk/0`, `effect/0`, `execute/2`, optional `timeout/0` and `format_result/1`) plus one
  line in `config :trinity, :tools` (`modules:`; `toolsets:` groups names). No core module changes; the
  registry test asserts `git grep TestTools lib/` finds nothing.
- Tool modules are stateless. A runtime with state (a shell, a browser) is a child of `Trinity.Tools.Supervisor`
  the tool looks up.
- `effect/0` is `:none` (a read), `:artifact` (a local write) or `:catalog` (an external effect). A `:catalog`
  tool is listed in `Trinity.Effects.Catalog`'s module attribute or it does not start; nothing registered at
  runtime may claim it. A runtime tool's name is namespaced (`mcp:<server>:<tool>`, `skill:<name>`); core
  names are reserved; the tier map in `Trinity.Permissions` is code and lists core names only.
- A tool returns `{:ok, %Trinity.Tools.Result{}}` or `{:error, reason}`; the runner caps the content at
  `result_cap_bytes` (64 KB) with a marker. Arguments arrive validated; a tool never repairs them either.

## UI (decided at slice 013)

- Tokens live in `assets/css/app.css` and nothing else names a colour, a radius or a font: two daisyUI themes
  (`dark`, the default; `light`) carry the palette as `base-100/200/300`, `primary` (teal), `secondary` (violet),
  `accent` (amber) and the four status colours; a Tailwind `@theme` block carries the font stack (`font-sans`,
  `font-mono`), the two chat text sizes (`text-ui`, `text-meta`) and the radii (`rounded-panel`, `rounded-field`,
  `rounded-pill`). A later surface uses these classes; it does not add a hex value.
- The component vocabulary is `TrinityWeb.ChatComponents`: `message`, `tool_card`, `draft`, `composer`,
  `model_picker`, `status_pill`, `banner`, `local_time`. The approval card (021), memory panel (030), skills list
  (040), tasks (050), gateways (070), activity and cost (090) and settings (100) extend this module or add a
  sibling with the same tokens; none restyles a bubble.
- Every page renders inside `Layouts.app` (a 3 rem top bar with the brand, the page's `:bar` slot and the theme
  toggle, over a main region that fills the viewport). Times are rendered as UTC by the server and rewritten in
  the viewer's zone by the `LocalTime` hook.
- Model output reaches the DOM through `TrinityWeb.Markdown.to_html/2` and no other path; `raw/1` appears once in
  the tree, there.
- Every browser response carries the Content-Security-Policy `TrinityWeb.Plugs.ContentSecurityPolicy` sets; an
  inline script needs the request's nonce (`@csp_nonce`), and there is one, the theme script in the root layout.
- The chat runs without a key in development: `TRINITY_FAKE_PROVIDER=1 mix phx.server`.

## Engineering rules

These are enforced by the gate where a tool can enforce them, and by review where none can.

- **Modularity.** Every pluggable concern is a `@behaviour` behind a registry. Adding a tool, a
  model provider or a gateway is a new module and a configuration entry, never an edit to a core
  module.
- **Boundaries.** The dependency rules in `docs/01-architecture.md` are compiled, not advisory:
  `boundary` reports a violation as a warning and the gate compiles with warnings as errors, so an
  architectural violation fails the build. This is what makes the layering in that document a
  property of the tree rather than a diagram.
- **OTP first.** One process per session; everything supervised; no bare `spawn`; work that can
  fail runs under a `Task.Supervisor`.
- **No runtime evaluation of model output.** `Code.eval_string` and its family are never applied to
  anything a model produced. A custom Credo check (`credo_checks/no_eval_on_model_output.ex`)
  enforces it over the whole tree. Sandboxed execution goes through `Trinity.Sandbox`.
- **Persistence.** All writes go through the repository owner; schema changes need migrations, and
  a migration must work on SQLite (primary) without breaking PostgreSQL (secondary).
- **Streaming.** Model output streams over PubSub topics and is never accumulated unbounded in a
  LiveView's state.
- **Types.** Elixir's type checker is part of the gate; public functions carry typespecs.
- **Dependency versions** come from `VERSIONS.md`. A newer release is proposed and reviewed, never
  adopted silently.
- **Tests do not reach the network.** Provider calls are mocked against behaviours; an opt-in
  tag exists for tests that deliberately exercise a real provider.

## Code review

What a reviewer does, what they check, and what makes a change acceptable. Written down because a
review standard that lives in one person's head is not a standard, and because the first question
a reviewer of *this project* will ask is how its own changes are reviewed.

### How review is conducted

Every change reaches `main` through a pull request against a protected branch, with the full gate
green. There is no direct push and no exception for a one-line fix; a change small enough not to
need review is small enough not to need an exception.

A pull request states what it changes and what it proves. The body carries the evidence: commands
and their output, or named tests and their results. A reviewer who has to run the change to find
out what it does is being asked to do the author's work.

The reviewer is someone other than the author wherever the maintainer list allows it. Where it
does not, the change is still gated on the full build, and the project says plainly in
`docs/06-risk-register.md` (R22) that this is a gap rather than pretending the gate substitutes
for a second pair of eyes.

### What must be checked

A reviewer is responsible for forming an opinion on each of these, not for confirming that a tool
ran:

1. **Is the change worth making?** Scope first. A change that does something nobody asked for is
   rejected however well it is written, and anything found outside the stated scope belongs in a
   follow-up rather than folded in quietly.
2. **Does the evidence support the claim?** Every "verified" names its command and its exit code.
   A summary of output is not output. Where a test is claimed to prove a property, the reviewer
   asks which test fails if the change is reverted, and whether that test could fail at all.
3. **Is the security argument still true?** If the change touches an effect, a permission, a
   boundary, a token, a key or anything crossing a trust boundary, the reviewer checks it against
   `docs/07-security-model.md` and `docs/10-assurance-case.md`, and rejects a change that makes a
   statement in either of those documents false without correcting it.
4. **Does it fail safe?** A new default that permits, a new path that skips the gate, an error
   handler that repairs malformed input instead of refusing it: each of these is a defect even
   when every test passes.
5. **Is untrusted content still treated as untrusted?** Anything that moves content toward the
   model, the prompt or an effect is checked for whether it preserves origin and taint.
6. **Do the records stay honest?** Corrections append; a document is not rewritten to look as
   though it had always been right. A commit message that describes changes the commit does not
   make, or omits changes it does make, is sent back.
7. **Is what is *not* done stated?** A change that leaves a gap and says so is acceptable. One that
   leaves a gap silently is not.

### What makes a change acceptable

All of the following, together:

- the gate is green, on the change as it will land rather than on an earlier version of it;
- the evidence in the pull request is reproducible by the reviewer from what is written there;
- major new functionality has tests in the same change, and a fixed defect has a regression test
  naming it;
- documents affected by the change are updated in the same change, including the risk register and
  the assurance case when the change touches what they claim;
- nothing in the change is outside its stated scope;
- the reviewer can say what the change does without reading the diff twice.

A change failing any of these is returned with the reason. "Looks fine" is not a review, and
approving something a reviewer has not understood is worse than declining to review it.

## Rules of evidence

The standard a change is held to, and the reason the proof sections of this repository can be
checked by a stranger.

- **A failing test comes before the fix.** A test for a claimed property is committed failing
  first, by name, and the fix references it. A failure that occurs at an earlier fault than the
  claim has demonstrated nothing.
- **Populations come from the tree.** Any statement of the form "every X" names the command that
  enumerates X. A hand-written list whose membership is the thing in question is the defect.
- **"Verified" names its command and its exit code**, from the process that ran it. A pipeline's
  exit status is not the command's.
- **Corrections append.** Records grow by dated append; a wrong line stays and is corrected below
  it. Nothing is rewritten to look as though it was always right.
- **Values come from the tree or from a person.** No date, count, commit hash, digest or line
  number is written from memory; the deriving command is named.
- **A deferral carries an owner, an absolute date and a lift condition** a stranger can check.
- **A name is a claim.** A function called `verify` that records without verifying is renamed or
  fixed.
- **Every egress is enumerated.** Anything the system sends off the machine is listed with what
  crosses in the clear and what crosses hashed.

## Git

- `main` is always green (gate passes) and always releasable.
- Branch per slice: `slice/NNN-short-name`. Delete after merge.
- Conventional Commits with the slice id as scope: `feat(s022): …`, `fix(s022): …`, `test(s022): …`, `docs(s022): …`,
  `chore(s000): …`, `refactor(s012): …`.
- Final slice commit message: `feat(sNNN): complete slice NNN (<title>)`.
- Merge: a pull request, merge-commit method only, `gate` green on the branch head (repository ruleset, no
  bypass). Tag: `slice/NNN` (annotated), pushed after the merge; tags are protected against update and
  deletion. Never rebase or force-push `main`; the ruleset refuses it anyway.
- **The merge commit is signed off too.** GitHub writes it, so the sign-off goes in the body given to
  `gh pr merge --merge --subject "Merge slice/NNN-…" --body "…Signed-off-by: Name <email>"`. Merging with a
  subject alone produced an unsigned commit under a protected tag once (slice 013, `3db7a5f`), which
  `scripts/plan_check.sh` rule 8 now names as its one exemption. Check `git log -1 --format=%B` on `main`
  before tagging; a tag cannot be moved.
- `mix.lock` is committed. Dependency changes are their own commit: `chore(sNNN): add req_llm ~> 1.10`.

## Definition of Done

Gate green, every acceptance criterion proven, tests present, docs updated,
the engineering record written, and the change tagged.

## Proof standard

Each acceptance criterion of a change gets:
- the command(s) run,
- the relevant output (trim long output; keep the lines that prove the point),
- for UI: a screenshot or short GIF held with the change's engineering record,
- for process/crash behaviour: the test name and its output.
Plus: `mix gate` output, `mix test --cover` summary line, `git log --oneline main..HEAD`.

## ADRs

Any decision that changes architecture, stack, data model, or process gets an ADR in `docs/adr/` using
a consistent template, numbered sequentially, status `proposed` / `accepted` / `superseded by ADR-XXXX`. `proposed` is a real state: ADR-0004, 0007 and 0009 each wait on a measurement from a named slice.

## Documentation hygiene

- `docs/01-architecture.md` supervision tree and context table are updated in the slice that changes them.
- `docs/05-data-model.md` is updated in the slice that adds a migration.
- `VERSIONS.md` is updated in the slice that adds/updates a dependency.

## Properties, and when to write one instead of an example (Slice 004)

An example test states that one input gives one answer. A property states that a rule holds over a
space of inputs, and `stream_data` generates from that space and shrinks any failure to the smallest
case that still fails.

**Write a property when the code answers "is this the same thing".** Canonicalisers, digests,
fingerprints, parsers and validators are all of this shape, and they are wrong in two ways an
example rarely reaches: saying *different* about two spellings of one value, and saying *same* about
two different values. An example test picks the spellings somebody thought of, which is exactly the
set an attacker will not use.

**Write a property when the rule is about an order or a combination.** The tighten-only state
modifier has to hold for every subset of states in every order; asserting that by example means
asserting it for the orders someone listed.

**Keep the example tests.** They document intent and they name the case that mattered. A property
saying "no two definitions collide" does not tell a reader that the description is in the digest on
purpose. Slices 028 and 029 have both, and the properties in `test/property` complement those rather
than replacing them.

**A property that has never failed proves less than it looks.** `test/property/finds_what_examples_miss_test.exs`
plants the classic canonicaliser defect, concatenating fields with no separator, and shows the
example-style assertions passing on it while a generated search finds a collision. Anything added to
`test/property` should be able to say what it would have caught.

**Running wider.** The gate runs 100 cases per property so that it stays fast enough that nobody
skips it. Before trusting a property, run it wider:

```
TRINITY_PROPERTY_RUNS=20000 mix test test/property --timeout 900000
```

The `--timeout` is not optional at that width. ExUnit's per-test limit is 60 seconds and a property
is one test however many cases it runs, so a wide run without it fails with `TimeoutError`, which in
the summary looks exactly like a property violation and is not one. Measured while writing this:
20,000 runs of the validator properties take about 356 seconds.

ExUnit prints the seed and `stream_data` shrinks a failure to a minimal case, so a counter-example
found at any width is reproducible.
