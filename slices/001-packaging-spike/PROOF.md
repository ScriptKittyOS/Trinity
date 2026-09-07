<!--
SPDX-FileCopyrightText: Sudo Apt Holdings LLC
SPDX-License-Identifier: Apache-2.0
-->

# PROOF — Slice 001 — Packaging spike: Burrito + ex_tauri smoke build

Agent: Claude Opus 5 · Date: 2026-09-06 · Branch: `slice/001-packaging-spike`

`ROADMAP.md` set to `done` at **`b30c6ad`**, which is the final commit in CLAUDE.md §4's sense.
Seven commits follow it, and they are not the slice being reworked: they are the owner's G3
instructions applied — the CI run and the two defects it exposed, the wrapper transcript, and
three corrections to this file's own claims. Each is listed under Git below. The branch head at
G3 is named there; `git log --oneline main..HEAD` derives it.

## Summary

The scaffold from 000 packages as a single Burrito binary on linux x86_64, boots, serves HTTP
200, and stops by itself under `--no-halt --smoke` leaving no process behind. `ex_tauri` runs
on the pinned OTP 28 toolchain — its `~> 27.0` is declarative metadata and its runtime guard
warns rather than raising above OTP 27.

All three targets build and run — **on runners**. `package` run `34067973983` at `c2be3fa`,
three jobs green: linux 20 790 808 B and macOS 11 927 096 B both served HTTP 200, Windows
24 519 680 B booted and exited under `--smoke`. On this machine only linux builds; Windows
needs 7z and macOS can only be cross-compiled.

**What this slice did not do is the more important half. No native window has been opened on
any operating system, and no screenshot of one exists.** A runner has no desktop session and
every job says so in its own summary. **ADR-0004 is therefore not confirmed**: its exit
condition is a *running smoke build* on macOS and Windows, which the runners now give, but its
subject is the desktop **shell**, and `mix ex_tauri.dev` has never been run anywhere —
including here, because `mix ex_tauri.install` was never run and there is no `tauri/` project.
Stamping `accepted` on it would be inventing a result.

Four criteria exit unproven or partly proven, and **only two of them need a machine**:

* **AC2, AC3** — a macOS desktop and a Windows desktop. Neither exists here.
* **AC4, and AC6's first-paint half** — **not a machine.** This is an X11 desktop with
  `DISPLAY=:0`. What is missing is that `mix ex_tauri.install` was never run, so there is no
  `tauri/` project to launch, plus five apt packages needing root. I called this "no machine
  available" for the length of the slice and it was wrong; the correction is under AC4.

A fifth, **AC8, exits false** — not unproven — because the property underneath it was measured
and does not hold: the Burrito wrapper does not forward termination, so the BEAM outlives it
and goes on serving. Filed as **finding F1**, owned by slice 100.

## Gate

```
$ mix gate ; echo "exit=$?"
Checking 44 source files ...
Analysis took 0.05 seconds (0.00s to load, 0.05s running 69 checks on 44 files)
167 mods/funs, found no issues.
... SCAN COMPLETE ...
versions.verify: OK — 67 locked packages, none disagreeing with 45 pins
versions.gen: VERSIONS.md already matches Trinity.Versions and mix.lock
trinity.version_form: OK
trinity.names: OK over 157 tracked files
trinity.secrets.scan: OK over 157 files
trinity.reuse: OK — every commentable tracked file carries an SPDX header
Result: 68 passed
trinity.coverage: 001 30.37% vs 000 27.01% — OK
exit=0
```

```
$ ./scripts/plan_check.sh ; echo "exit=$?"
plan_check: PASS
exit=0
```

## Tests

```
$ mix test --cover ; echo "exit=$?"
|     30.37% | Total                             |
exit=0
Result: 68 passed
```

