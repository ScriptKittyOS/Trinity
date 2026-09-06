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

---

## Line 1 — `boundary` probe (H7). Answered: it works.

Run 2026-09-06 in a throwaway app outside the repository, on the pinned toolchain.

```
$ elixir -v
Erlang/OTP 28 [erts-16.1.1] [source] [64-bit] [smp:32:32] [ds:32:32:10] [async-threads:1] [jit:ns]

Elixir 1.20.4 (compiled with Erlang/OTP 28)
$ mix deps | grep -A1 '^\* boundary'
* boundary 0.10.4 (Hex package) (mix)
  locked at 0.10.4 (boundary) 8baf6f23
```

Two boundaries: `A` with `deps: []`, `B` with `deps: [A]`. The violation is `A` calling `B.hello()`.

**Baseline, no violation:**

```
$ mix compile --warnings-as-errors --force ; echo "exit=$?"
==> boundary
Compiling 15 files (.ex)
Generated boundary app
==> probe
Compiling 2 files (.ex)
Generated probe app
exit=0
```

**Red, violation planted at `lib/a.ex:5`:**

```
$ mix compile --warnings-as-errors --force ; echo "exit=$?"
Compiling 2 files (.ex)
Generated probe app

warning: forbidden reference to B
  (references from A to B are not allowed)
  lib/a.ex:5

exit=1
```

**Green, violation removed:**

```
$ mix compile --warnings-as-errors --force ; echo "exit=$?"
Compiling 2 files (.ex)
Generated probe app
exit=0
```

**H7 is closed: `boundary` 0.10.4 compiles and enforces on Elixir 1.20.4 / OTP 28.** No fallback ADR is needed,
and ADR-0001, `docs/01-architecture.md`, CLAUDE.md §5 and AC4 keep the foundation they rest on.

### One measurement the probe added, which the slice needs

`boundary` reports a violation as a **warning**, not an error. With the same violation in place and the flag
dropped:

```
$ mix compile --force ; echo "exit=$?"
Compiling 2 files (.ex)
Generated probe app

warning: forbidden reference to B
  (references from A to B are not allowed)
  lib/a.ex:5

exit=0
```

**Exit 0.** So `boundary` is an enforcer only while `--warnings-as-errors` is on the compile step; without it the
architecture rules are advisory and a violation ships silently. That is the same shape as the `sobelow --exit`
contradiction M5 was raised for. The gate alias at line 5 must therefore keep `--warnings-as-errors` on `compile`,
and AC4 is a claim about that flag as much as about `boundary`.

---

## Line 2 — ERTS probe (B3). The three constraints do not intersect.

Run 2026-09-06, before any pin file was written.

### Where the numbers come from

`burrito` 1.6.0 was fetched from hex and unpacked. `lib/util/default_erts_resolver.ex` delegates to
`Burrito.Util.ERTSUniversalMachineFetcher.fetch_version/4`, which names three artifact sources verbatim:

```
@windows_url "https://github.com/erlang/otp/releases/download/OTP-{OTP_VERSION}/otp_win64_{OTP_VERSION}.exe"
@linux_url   "https://beam-machine-universal.b-cdn.net/OTP-{OTP_VERSION}/linux/{ARCH}/any/otp_{OTP_VERSION}_linux_any_{ARCH}.tar.gz"
@mac_url     "https://beam-machine-universal.b-cdn.net/OTP-{OTP_VERSION}/macos/universal/otp_{OTP_VERSION}_macos_universal.tar.gz"
```

Each was probed with `curl -I` per OTP version. 200 means the artifact exists; 404 means Burrito cannot fetch it.

### Column 1 — what Burrito 1.6.0 can actually fetch, per target

| OTP | macOS universal | Linux x86_64 | Linux aarch64 | Windows |
|---|---|---|---|---|
| 27.3.4.17 | **404** | **404** | not probed | 200 |
| 28.1.1 | 200 | 200 | 200 | 200 |
| **28.5** | **200** | **200** | **200** | **200** |
| 29.0.6 | **404** | **404** | **404** | 200 |

