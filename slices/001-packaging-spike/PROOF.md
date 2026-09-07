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

**The shell half is real now.** `mix ex_tauri.install` ran at G4 (`db14cd7`), the Linux shell
compiles, and **the owner opened a native window titled Trinity showing the Phoenix scaffold on
this machine**. First paint 2–3 s. The screenshot is under `proof/` with its digest. That is
**AC4 proven** — the first window in this project on any OS.

**Two criteria still need a machine that is not this one: AC2 and AC3**, for a window on macOS
and on Windows. Both artifacts build and run on runners; neither has been shown in a window.

**AC8 is the one to read carefully, and it is not simply "passes".** Through the window on the
dev path the sidecar dies in **14–19 ms** against a 5 000 ms bound. But the heartbeat's 1500 ms
timer never fired, `SIGKILL` gives the same figure as `SIGTERM`, and **the production sidecar is
a different process shape** — three runs of it orphan past 7.6 s, still answering HTTP 200, with
the heartbeat compiled in. Finding **F1 stands**, and what closes it is a measurement this slice
did not make.

**ADR-0004 is still not confirmed.** Its exit condition is a running smoke build on macOS *and*
Windows, which the runners now give for the sidecar — but its subject is the desktop **shell**,
and the shell has been *run* on exactly one OS, this one, by the owner. macOS and Windows
compile it and have never launched it.

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
plan_check: PASS
exit=0
```

**One command, one exit code**, since G4 item 3. `scripts/plan_check.sh` is the gate's final
step. It used to be a second command with a second exit code, and three times in this slice the
gate's `exit=0` was read while `plan_check exit=1` on the line below it was not; twice that
reached the remote. Demonstrated with a planted rule-7 violation: `mix gate` alone exits 1 and
prints the `FAIL` line, and exits 0 after removal. `test/gate_alias_test.exs` asserts
`plan_check.sh` is the **last** step and appears exactly once.

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

**Windows has still never been observed serving, and it is the one CI question this slice does
not answer.** At G3 the reason was that the step carried `if: runner.os != 'Windows'`. At G4
that condition is gone and the step runs everywhere, but three further defects — all mine, all
Windows-only — have stood between it and an answer: a git `sparse` dependency Mix refused under
`:prod`, an unbounded `curl` loop, and `kill` from Git-bash failing to stop a native Windows
process so the job hung twice and was cancelled by hand. Each is fixed and pushed. **Linux and
macOS pass the same step**, so the step itself works.

The artifact's own evidence does not rest on that: it builds on the runner, it builds here, and
it boots and exits under `--smoke`. What is unproven is that it *serves*, on Windows, and it is
recorded as unproven rather than assumed from the other two runners.

`ex_tauri`'s fallback path in ADR-0004 remains **untriggered**: its trigger is "Windows fails
with ex_tauri", and the Windows *shell* has still never been attempted.

### Built on this machine too, since the owner installed 7z

```
$ BURRITO_TARGET=windows_x86_64 MIX_ENV=prod mix release desktop --overwrite ; echo "exit=$?"
--> Going to recompile NIF for cross-build: exqlite -> x86_64-windows
--> Successfully re-built exqlite for x86_64-windows!
info: Archived 2189 files into payload! 📦
exit=0

$ stat -c '%n %s' burrito_out/desktop_windows_x86_64.exe
burrito_out/desktop_windows_x86_64.exe 27316224
```

**AC3 reads "built here and on a runner, window unproven."** Not "runs": nothing on this machine
can execute a Windows binary, and the runner's `--smoke` is what shows it runs.

### Why it was not built here until G4

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

**PROVEN, 2026-09-07, by the owner on this X11 desktop.**

```
$ mix ex_tauri.dev
```

opened a window titled **Trinity** showing the Phoenix scaffold. Screenshot:

```
slices/001-packaging-spike/proof/ac4-linux-window.png
  2814779 bytes, PNG 7680x2160
  sha256 e52785ce61ea9f69615ffa7602f7fd172b1fa5a310d8b69b1b11f7fc09bfabe7