`mix test --cover` exited **3** before this slice, on a 90% threshold `mix.exs` claimed to have
turned off. `test_coverage: [threshold: 0]` is the wrong shape — Mix reads the threshold from
the `:summary` sub-option — so the key had been ignored since slice 000. Corrected to
`test_coverage: [summary: [threshold: 0]]`. It never affected `mix gate`, which runs `test` and
`mix trinity.coverage` and not `--cover`; it affected anyone reading the comment.

`coverage.tsv` row: `001  30.37  5a9c8f7  2026-09-06`. **Up 3.36 points from 000's 27.01%**, so
the drop rule owes no reason. The rule was exercised for the first time anyway, in both
directions — see AC9.

## Acceptance criteria evidence

### AC1 [auto] — `MIX_ENV=prod mix release` with Burrito produces a binary for the host OS; running it starts Phoenix on an ephemeral port and serves the scaffold page

```
$ BURRITO_TARGET=linux_x86_64 MIX_ENV=prod mix release desktop --overwrite ; echo "exit=$?"
exit=0

$ stat -c '%n %s' burrito_out/desktop_linux_x86_64 ; echo "exit=$?"
burrito_out/desktop_linux_x86_64 20777960
exit=0

$ file burrito_out/desktop_linux_x86_64
burrito_out/desktop_linux_x86_64: ELF 64-bit LSB executable, x86-64, version 1 (SYSV), statically linked, stripped
```

```
$ PHX_SERVER=true ./burrito_out/desktop_linux_x86_64 --no-halt &
[info] Running TrinityWeb.Endpoint with Bandit 1.12.5 at 127.0.0.1:35159 (http)

$ curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:35159/ ; echo "exit=$?"
200
exit=0

$ curl -sS http://127.0.0.1:35159/ > page.html ; echo "exit=$?"
exit=0
$ wc -c < page.html
20165
$ grep -o 'Phoenix Framework\|csrf-token' page.html | head -3
csrf-token
Phoenix Framework
Phoenix Framework
```

**Met.** The port is ephemeral: `config/runtime.exs` binds `127.0.0.1` on port 0 in `:prod`, and
35159 is what the kernel assigned that run.

**`--no-halt` is load-bearing and is a finding, not a flag I like.** Burrito launches the
release as `erl … -noshell -s elixir start_cli … -extra <argv>`. `elixir start_cli` is the
ordinary Elixir CLI entry point and it halts when its command list is empty, exactly as
`elixir -e ''` does — so without `--no-halt` the binary starts the endpoint and exits
immediately, with status **0**, and nothing downstream notices.

### AC2 [manual] — `mix ex_tauri.dev` opens a native window showing the LiveView scaffold on macOS

**Window unproven. But the artifact is no longer "never executed".**

Upgraded 2026-09-06 by the `package` workflow's first green run, `34067973983` at `c2be3fa`,
job `macOS aarch64` on `macos-latest`:

```
-rwxr--r--  1 runner  staff  11927096 Sep  6 23:52 desktop_macos_aarch64
Running TrinityWeb.Endpoint with Bandit 1.12.5 at 127.0.0.1:49432 (http)
TRINITY_SMOKE_PORT=49432
HTTP 200 on port 49433
```

**Built natively on macOS, launched, served HTTP 200, and exited by itself under `--no-halt
--smoke` leaving no process of ours behind.** That is AC1's property on macOS.

**It is not AC2.** AC2 asks for `mix ex_tauri.dev` opening a native window showing the scaffold,
with a screenshot. A GitHub runner has no desktop session, the job's own summary says so, and no
screenshot exists. AC2 stays `[manual]` and unproven, needing a macOS desktop.

Superseding the earlier entry here: it said the macOS target "does cross-compile on this Linux
host … and has never been executed", with a 13 782 104-byte figure. The cross-compile fact
stands but is now beside the point — the runner built it natively at 11 927 096 bytes and ran
it.

### AC3 [manual] — the same on Windows, or a documented failure with the fallback that succeeded

**Window unproven. Built and run on a runner; still not built on this machine.**