Windows comes from the official OTP release page, so it carries every version; macOS and Linux come from the
BEAM-machine CDN, which **carries only the OTP 28 line**. Column 1 admits OTP 28.x and nothing else.

### Column 2 — what Elixir 1.20.x lists

Elixir 1.20.4 ships builds for OTP 27, 28 and 29 (`asdf list all elixir | grep '^1\.20\.4'` returns `1.20.4`,
`1.20.4-otp-27`, `1.20.4-otp-28`, `1.20.4-otp-29`). Column 2 admits 27, 28 and 29.

### Column 3 — what `ex_tauri` 0.2.0 states

```
$ grep -n 'otp' ex_tauri-0.2.0/mix.exs
11:      elixir: "~> 1.15",
12:      # Limited to OTP 27 due to Burrito pre-compiled ERTS availability
13:      # OTP 28 doesn't have universal macOS binaries available yet
14:      otp_release: "~> 27.0",
$ grep -n 'OTP' ex_tauri-0.2.0/README.md
29:- **Elixir** >= 1.15 with **OTP 27** (OTP 28 not yet supported due to Burrito ERTS availability)
```

Column 3 admits **only OTP 27**, and therefore excludes 28.

### The intersection is empty, and column 3's stated reason is measurably false

Column 1 ∩ column 2 = **OTP 28.x**, newest satisfying both is **28.5**. Column 3 excludes 28. **No OTP version
satisfies all three constraints**, so line 2's rule as written yields nothing and I am not inventing a tie-break.

The reason column 3 gives for excluding OTP 28 is *"OTP 28 doesn't have universal macOS binaries available yet"*.
The measurement above says the opposite, and inverts it: **OTP 28 macOS universal returns 200, and OTP 27 macOS
universal returns 404.** `ex_tauri`'s constraint is a stale fact of exactly the kind B3 was raised to catch — it
was true when written and the CDN has moved on.

### What this settles about ADR-0005

The OTP 28 pin is **confirmed by measurement**, on the packaging chain's own artifact index, and the ADR-0005
correction's suspicion that OTP 29 might now be viable is **overturned**: OTP 29 is missing on macOS and on both
Linux architectures. The newest OTP that Burrito can package for all three targets is **28.5**, not the 28.1.1
this machine currently runs.

### Stopping here, before line 3 writes a pin

Per CLAUDE.md §7 — a dependency incompatibility, and an ambiguity that changes the design.

---

## Line 2, continued — owner's extra measurement. The pin moves to 28.5.0.5.

The owner's decision pinned 28.5 subject to probing every 28.x patch OTP has released above it, taking the newest
that returns 200 on **all four** targets.

### The population, from two independent sources that agree

```
$ asdf list all erlang | grep -E '^28\.' | tr '\n' ' '
28.0-rc1 28.0-rc2 28.0-rc3 28.0-rc4 28.0 28.0.1 28.0.2 28.0.3 28.0.4 28.1 28.1.1 28.2 28.3 28.3.1 28.3.2 28.3.3
28.4 28.4.1 28.4.2 28.4.3 28.5.0.1 28.5.0.2 28.5.0.3 28.5.0.4 28.5.0.5 28.5.0.6 28.5

$ curl -s "https://api.github.com/repos/erlang/otp/releases?per_page=100" | grep -oE '"tag_name": *"OTP-28[^"]*"' | ...
28.0 28.0-rc1 ... 28.4.3 28.5 28.5.0.1 28.5.0.2 28.5.0.3 28.5.0.4 28.5.0.5 28.5.0.6
```

Six patches exist above 28.5: **28.5.0.1 through 28.5.0.6**. The two sources agree, so the population is not a
hand list.

### The full table

| OTP | macOS universal | linux x86_64 | linux aarch64 | Windows | all four? |
|---|---|---|---|---|---|
| 28.5.0.6 | **404** | **404** | **404** | 200 | no |
| **28.5.0.5** | **200** | **200** | **200** | **200** | **yes — the pin** |
| 28.5.0.4 | 200 | 200 | 200 | 200 | yes |
| 28.5.0.3 | 200 | 200 | 200 | 200 | yes |
| 28.5.0.2 | 200 | 200 | 200 | 200 | yes |
| 28.5.0.1 | 200 | 200 | 200 | 200 | yes |
| 28.5 | 200 | 200 | 200 | 200 | yes |

