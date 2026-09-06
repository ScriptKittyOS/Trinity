# Slice 000 — Toolchain, repo bootstrap, quality gate

| Field | Value |
|---|---|
| Phase | 0 Foundation |
| Milestone | M0 Stands |
| Size | L |
| Depends on | — |
| Status | done |

## Goal
A Phoenix 1.8 app named `trinity` that compiles on pinned Elixir 1.20.x / OTP 28.x, with the full quality gate
(`mix gate`) green, `boundary` wired, CI running the gate on push, and `VERSIONS.md` verified against reality.

## Why
Everything downstream assumes the gate exists and the versions are real. Accountability starts here.

**Sized L, not M, and not split.** The scope holds a toolchain, a generator run, boundary wiring, an eight-step
gate, two Mix tasks, CI and the open-source hygiene artefacts. The hygiene half stays here because ADR-0012
decision 2 puts the governance files at this slice by name, and because decision 1's commit-1 requirement is
only partly met: commit 1 carries `LICENSE`, `NOTICE` and DCO sign-off, and does **not** carry SPDX headers or
`REUSE.toml`. This slice closes that gap and delivers decision 2, so splitting it would leave an accepted ADR
unmet with no slice owning the remedy.

## Scope
**In:**
- **First, before anything else: the `boundary` probe.** `boundary` has not shipped since 2024-09-25 and its
  behaviour under Elixir 1.20's type checker with `--warnings-as-errors` is unverified. Everything in
  ADR-0001, `docs/01-architecture.md`, CLAUDE.md §5 and AC4 below rests on it. Stand up a throwaway app on the
  pinned toolchain, wire two boundaries, plant a violation, and confirm it fails compilation. If it does not
  work, stop and record the fallback (conventions plus a custom Credo check, or an umbrella) in an ADR before
  continuing. Nothing else in this slice starts until this is answered.
- `.tool-versions` pinning erlang + elixir; `elixir --version` output recorded. Measured at G1: `mise` is
  absent on this machine and `asdf` v0.18.0 is present, so the pin file is asdf's, not `mise.toml`.
- `mix phx.new trinity --database sqlite3 --no-mailer` (keep LiveView, Tailwind, daisyUI defaults; remove what is unused later).
- Dependencies: `boundary`, `credo`, `mox`, `mix_audit`, `sobelow`, `ex_doc`, `nimble_options`. Nothing else yet.
- `boundary` top-level definitions for `Trinity` and `TrinityWeb` (`TrinityWeb` deps `[Trinity]`; `Trinity` deps `[]`).
- Mix aliases: `gate` = format --check-formatted, compile --warnings-as-errors --force, credo --strict,
  `sobelow --exit` **blocking, with a committed `--skip` list carrying a one-line reason per skip**, hex.audit,
  deps.audit, test, secret scan. (`--exit` fails the build; the earlier wording called the same step advisory,
  which it is not. A named exception with a reason is an enforcer, not a weakening.)
- `versions.exs`: the machine-readable pin list, one entry per dependency. `VERSIONS.md`'s tables are **generated
  from it**, so the prose cannot drift from the checked data.
- `mix versions.verify` task: reads `versions.exs` and `mix.lock`, prints pinned vs locked vs latest from
  `mix hex.info`, non-zero exit on retired or vulnerable. It does **not** parse the markdown: those cells hold
  emoji, footnotes and phrases like "decided by Slice 059", and a parser over them breaks on the first edit,
  which is when it is needed. The audit that found ten stale rows in `VERSIONS.md` had to be run by hand because
  the check was specified as prose.
- **Gate enforcers for rules that currently have none.** CLAUDE.md §8 says a rule has an enforcing test or a
  stated reason; these had neither. Each is a separate gate step and a separate line in PROOF.md; none is reported
  as covering another:
  1. `Code.eval_string` on model output: a Credo check or grep over `lib/`. Fails the gate on any occurrence.
  2. **The version-form check.** MCP is versioned by date, never by a major number, so the forbidden form is a
     literal `MCP` followed by a major version number. The pattern is **case-sensitive with word boundaries**,
     which is what excludes `gen_mcp 2.0` and `anubis_mcp 2.0.x`: they are lower-case and the underscore is a
     word character, so no boundary opens before `mcp`. **There is no exemption list.** The enforcer's own
     source file is the single path it skips, because it must contain the pattern to test it, and a test asserts
     that skip list has exactly one entry.
  3. **The name check.** Two policies, and which policy a name gets decides how it is matched.
     **Zero-permitted-sites names** — the two code names and the superseded agent name — are matched by a
     **committed digest set**, never by a plaintext pattern, because any file spelling them would itself be a
     hit. That is why this specification does not name them either. G1 states the digest set's
     false-negative limit.
     **Permitted-site names** — the four platform names — are matched in plain text and are allowed only
     inside the one approved section of `README.md`. That section is located **by its heading text**, never by
     line numbers, so editing the file above it cannot silently move the permitted window.
     The check runs over **paths as well as contents**: a content-only grep would pass a tree whose filenames
     carry names, which is how a filename carrying a code name was caught.
  4. `reuse lint`: per-file copyright and licence information. **This is a separate check from 3 and covers none
     of it.**
  5. **Tests must not reach the network.** Outbound sockets are blocked on the **default** test run, so the rule
     fails loudly rather than passing quietly on a machine that happens to be online. The `:live` tag is excluded
     from `mix gate` and runs only under an explicit flag, with the network open — those tests exist to reach a
     real provider, so blocking them would break the opt-in path CLAUDE.md §5 and `docs/03` both define.
