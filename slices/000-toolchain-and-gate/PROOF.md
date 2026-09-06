# Slice 000 — PROOF

Branch `slice/000-toolchain-and-gate`. Every command below was run on the pinned toolchain, and
every "verified" names its command and its exit code. Where a red was discovered rather than
staged, that is said.

## AC1 [auto] — the toolchain matches the pin file

```
$ cat .tool-versions
erlang 28.5.0.5
elixir 1.20.4-otp-28

$ elixir --version ; echo "exit=$?"
Erlang/OTP 28 [erts-16.4.0.5] [source] [64-bit] [smp:32:32] [ds:32:32:10] [async-threads:1] [jit:ns]

Elixir 1.20.4 (compiled with Erlang/OTP 28)
exit=0

$ erl -noshell -eval 'io:format("~s / erts ~s~n",[erlang:system_info(otp_release), erlang:system_info(version)]), halt().'
28 / erts 16.4.0.5
```

`VERSIONS.md`'s toolchain table carries `28.5.0.5` and `1.20.4-otp-28`.

**The pin file is `.tool-versions`, not `mise.toml`.** Measured before it was written:

```
$ which mise asdf ; echo "exit=$?"
/usr/local/bin/asdf
exit=1
```

`mise` is absent, `asdf` v0.18.0 is present. `SLICE.md` and `VERSIONS.md` were corrected.

## AC2 [auto] — `mix gate` exits 0

```
$ mix gate ; echo "exit=$?"
...
versions.verify: OK — 7 pins satisfied by mix.lock
versions.gen: VERSIONS.md already matches Trinity.Versions
trinity.version_form: OK
trinity.names: OK over 146 tracked files
trinity.secrets.scan: OK over 146 files
trinity.reuse: OK — every commentable tracked file carries an SPDX header
Running ExUnit with seed: 816745, max_cases: 64
................................................
Finished in 0.05 seconds (0.02s async, 0.03s sync)
Result: 48 passed
trinity.coverage: 000 at 27.98% is the FIRST row. It is the baseline and is compared against nothing; the rule is not exercised yet.
exit=0
```

`scripts/plan_check.sh` also passes at this tree: `exit=0`.

## AC3 [auto] — `mix versions.verify`

```
$ mix versions.verify ; echo "exit=$?"
  boundary         pinned ~> 0.10    locked 0.10.4
  credo            pinned ~> 1.7     locked 1.7.19
  mox              pinned ~> 1.2     locked 1.3.1
  mix_audit        pinned ~> 2.1     locked 2.1.5
  sobelow          pinned ~> 0.15    locked 0.15.0
  ex_doc           pinned ~> 0.38    locked 0.40.4
  nimble_options   pinned ~> 1.1     locked 1.1.1
versions.verify: OK — 7 pins satisfied by mix.lock
exit=0
```

**Rows this slice touched, and only those, were updated in `VERSIONS.md`:** the Erlang/OTP and
Elixir rows now carry measured patch versions and the reason, and the `mise / asdf` row is
replaced by an `asdf` row. Rows for dependencies no slice has added yet keep their 🔍 — flipping
those would be claiming a measurement nobody made.

**Deviation, recorded.** `SLICE.md` named `versions.exs`, a data file. The pin list is
`lib/trinity/versions.ex`, a compiled module, because a `.exs` data file must be evaluated at
runtime and the eval-family enforcer forbids that family under `lib/`. Same data, no evaluation,
and the compiler checks it. `mix versions.gen` generates VERSIONS.md's block from it and
`mix versions.gen --check` fails the gate if the two disagree.

## AC4 [auto] — a boundary violation fails the gate

Red, `Trinity` calling into `TrinityWeb` with `deps: []`:

```
$ mix compile --warnings-as-errors --force ; echo "exit=$?"
warning: forbidden reference to TrinityWeb.Endpoint
  (references from Trinity to TrinityWeb are not allowed)
  lib/trinity.ex:21
exit=1

$ mix gate >/dev/null 2>&1 ; echo "exit=$?"
exit=1
```

Green, violation removed:

```
$ mix gate >/dev/null 2>&1 ; echo "exit=$?"
exit=0
```

**The flag is the enforcement, and this was measured, not assumed.** With the same violation
planted and `--warnings-as-errors` dropped:

```
$ mix compile --force ; echo "exit=$?"
warning: forbidden reference to B
  (references from A to B are not allowed)
exit=0
```

`boundary` reports violations as *warnings*. Without the flag the architecture rules in
`docs/01` are advisory and a violation ships silently. `test/gate_alias_test.exs` asserts the
gate's compile step carries the flag; dropping it in a throwaway edit to `mix.exs` fails that
test with `exit=2`, and restoring it passes.

## AC5 [manual] — CI green on the branch