Upgraded 2026-09-06 by run `34067973983` at `c2be3fa`, job `windows x86_64` on
`windows-latest`:

```
-rwxr-xr-x 1 runneradmin 197121 24519680 Sep  6 23:57 desktop_windows_x86_64.exe
Running TrinityWeb.Endpoint with Bandit 1.12.5 at 127.0.0.1:60534 (http)
TRINITY_SMOKE_PORT=60534
```

**Built natively on Windows and ran under `--no-halt --smoke`, printing its port and exiting
0.** The runner has 7z, so the ERTS unpack that fails here succeeds there.

**One gap in this evidence, stated rather than glossed:** the workflow's "Serves HTTP 200" step
is `if: runner.os != 'Windows'`, so **Windows was never asked to serve**. It booted and exited;
it was not curled. That is a hole in my workflow, not a property of the artifact, and it is a
follow-up.

`ex_tauri`'s fallback path in ADR-0004 remains **untriggered**: its trigger is "Windows fails
with ex_tauri", and the Windows *shell* has still never been attempted.

### Why it is still not built on this machine

```
$ MIX_ENV=prod mix release desktop --overwrite ; echo "exit=$?"
> Burrito is building target: windows_x86_64
--> Remote ERTS From Beam Machine: https://github.com/erlang/otp/releases/download/OTP-28.5.0.5/otp_win64_28.5.0.5.exe
** (RuntimeError) Couldn't find 7z/7zz
    (burrito 1.6.0) lib/util/default_erts_resolver.ex:80: Burrito.Util.DefaultERTSResolver.do_unpack/2
exit=1

$ for c in 7z 7zz 7za 7zr; do command -v "$c" || echo "$c (absent)"; done
7z (absent)
7zz (absent)
7za (absent)
7zr (absent)

$ apt-cache policy p7zip-full | head -2
p7zip-full:
  Installed: (none)
```

The Windows ERTS ships as a `.exe` installer and Burrito unpacks it with 7z. Installing one
needs root, which CLAUDE.md §7 keeps off this agent's hands. `SLICE.md`'s Risks section
predicted this before the slice started.

**The ADR-0004 fallback is untriggered, not eliminated.** Its trigger is "Windows fails with
ex_tauri", and Windows was never attempted, so nothing has been learned about the fallback.

### AC4 [manual] — a native window on Linux

**Not proven — and the reason I gave for it at G1 was wrong.**

The G1 plan and the earlier draft of this file said "no desktop session available on this
machine". Measured:

```
$ echo "DISPLAY=$DISPLAY  XDG_SESSION_TYPE=$XDG_SESSION_TYPE"
DISPLAY=:0  XDG_SESSION_TYPE=x11
```

**There is a display.** This supersedes every earlier line in this slice's records that says
otherwise. AC4 is unproven for two different reasons, and neither is the one I gave:

1. **There is no Tauri project to run.** `SLICE.md` Scope says "run `mix ex_tauri.install`" and
   Deliverables names a `tauri/` scaffold; `git ls-files tauri | wc -l` is `0`. The approved G1
   plan's fifteen lines never included the install step, so the deliverable was dropped at plan
   time and I did not flag it. `mix ex_tauri.dev` has nothing to launch.
2. **The Tauri v2 system libraries are absent** — `libwebkit2gtk-4.1-dev`, `libgtk-3-dev`,
   `libayatana-appindicator3-dev`, `librsvg2-dev`, `patchelf`, none installed, all resolvable in
   this machine's apt, all needing root.

Neither is "no machine". A prepared, step-by-step procedure for the owner is in `NOTES.md`
under "The owner's manual check on this machine", with who runs each step; step 2 is a Question
on the slice issue because `mix ex_tauri.install` is an Igniter task that rewrites tracked
files, and slice 000 has already been bitten once by a generator doing that.

