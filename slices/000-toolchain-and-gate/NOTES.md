# Slice 000 — NOTES

## G1 plan

Posted 2026-09-06 against `012f595c70eb451e56216814213e64577f6d945e`, fifteen lines in execution order, one
sentence each, each naming what it produces. Nothing is coded until you have read them.

1. **The `boundary` probe runs first (H7)**, standing up a throwaway app on the pinned toolchain with boundaries `A` (deps `[]`) and `B` (deps `[A]`), planting an `A → B` call, and recording in this file both outputs and both exit codes of `mix compile --warnings-as-errors --force` — non-zero naming the violation, zero once removed — and stopping to write a fallback ADR if it does not enforce.
2. **The ERTS probe runs before the pin is written (B3)**, unpacking `burrito` 1.6.0 from hex, reading the module that resolves an ERTS artifact, querying the index it names for macOS, Linux and Windows, and recording the per-target table here, from which the newest OTP all three offer becomes the pin.
3. **The scaffold** produces `mise.toml` from lines 1 and 2, the `mix phx.new trinity --database sqlite3 --no-mailer` tree, the seven dependencies, the `Trinity` and `TrinityWeb` boundary declarations, and `TRINITY_DATA_DIR` in `config/runtime.exs`.
4. **The single pin source (M6)** produces `versions.exs`, `lib/mix/tasks/versions.gen.ex` regenerating VERSIONS.md's tables from it, and `lib/mix/tasks/versions.verify.ex` reading `versions.exs` and `mix.lock` and never the markdown.
5. **The gate alias (M5)** adds the eight-step `gate` to `mix.exs` with `sobelow --exit` blocking and commits `.sobelow-skips` empty, each later entry carrying one line of reason.
6. **The coverage baseline (M7)** produces `coverage.tsv` with columns `slice_id`, `percent`, `sha`, `date` and the gate step that reads it, recorded in PROOF.md as the first row and therefore a comparison against nothing.
7. **Enforcer 1** produces `lib/trinity/credo/no_eval_on_model_output.ex` and its test, failing the gate on any `Code.eval_string` under `lib/`.
8. **Enforcer 2 needs no exemption list**, producing `lib/mix/tasks/trinity.version_form.ex` which matches a literal `MCP` followed by a major number case-sensitively and on word boundaries, so lower-case library version strings are excluded by the boundary rather than by a list, and `test/version_form_test.exs` asserting the skip list holds exactly one path, the task's own source.
9. **Enforcer 3, the name check**, produces `lib/mix/tasks/trinity.names.ex` and `priv/name_digests.txt`, matching every zero-permitted-site name by salted digest so no file names them, locating the one permitted README section by its heading text rather than a line number, and running over paths as well as contents.
10. **Enforcer 4** produces `REUSE.toml` and a `reuse lint` gate step reported separately from line 9 and covering none of it.
11. **Enforcer 5** produces `test/support/network_guard.ex` blocking outbound sockets on the default test run, with the gate excluding `:live`, which runs under an explicit flag with the network open.
12. **The secret scan** produces `lib/mix/tasks/trinity.secrets.scan.ex` and its test, red on a planted fake key and green after removal.
13. **Licence and SPDX** add a header to every file `git ls-files` returns that can carry one and record `LICENSE`'s sha256 `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30` in PROOF.md, closing the ADR-0012 decision-1 gap commit 1 left open.
14. **Governance and CI** produce `CODE_OF_CONDUCT.md`, `CONTRIBUTING.md`, `SECURITY.md`, `GOVERNANCE.md`, `MAINTAINERS.md` and `CITATION.cff` for ADR-0012 decision 2, plus `.github/workflows/gate.yml` running `mix gate`, `scripts/plan_check.sh` and the DCO check.
15. **The manual queue holds four items and only these**, because the tree answers everything else in this slice: approve the line-9 digest-set design and its stated false-negative limit, which the slice issue's G1 gate says to wait on and which blocks lines 9 onward; supply the `SECURITY.md` disclosure contact; confirm the line-14 CI run is green, since AC5 is a claim about a remote I cannot vouch for; and rule on the moved ADR, still held in `../trinity-private` rather than destroyed.