`.github/workflows/gate.yml` runs `mix deps.get`, `scripts/plan_check.sh`, a DCO check and
`mix gate` on ubuntu-latest, with `fetch-depth: 0` because `plan_check` rule 8 reads the whole
history.

**Not verified here, and I cannot verify it.** This is a claim about a run on a remote. The
owner confirms it at G3 by pasting the Actions run status. Retagged `[manual]` for that reason.

## AC6 [auto] — the secret scan

Red, a fake AWS key planted in `lib/planted_key.ex`:

```
$ mix trinity.secrets.scan ; echo "exit=$?"
FAIL lib/planted_key.ex:5: AWS access key id
** (Mix) trinity.secrets.scan: 1 finding(s)
exit=1
```

Green, file removed:

```
$ mix trinity.secrets.scan ; echo "exit=$?"
trinity.secrets.scan: OK over 146 files
exit=0
```

## AC7 [auto] — each of the five enforcers, red and green

**1. Eval family** (`Trinity.Credo.NoEvalOnModelOutput`). `CLAUDE.md` §5 names one function;
one function has an obvious bypass, so the check covers `Code.eval_string`, `eval_quoted`,
`eval_file`, `compile_string`, `compile_quoted` and `:erl_eval`, with **one test per function**.
`test/no_eval_on_model_output_test.exs`: 13 tests, all passing, each red asserting the trigger
and line, plus greens for ordinary code and for a variable merely *named* `eval_string`.

**2. Version form.** No exemption list: the pattern is case-sensitive on word boundaries, so
`gen_mcp 2.0` and `anubis_mcp 2.0.x` are excluded *by the boundary*, not by a list.
`test/version_form_test.exs` asserts the skip list holds exactly one entry — the enforcer's own
source — so it cannot grow.

*Red discovered, not staged:* the enforcer failed the gate on its own test file, which held the
forbidden form as a literal fixture. The fixtures are now composed at runtime, so the file never
contains the string and the skip list stayed at one.

**3. Name check.** Red on a **synthetic token in a test-only digest set**, never a real name:

```
$ mix trinity.names --digests /tmp/syn.txt ; echo "exit=$?"
FAIL lib/planted_name.ex:4: forbidden name (zero permitted sites)
** (Mix) trinity.names: 1 violation(s)
exit=1

$ mix trinity.names --digests /tmp/syn.txt ; echo "exit=$?"   # planted file removed
trinity.names: OK over 146 tracked files
exit=0
```

Paths are scanned as well as contents, with the same tokenisation:

```
$ mix trinity.names --digests /tmp/syn.txt ; echo "exit=$?"   # token as a FILENAME
FAIL lib/qqfictitiousmarkerword_module.ex: forbidden name in a PATH (zero permitted sites)
exit=1
```

**4. `reuse lint`.** *Red discovered, not staged:* `mix trinity.reuse` failed the gate on
`lib/mix/tasks/versions.gen.ex`, created after the header pass —
`FAIL lib/mix/tasks/versions.gen.ex: no SPDX-License-Identifier: Apache-2.0`, `exit=1`. Green
after the header was added. **This check covers none of check 3**; they are separate gate steps
and separate lines here, and neither is offered as evidence for the other.

**5. Network rule.** `test/network_guard_test.exs` opens a **local TCP listener** so the
demonstration needs no network: the guard refuses to connect to a listener that is definitely
there (`{:error, :network_blocked_in_test}`), and reaches that same listener under
`TRINITY_LIVE=1`. The gate excludes `:live`, so `mix test --only live` keeps working — blocking
it would have broken the opt-in path `CLAUDE.md` §5 and `docs/03` both define.

## AC8 [manual] — the name check over the tree

```
$ mix trinity.names ; echo "exit=$?"
trinity.names: OK over 146 tracked files
exit=0

$ git grep -lIiE '<the four platform names>'      # pattern elided; see below
README.md
```

**The pattern is elided in that transcript deliberately.** Writing it out would put the platform
names in this file, which is not an approved site — and the enforcer proved that by failing on
the first draft of this document:

```
$ mix gate ; echo "exit=$?"
FAIL slices/000-toolchain-and-gate/PROOF.md:205: platform name outside the approved section
** (Mix) trinity.names: 1 violation(s)
exit=1
```

The proof document is not exempt from the rule it is proving. The pattern lives in the
enforcer's own source, which is its single skipped path.

Every platform-name hit is inside `README.md`'s approved section, located by the heading
`## Connecting Trinity to the platform`. Zero-site names return nothing in contents or paths.

**Owner confirms at G3** that each permitted hit maps to an approved line; that mapping is the
owner's approval, not a machine's, which is why this is `[manual]`.