**AC2 and AC3 are unaffected by this correction** — they need a macOS and a Windows machine and
those genuinely do not exist here. **AC4 does not need a machine. It needs the two steps
above**, and saying "no machine" concealed that for the length of this slice.

### AC5 [auto] — binary size and cold-start-to-serving recorded for linux x86_64 in `docs/packaging.md`

```
$ stat -c %s burrito_out/desktop_linux_x86_64
20777960

$ du -sh ~/.local/share/.burrito
88M

$ for i in 1 2 3 4 5; do coldstart.sh; done      # exec to first HTTP 200, ms
231
235
240
237
245

$ rm -rf ~/.local/share/.burrito && coldstart.sh  # first launch of a fresh install
1578
```

**Met.** The table is in `docs/packaging.md`. **Two figures are reported rather than one**:
Burrito extracts its payload into `~/.local/share/.burrito` on first launch, so 1 578 ms is
what a person sees the first time and ~235 ms is every launch after. Reporting only the warm
figure would understate the launch that forms the impression by a factor of six.

### AC6 [manual] — the same figures for macOS and Windows, and cold-start-to-first-paint on any OS

**Partly proven, and the rest is not blocked by what I said it was.** Three sub-claims, three
different answers:

**Per-OS binary size — proven**, by the runners, run `34067973983`:

| OS | Bytes |
|---|---|
| linux x86_64 | 20 790 808 |
| macOS aarch64 | 11 927 096 |
| Windows x86_64 | 24 519 680 |

**Per-OS cold-start-to-serving — not measured.** The jobs launch and curl but do not time the
interval, so there is no macOS or Windows equivalent of AC5's 231–245 ms. That is a gap in my
workflow, not a missing machine: a runner could measure it. Follow-up.

**Cold-start-to-first-paint — needs a window, and the window is not blocked by a missing
machine either.** See AC4's correction: this is an X11 desktop. It is blocked on
`mix ex_tauri.install` never having run and on five apt packages, and it is step 3 of the
owner's prepared procedure in `NOTES.md`, timed from `return` to the window appearing.

Split from AC5 at G1. **Both halves were blamed on missing machines and neither is.**

### AC7 [auto] — running the binary under `--smoke` exits 0 and leaves no process behind

```
$ ps -eo pid,ppid,comm | grep -E 'desktop_linux|beam.smp|erl_child_setup' > before.txt ; cat before.txt
2487028 2485809 beam.smp
2487056 2487028 erl_child_setup

$ ./burrito_out/desktop_linux_x86_64 --no-halt --smoke ; echo "exit=$?"
18:56:11.939 [info] Running TrinityWeb.Endpoint with Bandit 1.12.5 at 127.0.0.1:45031 (http)
TRINITY_SMOKE_PORT=45031
exit=0

$ ps -eo pid,ppid,comm | grep -E 'desktop_linux|beam.smp|erl_child_setup' > after.txt ; cat after.txt
2487028 2485809 beam.smp
2487056 2487028 erl_child_setup

$ diff before.txt after.txt ; echo "exit=$?"
exit=0
```

Corroborated on three runners, run `34067973983` at `c2be3fa`, all green:

| Runner | Artifact | Bytes | Port printed | Served |
|---|---|---|---|---|
| `ubuntu-latest` | `desktop_linux_x86_64` | 20 790 808 | 40877 | HTTP 200 on 43181 |
| `macos-latest` | `desktop_macos_aarch64` | 11 927 096 | 49432 | HTTP 200 on 49433 |
| `windows-latest` | `desktop_windows_x86_64.exe` | 24 519 680 | 60534 | not asked — see AC3 |

Each job compares a filtered process list either side of the exit and fails on any survivor.