- Secret scan: a small Mix task (`mix trinity.secrets.scan`) with regexes for common API key shapes over `git diff --cached` and the tree; part of gate.
- GitHub Actions (or equivalent) workflow running `mix gate` on ubuntu-latest with a matrix `TRINITY_DB=sqlite` (postgres job added in 010).
- `.gitignore` already exists and covers `.env*`, `_build`, `deps`, `priv/data/` and `tauri/target`; the
  generator's additions merge into it rather than replacing it.
- `README.md` in repo root: how to run, how the slice process works (link to `docs/`).
- Copy this plan package into the repo (`docs/`, `slices/`, `templates/`, `CLAUDE.md`, `ROADMAP.md`, `VERSIONS.md`).
- **Open-source hygiene from commit 1 (ADR-0012):** `LICENSE` = Apache-2.0; `NOTICE` with the three-role pattern
  (Sudo Apt Holdings LLC owns the IP, Script Kitty built it, Ayla Croft authored it, ORCID 0009-0008-9457-2160);
  SPDX headers on every source file (`# SPDX-License-Identifier: Apache-2.0`, holder only); `REUSE.toml`;
  DCO sign-off enforced by a commit-msg hook and CI (`git commit -s`); `CODE_OF_CONDUCT.md`, `CONTRIBUTING.md`,
  `SECURITY.md`, `GOVERNANCE.md` (single maintainer today, documented intent and process to add committers),
  `MAINTAINERS.md`, `CITATION.cff`. The repo is private until the owner says otherwise; the history must already be
  publishable.
**Out:**
- Any domain code. Any desktop tooling (001). Tailwind theme work.

## Design notes
- Keep the generator's `Trinity.Repo` but do not add schemas yet.
- `config/runtime.exs`: `TRINITY_DATA_DIR` env (defaults to OS data dir via a tiny helper; full OS-dir logic in 010).
- Elixir 1.20 type checker: ensure `mix compile --warnings-as-errors` treats type warnings as errors (it does by default; verify).

## Deliverables
- Repo scaffold, `.tool-versions`, `mix.exs` with aliases, `lib/trinity/versions.ex` (see the recorded deviation), `lib/mix/tasks/versions.verify.ex`, `lib/mix/tasks/versions.gen.ex`, `lib/mix/tasks/trinity.secrets.scan.ex`, `.github/workflows/gate.yml`, `.credo.exs`, `.formatter.exs`, plan package copied.

## Acceptance criteria
1. [auto] `elixir --version` shows Elixir 1.20.x on OTP 28.x, matching `.tool-versions`, and the exact patch versions are written into `VERSIONS.md`.
2. [auto] `mix gate` exits 0 on a clean checkout.
3. [auto] `mix versions.verify` exits 0 and its output is pasted in PROOF.md; any 🔍 rows in `VERSIONS.md` that this slice touched are flipped to ✅ with today's date.
4. [auto] Introducing a boundary violation (temporary test file making `Trinity` call `TrinityWeb`) makes `mix gate` fail; removing it makes it pass. Both outputs captured.
5. [manual] CI workflow runs the gate and is green on the slice branch.
6. [auto] `mix trinity.secrets.scan` detects a planted fake key in a temp file and exits non-zero; passes after removal.
7. [auto] Each of the five enforcers above fails the gate on a planted violation and passes after its removal. Both outputs captured per enforcer.
8. [manual] The name check exits 0 over the tree as it stands at commit 1, and every permitted hit maps to a line on the approved permitted-sites list.
9. [manual] The name check's red is demonstrated on a synthetic token, not on real content, and the digest set's false-negative limit is stated in NOTES.md.

## Proof required
- `elixir --version`, `asdf current`, `mix gate` output, `mix versions.verify` output, the boundary-violation before/after, CI run URL or log excerpt, secret scan before/after.

## Manual verification queue
Every `[manual]` criterion below needs a person. Listed here so the owner sees the queue at G1 rather
than at review time.
- **AC5** — confirm the CI Actions run is green on this branch, by pasting its status; the run is on a
  remote this branch cannot vouch for.
- **AC8** — answered at G1: the permitted-sites list is approved and the name check consumes it; the owner
  confirms at G3 that each permitted hit maps to an approved line.
- **AC9** — answered at G1: the digest-set design and its stated false-negative limit are approved as
  written in NOTES.md; the owner confirms the limit still reads correctly at G3.

## Definition of Done
- [ ] `mix gate` green · [ ] AC1–9 proven · [ ] CI green · [ ] `VERSIONS.md` updated · [ ] ROADMAP → done · [ ] final commit + tag

## Commit & tag
`feat(s000): complete slice 000 — toolchain, repo bootstrap, quality gate` · tag `slice/000`

## Risks / open questions
- If Elixir 1.20.x does not support the chosen OTP 28 patch, use the newest 1.20.x that does and note it in NOTES.md.
- The OTP 28 pin itself is unmeasured (B3). This slice records `elixir -v` and the ERTS set Burrito 1.6.0 actually offers; Slice 001 confirms it per target.
- If `sobelow` produces false positives on the scaffold, document the skip list; do not remove it from the gate.