```

**The size and digest are here because of what nearly went in instead.** My handover step used
`import -window "$(xdotool search --name '^Trinity$' | head -1)"`; `xdotool` is absent, so the
`-window` argument was empty and `import` wrote a **185-byte stub** — a file that exists, is
named like evidence, and contains nothing. It would have satisfied every check this project
has: the path is right, `trinity.reuse` covers it, nothing reads its contents. The owner
re-took it with `-window root`. **A screenshot is the one artefact here whose correctness no
enforcer can see, so it carries its digest.**

The prerequisites that made this possible, and both were mine to have found earlier: the owner
installed five Tauri v2 libraries (root), and `mix ex_tauri.install` had never been run — see
the correction below, which stands.

#### The correction that stood before it, kept

**The reason I gave for AC4 at G1 was wrong.**

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
21398872          # 20777960 before D7 put ex_tauri in :prod; +620912, +3.0%

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

**Per-OS binary size — proven**, by the runners. Two sets of figures, because D7 changed what
is in the binary between them:

| OS | run `34067973983`, before D7 | run `34075257183`, after D7 |
|---|---|---|
| linux x86_64 | 20 790 808 | 21 298 216 |
| macOS aarch64 | 11 927 096 | 12 435 992 |
| Windows x86_64 | 24 519 680 | — see AC3 |

The later column is the artifact this slice ships. Both are kept rather than the first being
overwritten: the difference is `ex_tauri` and its dependency tail entering `:prod`, and a reader
comparing sizes across slices needs to know a dependency moved rather than the code growing.

**Per-OS cold-start-to-serving — measured, at G4 item 2**, run `34075257183`:

| OS | exec to first HTTP 200 |
|---|---|
| linux x86_64 | **699 ms** |
| macOS aarch64 | **1 416 ms** |

The jobs previously launched and curled without timing the interval, and Windows was never
curled at all (`if: runner.os != 'Windows'`). Both were holes in `package.yml` rather than
missing machines.

**These are not comparable with AC5's 231–245 ms.** That figure is a warm launch on this
machine with the Burrito payload already extracted; a runner is cold every time, so 699 ms is
the runner's equivalent of AC5's 1 578 ms first-launch figure, not of its warm one. Reporting
them in one column would invite exactly that mistake.

**Cold-start-to-first-paint — PROVEN on Linux, 2026-09-07.** The owner timed **2–3 seconds**
from pressing Enter on `mix ex_tauri.dev` to the scaffold appearing in the window. Timed by hand,
which is the only way a first paint can be timed, and stated to the precision it was taken at.
It exists for one OS; macOS and Windows would each need their own window.

Split from AC5 at G1. **Both halves were blamed on missing machines and neither was blocked by
one** — the size half was answered by runners and the paint half by this desktop, once the two
steps AC4 names were done.

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

**Measured through a real window at G4. It passes on the dev path, by a mechanism Trinity does
not own, and the production sidecar still orphans. Finding F1 stands.**

#### Through the window: the owner's close

```
# before closing, window open
 966625  966348 beam.smp            125     <- mix ex_tauri.dev
 966776  966653 cargo-tauri         125
 966847  966776 trinity             125     <- the Rust window
 967584  966847 beam.smp            123     <- the sidecar
 2487028 2485809 beam.smp          14543    <- the owner's own session

# after closing with the window's ✕
 2487028 2485809 beam.smp          14603    <- same pids, older etimes
 2487056 2487028 erl_child_setup   14603