**The first run of that workflow failed on all three, and both causes were mine.** `mix
assets.deploy` did not lead with `compile`, so Phoenix 1.8's colocated CSS did not exist on a
clean checkout and the alias resolved only on a machine that had already built (fixed in
`8048ad3`). Then the smoke step diffed the *whole* `ps` table, and a live runner churns between
two samples — macOS on `mdworker_shared` and `CloudTelemetryService`, linux on a `kworker`
kernel thread — while the artifact had launched, served and exited correctly (fixed in
`c2be3fa`). Both were defects in the evidence-gathering, not in the thing being measured, and
neither was findable locally.

Control, which is what makes the local run above mean anything:

```
$ PHX_SERVER=true timeout 20 ./burrito_out/desktop_linux_x86_64 --no-halt ; echo "exit=$?"
exit=124        # 124 is timeout killing it — it was still running
```

**Met, with a correction to how the criterion is worded.** `SLICE.md` AC7 says "running the
binary under `--smoke`". **My first measurement of it was worthless and is recorded here rather
than quietly replaced.** I ran `./burrito_out/desktop_linux_x86_64 --smoke`, got exit 0 and a
clean `ps`, and would have called the criterion met — but the binary exits 0 and leaves nothing
behind **with no flag at all**, because the Elixir CLI halts on an empty command list. That
observation was true and attributed nothing to the code under test.

The form above adds `--no-halt`, which makes staying alive the default, so that exiting is
attributable. **The reviewer should read AC7 as `--no-halt --smoke`.** The two remaining
processes in both listings are this session's own dev BEAM, present before the run started.

### AC8 [manual] — killing the window terminates the sidecar within 5 s

**FALSE, not unproven. Filed as finding F1.**

No window exists to close on this machine, so the criterion cannot be exercised in the form
`SLICE.md` states it. But the property underneath it — that the sidecar dies with its parent —
**has been measured, and it does not hold.** An empty population and a failed property are
different facts (CLAUDE.md §8), and this is the second.

Full transcript, one process, exit codes from the same invocation as their output:

```
$ ps -o pid,ppid,comm -p 2936769 -p 2936771 ; echo "exit=$?"     # BEFORE the kill
    PID    PPID COMMAND
2936769  139843 desktop_linux_x
2936771 2936769 beam.smp
exit=0

$ kill 2936769 ; echo "exit=$?"                                  # SIGTERM to the wrapper only
exit=0

$ ps -o pid,ppid,comm -p 2936769 ; echo "exit=$?"                # the wrapper: gone
    PID    PPID COMMAND
exit=1

$ ps -o pid,ppid,comm -p 2936771 ; echo "exit=$?"                # the BEAM it launched: alive
    PID    PPID COMMAND
2936771  139843 beam.smp
exit=0

$ tr '\0' ' ' < /proc/2936771/cmdline | cut -c1-140 ; echo "exit=$?"
/home/aylac/.local/share/.burrito/desktop_erts-16.4.0.5_0.1.0/erts-16.4.0.5/bin/beam.smp -- -root /home/aylac/.local/share/.burrito/desktop_
exit=0

$ curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:39075/ ; echo "exit=$?"
200
exit=0
```

Five seconds elapsed between the `kill` and the second `ps`, which is the bound the criterion
names.

**The orphan is not merely alive; it is still serving.** That is what makes this a liveness
contract rather than a tidiness problem: a shell that closes its window and kills the wrapper
leaves a Phoenix app listening on the user's loopback with nothing on screen to say so.

**What it was reparented to, stated precisely.** Pid 139843 is the per-user `systemd` instance
acting as a subreaper, not pid 1:

```
$ ps -o pid,ppid,comm -p 139843
    PID    PPID COMMAND
 139843       1 systemd
```

An earlier note in `NOTES.md` said "reparented to init". That is corrected there; the finding
is unchanged, but "init" names a process that was not involved.

**What this build lacks, and it matters to how "false" should be read.** `ex_tauri` ships
`ExTauri.ShutdownManager`, a heartbeat GenServer whose stated purpose is this exact case: the
Rust frontend sends a byte every 100 ms over a Unix domain socket, and the sidecar shuts down
gracefully after 1500 ms without one, "even when the process is killed without cleanup".
`mix ex_tauri.install` adds it to the application's children.