**The measurement moved the pin.** 28.5.0.6 is released and is on the official Windows download page, but the
BEAM-machine CDN has not built its macOS or Linux artifacts, so Burrito cannot package it for three of the four
targets. **The pin is OTP 28.5.0.5**, not the 28.5 the decision provisionally named — which is why the decision
made it subject to this probe.

That gap is also the standing risk: Windows tracks OTP releases immediately and the other three targets lag behind
a third-party CDN, so the newest packageable OTP is whatever that CDN last built. Re-run this probe at every phase
boundary, as `VERSIONS.md`'s re-verification procedure already requires.

## Line 1, continued — the toolchain install

The machine ran Elixir 1.19.2, not the pinned 1.20.x, so the H7 probe could not have measured what H7 asks about:
`boundary`'s behaviour under **Elixir 1.20's** type checker. The pinned Elixir was installed first.

```
$ which mise asdf ; echo "exit=$?"
/usr/local/bin/asdf
exit=1

$ asdf install elixir 1.20.4-otp-28 ; echo "exit=$?"
==> Checking whether specified Elixir release exists...
==> Downloading 1.20.4-otp-28 to /home/aylac/.asdf/downloads/elixir/1.20.4-otp-28/elixir-precompiled-1.20.4-otp-28.zip
==> Copying release into place
exit=0

$ elixir --version
Erlang/OTP 28 [erts-16.1.1] [source] [64-bit] [smp:32:32] [ds:32:32:10] [async-threads:1] [jit:ns]

Elixir 1.20.4 (compiled with Erlang/OTP 28)
```

`mise` is absent and `asdf` v0.18.0 is present, so **the pin file is `.tool-versions`, not `mise.toml`**, and
line 3's rule — write the file for whichever manager is present — resolves to asdf. Every reference to
`mise.toml` in `SLICE.md` is corrected to `.tool-versions` in the same commit.

---

## Amendment, 2026-09-06 — owner's addition to line 5

Quoting the owner's Decision:

> `boundary` enforces only under `--warnings-as-errors`, so the rule is advisory unless the gate carries the flag.
> **Added to line 5:** the gate's compile step runs `mix compile --warnings-as-errors`, and **a test asserts the
> gate alias contains that flag**, so removing it fails the gate. The red is demonstrated by dropping the flag in
> a throwaway edit to `mix.exs`.

Line 5 as posted is not rewritten; this amendment governs. The gate alias carries `--warnings-as-errors` on its
compile step, and `test/gate_alias_test.exs` asserts the flag is present in the alias, so a future edit that drops
it fails the gate rather than silently turning `boundary` and the type checker advisory.

## Line 3 — the pin is written

```
$ printf 'erlang 28.5.0.5\nelixir 1.20.4-otp-28\n' > .tool-versions
$ cat .tool-versions
erlang 28.5.0.5
elixir 1.20.4-otp-28

$ elixir --version
Erlang/OTP 28 [erts-16.4.0.5] [source] [64-bit] [smp:32:32] [ds:32:32:10] [async-threads:1] [jit:ns]

Elixir 1.20.4 (compiled with Erlang/OTP 28)

$ erl -noshell -eval 'io:format("~s / erts ~s~n",[erlang:system_info(otp_release), erlang:system_info(version)]), halt().'
28 / erts 16.4.0.5
```

`asdf install erlang 28.5.0.5` completed with exit 0 and `asdf list erlang` now shows it installed alongside the
28.1.1 the machine had. The running erts is **16.4.0.5**, which supersedes the erts-16.1.1 recorded in the line 1
probe — the H7 result is unaffected, since `boundary` was measured against Elixir 1.20.4 and the OTP 28 line, and
both still hold.

`VERSIONS.md`'s toolchain table now carries the exact patch versions and the reason for each, replacing the
"pending measurement" wording and the note that deferred the ERTS question to slice 001.