**The section moved during this slice**, from lines 46–62 to 72–88, when the Phoenix generator
overwrote `README.md` and it was restored with a run section added above. A check hard-coded to
46–62 would now be reading the wrong sixteen lines. Locating by heading text survived it.

## AC9 [manual] — the red is synthetic, and the limit is stated

The red above uses `qqfictitiousmarkerword` in a test-only set. No real name appears in any
test, any fixture, or this file.

**The stated false-negative limit**, in `NOTES.md` and in the module's `@moduledoc`: tokenising
downcases and splits on every run of non-alphanumerics, so **a forbidden name glued inside a
larger token with no separator is not detected**. Accepted: the check is a tripwire against
copy-paste drift, and copy-paste carries whole tokens.
`test/trinity_names_test.exs` asserts that limit explicitly rather than leaving it as prose.

## Coverage

```
$ mix test --cover        # total
27.98%
$ cat coverage.tsv
slice_id	percent	sha	date
000	27.98	e60e3e7	2026-09-06
```

`e60e3e7` is the commit at which coverage was measured, not this slice's final commit.

**This row is the baseline and is compared against nothing.** `mix trinity.coverage` says so in
those words rather than reporting a pass. The drop rule first does real work at slice 001.
`test/coverage_gate_test.exs` proves the rule itself: a 3.5-point drop fails, exactly 3.0 passes.

`mix test --cover`'s default 90% threshold was turned off, because `docs/03` sets **no absolute
threshold** — its rule is drop-based. Leaving the default on would have enforced a different rule
than the one the project states.

## What is not proven here

- **AC5.** Owner confirms the Actions run at G3.
- **The `[manual]` tagging review**, still owed project-wide. Slice 000's own retag (AC5, AC8,
  AC9) was the owner's instruction at G1 and is applied.
- **The ADR status vocabulary question** raised on the M3 issue is unanswered and outside this
  slice.
- **`docs/01`'s context table** describes contexts no code implements yet. Only `Trinity` and
  `TrinityWeb` exist, which is what this slice's scope names.

---

## Correction, appended 2026-09-06 — the coverage figure

**Supersedes** the coverage figure above, which read:

> ```
> $ mix test --cover        # total
> 27.98%
> $ cat coverage.tsv
> slice_id	percent	sha	date
> 000	27.98	e60e3e7	2026-09-06
> ```

That was measured at `e60e3e7`, before the last four commits added the permitted-hit listing,
`plan_check` rules 9 and 10, and the status row. Those added code without proportional tests, so
the figure moved. Re-measured at this slice's head:

```
$ mix test --cover        # total
27.01%
$ cat coverage.tsv
slice_id	percent	sha	date
000	27.01	e935c7b	2026-09-06
```

**The drop is 0.97 points, 27.98 to 27.01, inside the three-point tolerance**, so it would pass the rule
even if there were a prior row to compare against. There is not: this is still the first row and
still a baseline compared against nothing.

The original figure is left standing above rather than edited, because a record that quietly
changes its own numbers is the defect this project keeps finding.

---

# G4 changes requested — the four items

Appended, not merged into the sections above, so the reviewed document stands as reviewed.

## Item 1 — AC3's second clause, derived rather than hand-listed

**Superseded:** "Rows this slice touched, and only those, were updated" and the AC3 line calling
the second clause *partial*. "Rows this slice touched" was a hand list, which is the defect.

**The mark's meaning is now derivable.** ✅ means *the package is in `mix.lock` at this sha*,
emitted by `mix versions.gen` from `Mix.Dep.Lock.read/0`. Toolchain rows are marked from
`.tool-versions`. Nothing is marked by hand, so a mark cannot outlive the fact it asserts —
which is exactly how finding B3 found two false ✅ marks on the packages the OTP pin rested on.
The old legend, under which ✅ meant "someone ran `curl` on some date", is replaced and says so.

Every row now lives in `Trinity.Versions` and the whole table body is generated. **That also
removed a duplication I had introduced**: `versions.gen` had appended a block *beside* the
hand-written tables rather than replacing them, so the toolchain and the seven slice-000
dependencies were listed twice.

Derived population, cross-checked both ways:

```
$ grep -c '| ✅ in `mix.lock` |' VERSIONS.md          → 15
$ grep -c '| 🔍 not yet a dependency |' VERSIONS.md    → 12
$ grep -c '| 🔍 not a single package |' VERSIONS.md    → 6
$ grep -c '| ✅ `.tool-versions` |' VERSIONS.md        → 5

# every ✅ row is genuinely in mix.lock
phoenix phoenix_live_view phoenix_pubsub bandit ecto_sql ecto_sqlite3 jason boundary
nimble_options credo mox mix_audit sobelow ex_doc lazy_html   → all OK
# no 🔍 row is in mix.lock
(no output)

$ mix versions.gen --check ; echo "exit=$?"
versions.gen: VERSIONS.md already matches Trinity.Versions and mix.lock
exit=0
```