**It is not in this build.**

```
$ grep -n 'ShutdownManager' lib/trinity/application.ex ; echo "exit=$?"
exit=1
```

So the honest statement is narrower than "AC8 is false" and wider than "AC8 is unproven":

- **False, as measured, for the artifact this slice actually produced** — a bare Burrito binary
  with no heartbeat in its supervision tree. Kill the parent and the BEAM serves on.
- **Untested, not broken, for the mechanism `ex_tauri` provides for it.** I have not run
  `ExTauri.ShutdownManager`, and reporting a defect in a mechanism I never installed would be
  the overclaim this project keeps catching.

Both halves are true and neither substitutes for the other. AC8 exits **false**, citing
F1, on the build that exists; the untested heartbeat is the first thing F1 should
measure, and it is not among the candidates that issue currently names.

**Why the mechanism is absent is a gap in this slice, not an oversight of `ex_tauri`'s.**
`SLICE.md`'s Scope says "run `mix ex_tauri.install`" and its Deliverables name a `tauri/`
scaffold. Neither happened:

```
$ git ls-files tauri | wc -l
0
```

The approved G1 plan's fifteen lines never included the install step — line 3 is Burrito wiring
only — so the deliverable was dropped at plan time and I did not flag it. That is mine, and it
is why AC2, AC3 and AC4 could not have been run by anyone this slice: `mix ex_tauri.dev` has no
project to run against.

**Where the fix lives.** Not here. Burrito's wrapper signal handling is upstream behaviour, and
the remedy is Trinity's own liveness contract with its parent — designed and enforced in slice
100 per F1, with `ExTauri.ShutdownManager` measured first rather than assumed.

### AC9 [auto] — `mix gate` still green; `mix phx.server` still works without Tauri

```
$ mix gate ; echo "exit=$?"
Result: 68 passed
trinity.coverage: 001 30.37% vs 000 27.01% — OK
exit=0

$ ./scripts/plan_check.sh ; echo "exit=$?"
plan_check: PASS
exit=0

$ timeout 25 mix phx.server ; echo "exit=$?"
[info] Running TrinityWeb.Endpoint with Bandit 1.12.5 at 127.0.0.1:4000 (http)
exit=124        # still running when the timeout killed it
```

**Met.** The coverage rule was exercised in both directions, since 001 is the first slice with
a previous row to compare against:

```
$ mix trinity.coverage ; echo "exit=$?"          # seeded 4.01 points low
** (Mix) trinity.coverage: 001 23.0% is 4.01 points below 000 27.01%, more than the
   3.0-point tolerance. Name the reason in the slice's NOTES.md.
exit=1

$ mix trinity.coverage ; echo "exit=$?"          # at the measured figure
trinity.coverage: 001 30.37% vs 000 27.01% — OK
exit=0
```

## Reds demonstrated before their fixes

Every claim below was committed failing first, by name, and the fix commit references it.

| Property | Red at | Failure |
|---|---|---|
| Toolchain VERSIONS.md marks are derived from each row's own source | `82e74a3` | 3 of 5 in `VersionsToolchainMarkTest`; `mix test` exit 2 |
| `Trinity.Paths` resolves a distinct root per OS | `ec64ac7` | 3 of 6 in `PathsTest`; three roots collapsed to `["/h/.local/share/trinity"]` |
| The smoke path stops the OS process | `f7406c5` | 1 of 4 in `SmokeTest`; `run/2` returned without calling halt |
| Inline `@sobelow_skip` carries a reason | planted and removed | `["lib/trinity/paths.ex:71"]`; exit 2 |
| The coverage drop rule fires | seeded row | `exit=1` with the arithmetic |