```

Shell, sidecar and dev task all gone. **My stated pass condition was wrong**: I told the owner
`exit=1` from the `grep` was the pass, but the pattern matches `beam.smp` and their own session
runs one, so it could never be reached. The recorded check excludes those pids instead of
relying on an unreachable exit code.

#### The 5-second bound, six runs

Kill the `trinity` window process, poll until the sidecar's `beam.smp` is gone:

```
$ SIG=-TERM heartbeat.sh      19 / 15 / 14 ms
$ SIG=-KILL heartbeat.sh      16 / 15 / 14 ms
```

**14–19 ms against 5 000 ms.** Three hundred times the margin.

#### It is not the heartbeat

`ExTauri.ShutdownManager`'s timeout is 1500 ms, and every figure is two orders of magnitude
under it, so **the timer never fired**. `SIGKILL` matching `SIGTERM` rules out graceful cleanup
by the Rust process, which under `-KILL` runs none. What ends it is the stdio pipe closing when
the parent dies — **the first of the two candidates F1 already names**, occurring by accident of
how Tauri spawns a child rather than by anything Trinity does.

#### The dev sidecar is not the production sidecar

```
$ cat burrito_out/desktop-x86_64-unknown-linux-gnu
#!/bin/sh
cd "/home/aylac/Projects/Trinity" || exit 1
exec mix phx.server
```

Development spawns a shell script running `mix phx.server`. **Production spawns the Burrito
binary** — a wrapper with a BEAM child. Three runs on that shape, killing the wrapper as Tauri
does to its sidecar:

```
waited_ms=7673  ORPHAN beam=1012739 ppid=139843  still_serving=200
waited_ms=7726  ORPHAN beam=1014123 ppid=139843  still_serving=200
waited_ms=7605  ORPHAN beam=1015406 ppid=139843  still_serving=200
```

**Orphaned every time, past 7.6 s, still answering HTTP 200** — with the heartbeat compiled in,
since D7 put `ex_tauri` in `:prod`. It does not arm its timeout until the frontend has connected
once, and no frontend connected there.

#### What is not established

**A production sidecar whose window attached and then closed** — where the heartbeat would be
armed. Two attempts to form that process tree failed mechanically: Tauri's dev mode waits on
`devUrl` before launching, and the second attempt matched WebKit's process rather than the
sidecar. **That is the measurement that decides F1, and this slice did not make it.**

**Across every measurement in this slice the heartbeat's timer has never been observed to fire.**
Either something faster kills the sidecar, or nothing does.

#### Verdict

AC8 **passes on the dev path** and the criterion's own wording — a window, a close, `ps` — is
satisfied there. It is **not** satisfied for the artifact this slice ships, and F1 is not
closed. Slice 100 owns it, and what it must guarantee is not "add the heartbeat" — that is
already added and has never once been the mechanism that worked.

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

**Two criteria, and both need a machine that is not this one.** At G3 this table had five rows
and I described them as "one missing thing"; three of those five turned out not to need a
machine at all, and the two that did are below.

| AC | Needs | Step | Expected |
|---|---|---|---|
| 2 | a **macOS desktop** | `mix ex_tauri.dev` | a native window showing the scaffold; screenshot to `slices/001-packaging-spike/proof/` |
| 3 | a **Windows desktop** | `mix ex_tauri.dev` | the same, or a documented failure and the fallback |

**Closed since G3, and how:**

| AC | Was | Closed by |
|---|---|---|
| 4 | "unproven: no machine" | the owner, on this X11 desktop, once `mix ex_tauri.install` had run and five apt packages were in. **Proven**, with a screenshot. |
| 5 (CI) | "the GitHub Actions run" | `package` run `34067973983`, three jobs green |
| 6 size | "a macOS and a Windows machine" | the runners |
| 6 first paint | "no window" | the owner: 2–3 s |
| 8 | "false, needs a desktop" | measured through the owner's window and in six timed runs — see AC8 |

`.github/workflows/package.yml` has run green on three OSes. It has **not** run in its G4 form,
which adds the shell build, the Windows curl and the cold-start timer.

**A runner still cannot produce a screenshot of a real window on a real desktop.** Exactly one
such screenshot exists in this project: the owner's, on Linux, at
`slices/001-packaging-spike/proof/ac4-linux-window.png`.

## Deviations from SLICE.md

**Seven**, and the count is derived, not typed:

```
$ grep -c '^### D[0-9]' slices/001-packaging-spike/NOTES.md
8
$ grep -n '^### D[0-9]' slices/001-packaging-spike/NOTES.md
190:### D1   223:### D2   262:### D3   319:### D4   346:### D5   353:### D6   995:### D7
756:### D4 — accepted (the owner's decision on D4, not an extra deviation)
```

Eight headings, **seven deviations**: D4 appears twice, once as the deviation and once as the
owner's acceptance of it. **An earlier version of this line said "nine", typed from memory
against no command.** That is the defect CLAUDE.md §8 names — values come from the tree or the
owner — and it was in the section listing my deviations.

All seven are in `NOTES.md` with their measurements, all recorded before the commits that
carried them. **D7 is the one added at G4 and the one that most changes the artifact:**

0. **`ex_tauri` is a dependency of every environment, not `only: :dev`** (D7). `mix
   ex_tauri.install` adds `ExTauri.ShutdownManager` to the supervision tree unconditionally,
   and on a dev-only dependency the app cannot start in `:test` or `:prod`. The generator is
   right: the heartbeat is the window's only channel for telling the BEAM it has closed, so it
   must be in the binary that ships. `only: :dev` would have shipped F1's failure mode as a
   permanent property of every release. **This supersedes what line 1 recorded as "the
   configuration"**, which answered a different question correctly. The exclusion from `:test`
   is compile-time, not `Code.ensure_loaded?/1`, because that guard cannot tell an intended
   exclusion from a dropped dependency.

The four from earlier that still change what a reader should expect:

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
94e6c4e feat(s001): G4 items 2-4 — shell in CI, plan_check inside the gate, Windows built here
e5ca724 feat(s001): measure AC8's bound — it passes on the dev path and fails on the production shape
5c3afd9 feat(s001): AC4's screenshot, and the .gitignore rule that named a directory that never existed
b7cf84d docs(s001): item 1 prepared — the owner's launch, timing, screenshot and ps steps
df70f2c fix(s001): a6085b3 said Cargo.lock was added to REUSE.toml; it was not
a6085b3 feat(s001): the Linux Tauri shell builds; track src-tauri/Cargo.lock
6f9292b fix(s001): ex_tauri in every environment — the heartbeat has to be in the shipped binary
db14cd7 feat(s001): mix ex_tauri.install — the generator's output, nothing else
35fc4b5 docs(s001): D4 in PROOF still asked the owner to accept what they had accepted
0e4e926 docs(s001): the summary said three criteria need a machine; two do
09fdf74 docs(s001): four stale claims in PROOF.md, including a typed count in the deviations section
24323cf docs(s001): PROOF summary contradicted its own AC2 and AC3 after the CI run
183873d docs(s001): PROOF.md header and git log name the real shas
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