**The change found a real gap.** `versions.verify` gained a check that every direct dependency
in `mix.exs` has a row, and it immediately named **twelve** the generator had added and the pin
list never documented: `phoenix_ecto`, `phoenix_html`, `phoenix_live_dashboard`,
`phoenix_live_reload`, `esbuild`, `tailwind`, `heroicons`, `daisyui`, `gettext`, `dns_cluster`,
`telemetry_metrics`, `telemetry_poller`. All now carry rows.

**One assertion corrected while doing this.** `versions.verify` briefly failed eleven pins as
"absent from mix.lock". That was wrong: absence is not disagreement — most pinned packages
arrive at a later slice. The rule is now that **the lock must not disagree** with the pin list,
and a pin that is not a version requirement at all (`not pinned`, `optional, ~> 0.3`,
`(transitive via LiveView test)`) is documentation with nothing to satisfy. The tests encoding
the old semantics were updated rather than left passing against a rule that no longer holds.

```
$ mix versions.verify ; echo "exit=$?"
versions.verify: OK — 52 locked packages, none disagreeing with 45 pins
exit=0
```

## Item 2 — AC5, green at head, not at some earlier sha

```
$ git log --oneline -1
1921293 docs(s000): state the coverage drop as points, not as the new figure

$ gh run list --branch slice/000-toolchain-and-gate --limit 5 ; echo "exit=$?"
completed	success	docs(s000): state the coverage drop as points, not as the new figure	gate	slice/000-toolchain-and-gate	push	34050775439	37s	2026-09-06T18:08:39Z
completed	success	docs(s000): correct the coverage figure by appending	gate	slice/000-toolchain-and-gate	push	34050748444	32s	2026-09-06T18:08:06Z
completed	success	feat(s000): list every permitted name hit for AC8	gate	slice/000-toolchain-and-gate	push	34050721136	36s	2026-09-06T18:07:34Z
completed	success	chore(s000): repoint the repository URL to the ScriptKittyOS organisa…	gate	slice/000-toolchain-and-gate	push	34050683172	29s	2026-09-06T18:06:49Z
completed	success	docs(s000): status done in SLICE.md and ROADMAP.md	gate	slice/000-toolchain-and-gate	push	34050634156	28s	2026-09-06T18:05:54Z
exit=0
```

**The run for the head commit `1921293` is `completed success`.** All five listed runs are green.
Commits made after this listing carry runs of their own.

## Item 3 — AC7 enforcer 2, the transcript and the test

The red was described and not shown. Reproduced by reverting the fixture to a literal:

```
$ mix gate ; echo "exit=$?"
FAIL test/version_form_test.exs:24: assert VersionForm.forbidden?("we target <the forbidden form> now")
** (Mix) trinity.version_form: 1 violation(s)
exit=1
```

**The form is elided in that transcript**, for the same reason the platform names are elided in
AC8: writing it literally would make this document a violation. The enforcer proved that too —
the first draft of this section carried it verbatim and `mix gate` failed on
`PROOF.md:391`, `exit=1`. Twice now, a proof document has been caught by the rule it was
proving. That is the enforcers working on their author, and it is worth more than a green run.

Green once the fixture is composed at runtime again:

```
$ mix trinity.version_form ; echo "exit=$?"
trinity.version_form: OK
exit=0
$ mix gate >/dev/null 2>&1 ; echo "exit=$?"
exit=0
```

**The test that plants the composed form and asserts detection** is
`test "the forbidden form is caught"` in `test/version_form_test.exs:23`. It builds the string
from `@protocol <> " " <> "2.0"` so the file never contains it, and asserts `forbidden?/1`
returns true. Result:

```
$ mix test test/version_form_test.exs --trace
  * test the forbidden form is caught (0.01ms) [L#23]
Result: 4 passed
```

The companion `test "the skip list holds exactly one entry"` keeps the exemption from growing to
cover the file instead.

## Item 4 — the deviation list

`NOTES.md` now carries **"Deviations from the G1 plan — the complete list"** with all four. The
pin-file one was recorded in the narrative at *"Line 1, continued — the toolchain install"* and
was **not in the deviation list** until this item asked for it. That gap is stated in the list
itself: a fact buried in a run log is not a deviation anyone will find.

## Taken up from the Coordinator's closing note

`boundary` enforcing only under `--warnings-as-errors` is now stated in `docs/01-architecture.md`
where the architecture rules live, not only here. The next reader of that file will not read this
document, which was the point.

The sobelow fingerprint's line-number sensitivity stays recorded in `.sobelow-skips.reasons`,
as the note accepts.