Two of those reds were rejected first for failing at an earlier fault than the claim, per
CLAUDE.md §8, and both are recorded in `NOTES.md`: the `MIX_ENV=prod` release stopped on a
Credo check under `lib/` before it reached anything about releases, and the smoke test returned
`{:error, :no_server_found}` because the test endpoint did not serve.

## Manual verification for the reviewer

Four criteria, and they are **not** one missing thing — that was the framing I carried from G1
and it was wrong twice. AC2 and AC3 need machines. AC4 and AC6's first-paint half need two
steps on *this* machine. AC8 needs a window but is already known to fail underneath.

| AC | Needs | Step | Expected |
|---|---|---|---|
| 2 | a **macOS desktop** | `mix ex_tauri.dev` | a native window showing the scaffold; screenshot to `slices/001-packaging-spike/proof/` |
| 3 | a **Windows desktop** with 7z | `mix ex_tauri.dev` | the same, or a documented failure and the fallback |
| 4 | **not a machine** — `mix ex_tauri.install` (a Question, step 2) plus five apt packages (root, step 1) | `mix ex_tauri.dev` on this X11 desktop | a native window showing the scaffold |
| 6 | **size: done** by the runners. **First paint:** the same two steps as AC4, on this desktop | a stopwatch from `return` to the window painting | one first-paint figure for `docs/packaging.md` |
| 8 | any one of the three desktops | close the window, watch `ps` | sidecar gone within 5 s — **expect this to fail**, see AC8 |

Plus one that needs no machine, only a remote:

| AC | Needs | Step | Expected |
|---|---|---|---|
| 5 | ~~the GitHub Actions run~~ | **done** — run `34067973983` at `c2be3fa`, three jobs green | nothing left for the owner here beyond confirming the run |

`.github/workflows/package.yml` **has now run, green on all three OSes** — run `34067973983`
at `c2be3fa`. An earlier version of this paragraph said it "has never run", which was true when
written and is superseded here. Its first two runs failed, on two defects of mine that no local
run could have surfaced; both are recorded under AC7.

**A runner still cannot produce a screenshot of a real window on a real desktop**, and no
artifact from one is offered here as though it had. Every job says so in its own summary.

## Deviations from SLICE.md

**Six**, and the count is derived, not typed:

```
$ grep -c '^### D[0-9]' slices/001-packaging-spike/NOTES.md
7
$ grep -n '^### D[0-9]' slices/001-packaging-spike/NOTES.md | cut -d: -f1,2
190:### D1 …  223:### D2 …  262:### D3 …  319:### D4 …  346:### D5 …  353:### D6 …
756:### D4 — accepted (the owner's decision on D4, not a seventh deviation)
```

Seven headings, six deviations: D4 appears twice, once as the deviation and once as the
owner's acceptance of it. **An earlier version of this line said "nine", typed from memory
against no command.** That is the defect CLAUDE.md §8 names — values come from the tree or the
owner — and it was in the section listing my deviations.

All six are in `NOTES.md` with their measurements, all recorded before the commits that carried
them. The four that most change what a reader should expect:

1. **Rust is pinned in `rust-toolchain.toml`, not `.tool-versions`.** `asdf` here has no rust
   plugin and does not fail on a tool it has no plugin for — it omits the line from
   `asdf current` and exits 0. A `rust 1.92.0` line there would pin nothing.
2. **The Tauri CLI's deriving command is `_build/_tauri/bin/cargo-tauri tauri --version`.**
   `cargo tauri --version` exits 101; `ex_tauri` installs the CLI into `_build/_tauri`, which is
   gitignored, so no file in the tree pins it and its VERSIONS.md row is marked 📐, never ✅.
3. **A fourth non-hex pin the plan did not anticipate: Zig, exactly 0.16.0.** Burrito 1.6.0
   compares for equality, not a range.
