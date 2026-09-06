# Slice 000 — NOTES

## G1 plan v2

Posted 2026-09-06 against `012f595c70eb451e56216814213e64577f6d945e`, superseding v1 at `6c9f3d1` with the owner's
line-keyed changes. Fifteen lines, execution order, one sentence each, each naming what it produces.

1. **The `boundary` probe runs first (H7)**, standing up a throwaway app on the pinned toolchain with boundaries `A` (deps `[]`) and `B` (deps `[A]`), planting an `A → B` call, and recording in this file both outputs and both exit codes of `mix compile --warnings-as-errors --force` — non-zero naming the violation, zero once removed — and stopping to write a fallback ADR if it does not enforce.
2. **The ERTS probe runs before the pin is written (B3)**, producing a per-target table for macOS, Linux and Windows with three columns — the ERTS versions `burrito` 1.6.0 offers, what Elixir 1.20.x's compatibility table lists, and what `ex_tauri` 0.2.0's stated requirement excludes — from which the pin is the newest OTP satisfying all three, leaving `ex_tauri`'s actual behaviour to slice 001 to measure.
3. **The toolchain manager is measured before `mise.toml` exists**, running `which mise asdf; echo "exit=$?"` and recording the output here, then writing the pin file for whichever is present and stopping to ask if neither is.
4. **The single pin source (M6)** produces `versions.exs`, `lib/mix/tasks/versions.gen.ex` regenerating VERSIONS.md's tables from it, `lib/mix/tasks/versions.verify.ex` reading `versions.exs` and `mix.lock` and never the markdown, and `test/mix/tasks/versions_verify_test.exs` whose red plants an entry disagreeing with `mix.lock` and asserts a non-zero exit naming the package.
5. **The gate alias (M5)** adds the eight-step `gate` to `mix.exs` with `sobelow --exit` blocking, after first measuring whether `.sobelow-skips` accepts a trailing comment by adding one entry with a reason and recording sobelow's outcome here — if it rejects comments, reasons move to `.sobelow-skips.reasons` keyed by fingerprint with a test asserting every fingerprint carries one.
6. **The coverage baseline (M7)** produces `coverage.tsv` with columns `slice_id`, `percent`, `sha`, `date`, the gate step that reads it, and `test/coverage_gate_test.exs` whose red seeds a prior row and asserts the step fails on a drop greater than three points and passes at exactly three.
7. **Enforcer 1** produces `lib/trinity/credo/no_eval_on_model_output.ex` covering the whole family — `Code.eval_string`, `Code.eval_quoted`, `Code.eval_file`, `Code.compile_string`, `Code.compile_quoted` and `:erl_eval` — with one test per function planting a call in a throwaway module under `lib/` and asserting the gate goes red on each.
8. **Enforcer 2 needs no exemption list**, producing `lib/mix/tasks/trinity.version_form.ex` which matches a literal `MCP` followed by a major number case-sensitively and on word boundaries, so lower-case library version strings are excluded by the boundary rather than by a list, and `test/version_form_test.exs` asserting the skip list holds exactly one path, the task's own source.
9. **Enforcer 3, the name check**, produces `lib/mix/tasks/trinity.names.ex` and `priv/name_digests.txt` holding the salt and digests only, working by lowercasing, splitting on every non-alphanumeric character, digesting each token with the committed salt and comparing against the committed set, over contents and over paths tokenised the same way; its stated limit is that a zero-site name glued inside a larger token with no separator is not detected, accepted because this is a tripwire against copy-paste drift and copy-paste carries whole tokens; the generator that builds the set lives in `../trinity-private` and never in the tree; its red uses a synthetic token in a test-only set and never a real name; and every zero-site name goes through the digest set while the plain-text set holds only the four platform names.
10. **Enforcer 4** produces `REUSE.toml` and a `reuse lint` gate step reported separately from line 9 and covering none of it.
11. **Enforcer 5** produces `test/support/network_guard.ex` blocking outbound sockets on the default test run, proven without a network by a test that opens a local TCP listener and asserts the connect is blocked, and passes against that same listener when tagged `:live` and run under the explicit flag the gate excludes.
12. **The secret scan** produces `lib/mix/tasks/trinity.secrets.scan.ex` and its test, red on a planted fake key and green after removal.
13. **Licence and SPDX** add a header to every file `git ls-files` returns that can carry one and record `LICENSE`'s sha256 `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30` in PROOF.md, closing the ADR-0012 decision-1 gap commit 1 left open.
14. **Governance and CI** produce `CODE_OF_CONDUCT.md`, `CONTRIBUTING.md`, `SECURITY.md` carrying `security@scriptkittyos.com` as the disclosure contact, `GOVERNANCE.md`, `MAINTAINERS.md` and `CITATION.cff` for ADR-0012 decision 2, plus `.github/workflows/gate.yml` running `mix gate`, `scripts/plan_check.sh` and the DCO check.
15. **The manual queue holds one item**, the owner having answered the other three at G1: confirm at G3 that the line-14 Actions run is green, by pasting its status, because AC5 is a claim about a remote this branch cannot vouch for.

## Owner decisions at G1, 2026-09-06

- **Line 9 digest design approved** as written above. Nothing behind it is blocked.
- **`SECURITY.md` disclosure contact:** `security@scriptkittyos.com`.
- **The withdrawn shared-components ADR stays in `../trinity-private`.** Closed; it is not returning to the
  tree and is not to be destroyed. Its number is not cited here, because `plan_check` check 6 fails on a
  citation to an ADR absent from `git ls-files` — which it did on the first draft of this line.
- **AC5, AC8 and AC9 retagged `[manual]`** in `SLICE.md` in the same commit as this plan. The wider tagging review is
  per slice at its own G1, not a single sweep.
- **One slice, one branch.** G2 is `mix gate` green; the gate transcript is posted and work stops at G3 with
  `PROOF.md` written.