4. **The slice-000 Credo check had to move out of `lib/`.** `credo` is `only: [:dev, :test]` and
   `lib/` compiles in every environment, so nothing compiled under `MIX_ENV=prod` at all. This
   is a change outside packaging by the letter of the plan's constraint. **The owner accepted
   it on 2026-09-06 as a packaging prerequisite** — a spike that cannot compile for prod has
   not spiked — with a principle attached that is a correction to how I worked rather than to
   the code: *post the Question, then proceed in parallel with the work that does not depend on
   the answer; commit first and ask second is the wrong order even when the call is right.* I
   did the second thing, and raised it at G3 with eight commits already standing on it.

`SLICE.md`'s acceptance criteria were themselves retagged at G1 (line 2, commit `afca47d`):
seven criteria became nine, AC4 moved `[auto]` → `[manual]`, and AC5 and AC6 were each split
into an auto half and a manual one.

## Versions touched

`VERSIONS.md` updated: **yes**, regenerated by `mix versions.gen` from `lib/trinity/versions.ex`.

- `burrito` `~> 1.6` → ✅ in `mix.lock` at 1.6.0. Now a **direct** dependency: `&Burrito.wrap/1`
  runs under `MIX_ENV=prod` and the burrito `ex_tauri` brings is `only: :dev`.
- `ex_tauri` `~> 0.2` → ✅ in `mix.lock` at 0.2.0.
- `Rust` **1.92.0** → ✅ `rust-toolchain.toml`.
- `Zig` **0.16.0** → ✅ `.tool-versions`.
- `Tauri CLI` **2.11.4** → 📐 `_build/_tauri/bin/cargo-tauri tauri --version`.
- `asdf` → 📐 `asdf --version`; it cannot pin itself.

The row `Rust + Tauri CLI | stable | ✅ .tool-versions` is gone, and it was wrong on every
count: two tools in one row, an unmeasured pin, and a ✅ naming a file carrying neither name.
`mix versions.gen`'s toolchain mark is no longer a constant — each row states a `:from`, and a
row naming a file that stops carrying its pin now marks ❌ and fails the gate.

`mix hex.outdated` was not run this slice. `mix hex.audit` and `mix deps.audit` are gate steps
and both passed.

## Git

```
$ git log --oneline main..HEAD
e7202f4 docs(s001): CI ran — AC2 and AC3 upgrade from "never executed" to "built and run on a runner"
c2be3fa ci(s001): the smoke step diffed the whole process table, not ours
f8d1271 docs(s001): owner decisions recorded, AC8 false citing F1, and AC4's stated reason corrected
5b17e30 fix(s001): the rule-7 correction note quoted the identifier it was correcting
e25048f fix(s001): cite the wrapper finding as F1, not by board id — plan_check rule 7
8048ad3 fix(s001): assets.deploy did not compile first, so it failed on every clean checkout
0326dea ci(s001): package workflow never ran — its push trigger excluded slice branches
b30c6ad feat(s001): complete slice 001 — packaging spike (Burrito + ex_tauri)
263c96f docs(s001): lines 8-14 — packaging doc, package workflow, ADR-0004 correction, coverage row
5a9c8f7 feat(s001): line 5 — the --smoke boot path, and the runtime config a double-clicked binary needs
f7406c5 test(s001): line 5 — the smoke path never stops itself, committed failing
1d74cb2 feat(s001): line 4 — Trinity.Paths resolves a distinct root per OS
ec64ac7 test(s001): line 4 — Trinity.Paths first pass collapses three OS roots into one, committed failing
7a41cb2 feat(s001): line 3 — Burrito wiring, and toolchain marks derived from their own source
82e74a3 test(s001): line 3 — toolchain marks are not derived, committed failing
afca47d docs(s001): line 2 — acceptance criteria retagged, AC5 and AC6 split
d1b72d7 feat(s001): line 1 — ex_tauri measured on the pinned toolchain, no refusal
13c5b3f docs(s001): G1 plan v2
c1b14ad docs(s001): G1 plan
537bd3a docs(s001): status in_progress, and plan_check rule 11 — the lifecycle enforcer
```
