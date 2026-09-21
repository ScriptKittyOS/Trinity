<!--
SPDX-FileCopyrightText: Sudo Apt Holdings LLC
SPDX-License-Identifier: Apache-2.0
-->

# Packaging Trinity as a desktop binary

Written at Slice 001, the packaging spike. Every number and every command in this file was run
on the machine described under [Prerequisites](#prerequisites) on 2026-09-06; nothing is
quoted from a README. Where a thing was not measured, this file says so rather than estimating.

The commands are `mix release` and Burrito. The Tauri shell is Slice 100's; what this file
covers is the half a command can answer: a single binary that boots, serves and stops.

## Prerequisites

| Tool | Version | Pinned in | Why exactly this |
|---|---|---|---|
| Erlang/OTP | 28.5.0.5 | `.tool-versions` | The newest OTP whose ERTS Burrito can fetch for all four targets. See `docs/adr/0005-otp-pin-driven-by-packaging.md`. |
| Elixir | 1.20.4-otp-28 | `.tool-versions` | |
| Zig | **exactly** 0.16.0 | `.tool-versions` | Burrito 1.6.0 compares for equality, not a range, and exits 1 on anything else. Installed with the asdf zig plugin. |
| Rust | 1.92.0 | `rust-toolchain.toml` | Only for the Tauri shell. **Not** `.tool-versions`: asdf here has no rust plugin and ignores such a line silently, so it would be a pin that pins nothing. `rustup` honours this file. |
| Tauri CLI | 2.11.4 | nothing in the tree | `ex_tauri` installs it into `_build/_tauri`, which is gitignored. `cargo tauri --version` exits 101 on a fresh machine; the real command is `_build/_tauri/bin/cargo-tauri tauri --version`. |
| 7z or 7zz | any | none | **Windows target only.** Absent on the build machine, so the Windows target is unbuilt here. See [Targets](#targets). |

`VERSIONS.md`'s toolchain table carries the same figures with a mark that names where each one
came from, and `mix versions.gen --check` fails the gate if the table and
`lib/trinity/versions.ex` disagree.

## Build

```
mix deps.get
mix assets.deploy                        # required: config/prod.exs sets cache_static_manifest
BURRITO_TARGET=linux_x86_64 MIX_ENV=prod mix release desktop --overwrite
```

Three gotchas, all measured, all of which cost time before they were understood:

1. **`--overwrite` is not optional in a script.** Without it, and with a release directory
   already present, `mix release` prompts `Overwrite? [Yn]`, receives no stdin, and **exits 0
   having built nothing.** A CI job that omits it reports success on a stale artifact.
2. **`mix assets.deploy` must run first.** `config/prod.exs` sets `cache_static_manifest`, and
   the endpoint raises at boot without `priv/static/cache_manifest.json`. That task also writes
   a digested copy and a `.gz` sibling next to every static file; both are gitignored.
3. **`BURRITO_TARGET` selects one target** out of those declared in `mix.exs`. Without it,
   Burrito builds all three and the run fails on the first target whose host prerequisites are
   missing: for this machine, Windows.

## Run

```
PHX_SERVER=true ./burrito_out/desktop_linux_x86_64 --no-halt      # serves until stopped
./burrito_out/desktop_linux_x86_64 --no-halt --smoke              # boots, prints its port, exits 0
```

**`--no-halt` is mandatory and is easy to omit.** Burrito launches the release as
`erl … -noshell -s elixir start_cli … -extra <argv>`
(`deps/burrito/src/erlang_launcher.zig`). `elixir start_cli` is the ordinary Elixir CLI entry
point, and it halts when its command list is empty, exactly as `elixir -e ''` does. Without
`--no-halt` the binary starts the endpoint and then exits immediately, and it exits **0**, so
nothing downstream notices.

`--smoke` boots the app, asks the endpoint which port Bandit actually bound, prints
`TRINITY_SMOKE_PORT=<port>` as a single key=value line a shell can `cut`, and halts the OS
process. It is the only part of "the desktop app works" that a terminal can answer on a machine
with no display.

As built at slice 032, `TRINITY_SMOKE=1` in the environment asks for the same run and is the form
the package workflow uses: `Kernel.CLI` reads the plain arguments once the application has started
and treats `--smoke` as a file to run ("No file named --smoke", exit 1), a race the halting Task
lost on macOS in run 35608084951. The run prints five lines: the port, the markdown renderer
(slice 013), whether the EXLA NIF loaded (`TRINITY_SMOKE_EXLA`, recorded), a fake-vector search
through the vector store in force on the binary's own database, rolled back (`TRINITY_SMOKE_VEC`,
binding: exit 4), and the semantic tier's status (`TRINITY_SMOKE_SEMANTIC`, recorded). Slice
032's PROOF.md AC7 has each bundle's answers.

## Measurements: linux x86_64 only

Machine: Linux 6.14.0-37-generic, x86_64. **These figures are for this host and this target.**
Slice 001 AC6 asks for the same figures on macOS and Windows and they do not exist, because
those machines do not exist here.

| Measurement | Value | Command |
|---|---|---|
| Binary size | **20 777 960 bytes** (19.8 MiB) | `stat -c %s burrito_out/desktop_linux_x86_64` |
| Extracted payload on disk | **88 MB** | `du -sh ~/.local/share/.burrito` |
| Cold start to first HTTP 200, warm | **231, 235, 237, 237, 240, 245 ms** (6 runs) | exec to first `curl` success, `date +%s%N` either side |
| Cold start to first HTTP 200, **first run of a fresh install** | **1 578 ms** | the same, after `rm -rf ~/.local/share/.burrito` |

The first-run figure is the one a user sees once. Burrito unpacks its payload into
`~/.local/share/.burrito` on first launch and reuses it afterwards, so the 1.6 s is extraction
and the ~235 ms is every launch after that. Reporting only the warm figure would flatter the
binary by a factor of six on the one launch a person forms an impression from.

**Cold start to first *paint* is not measured and is not in this table.** First paint needs a
window. See AC6.

### Process behaviour

```
$ ps -eo pid,ppid,comm | grep -E 'desktop_linux|beam.smp|erl_child_setup'   # before
2487028 2485809 beam.smp
2487056 2487028 erl_child_setup

$ ./burrito_out/desktop_linux_x86_64 --no-halt --smoke ; echo "exit=$?"
TRINITY_SMOKE_PORT=45031
exit=0

$ ps -eo pid,ppid,comm | grep -E 'desktop_linux|beam.smp|erl_child_setup'   # after
2487028 2485809 beam.smp
2487056 2487028 erl_child_setup

$ diff before.txt after.txt ; echo "exit=$?"
exit=0
```

The `--no-halt` in that command is what makes the exit mean anything: staying alive is then the
default, so exiting is attributable to `--smoke` rather than to the CLI halting on its own.

**One known defect, and it is not fixed here.** The wrapper does not forward termination to the
BEAM it launched. `kill <wrapper pid>` leaves `beam.smp` running, reparented to init:

```
$ tr '\0' ' ' < /proc/2765267/cmdline
/home/aylac/.local/share/.burrito/desktop_erts-16.4.0.5_0.1.0/erts-16.4.0.5/bin/beam.smp -- -root …
```

That is the failure mode AC8 describes (closing the window should stop the sidecar), reached
by signal rather than by window. The fix belongs in the wrapper or in a supervisor around it,
neither of which is packaging wiring, so Slice 001 records it and Slice 100 owns it.

## Targets

Declared in `mix.exs`. Built here: one of three.

| Target | Built on this machine | Built and run on a runner | Blocker here |
|---|---|---|---|
| `linux_x86_64` | **yes**, 20 777 960 bytes | **yes**, 20 790 808 bytes, served HTTP 200 | none |
| `macos_aarch64` | **cross-compiles** only, 13 782 104 bytes, unsigned, never executed | **yes**, natively, 11 927 096 bytes, served HTTP 200 | Nothing here can execute a macOS binary. |
| `windows_x86_64` | **no** | **yes**, natively, 24 519 680 bytes, booted and exited under `--smoke`; not asked to serve | `** (RuntimeError) Couldn't find 7z/7zz`, the Windows ERTS ships as a `.exe` installer and Burrito unpacks it with 7z. None of `7z 7zz 7za 7zr` is installed and installing one needs root. |

Runner evidence: `package` run `34067973983`, three jobs green.

That `macos_aarch64` links under Zig here is a fact about the cross-compiler and **nothing about
whether the macOS app runs**: the runner is what established that it runs. The 11 927 096-byte
native build and the 13 782 104-byte cross build are different artifacts and are listed
separately rather than averaged into one number.

**No window has been opened on any of the three.** A runner has no desktop session, and every
job says so in its own summary.

## What a CI runner proves, and what it cannot

`.github/workflows/package.yml` runs the build on three runners. The distinction below is the
whole point of that workflow, and it is stated so that no artifact from it is offered as
something it is not.

**A runner proves:**

- the artifact **builds** on that OS, with that toolchain, from a clean checkout;
- the artifact **launches** and reaches serving, because the job curls the port `--smoke`
  printed and fails on anything but 200;
- the artifact **exits by itself** under `--no-halt --smoke`, and the job compares `ps` either
  side of the exit;
- a **launch log**, kept as an artifact.

**A runner cannot prove, and no job here will claim:**

- that a **native window opens** on a real desktop. A GitHub runner has no desktop session; on
  ubuntu-latest the job says which of two things it did: the shell under `xvfb-run`, or the
  sidecar smoked alone with no display at all, and never leaves that ambiguous.
- **first paint**, or anything else measured from pixels;
- that **closing a window** stops the sidecar;
- anything about **signing or notarisation**, which is Slice 101's.

A screenshot of a real window on a real desktop does not exist for macOS, Windows or Linux, and
Slice 001 exits saying so rather than counting those criteria as met.


## Native code in the bundle (slice 013)

Burrito's Linux ERTS is a musl build, and every NIF in the bundle has to be one too. Burrito cross-compiles C
NIFs (exqlite) with Zig by itself; a Rust NIF it does not touch. `mdex_native` (the markdown renderer's core)
ships precompiled artifacts, and neither the gnu nor the musl one loads in that ERTS: both need glibc's
`libgcc_s.so.1` (`_dl_find_object: symbol not found`). The linux package therefore builds it from source for
`x86_64-unknown-linux-musl` with Zig as the linker:

```
MDEX_NATIVE_BUILD=1 TRINITY_NIF_TARGET=x86_64-unknown-linux-musl \
CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER=$PWD/scripts/zig-cc-musl \
MIX_ENV=prod BURRITO_TARGET=linux_x86_64 mix release desktop --overwrite
```

`rust-toolchain.toml` names the musl target so rustup installs its standard library; `rustler` is a build-time
dependency for this alone. The result needs `libc.so` only (`readelf -d`), the same shape as the exqlite NIF.
macOS and Windows load the precompiled artifact for their native ERTS. Whether it loaded is not inferred from
a boot: `--smoke` prints `TRINITY_SMOKE_MARKDOWN=ok` after rendering one line through the NIF and exits 3
otherwise, and the `package` workflow's smoke step reads that line on every target.

Two things measured on the way (slice 013 NOTES.md, findings 12 to 14): Burrito reuses the payload it
extracted to `~/.local/share/.burrito/<name>_erts-<v>_<app v>` for as long as the app version stays the same,
so a local run of a new binary at the same version runs the old code until that directory is removed; and the
Burrito wrapper starts `erlexec` directly, so `RELEASE_NAME` is unset in the packaged app (the migrator no
longer keys on it).

## FIPS mode (slice 003)

The desktop bundle above does not run in FIPS mode: its ERTS is Burrito's prebuilt one, and whether Burrito can
wrap an ERTS built with `--enable-fips` is slice 100's question. What the tree proves about the mode it proves
on the gate's `fips` job: OTP built from source with `--enable-fips` against a UBI9 container's OpenSSL, the
whole gate run with the mode on, and the algorithms the mode removes listed in the tree. `docs/fips-leg.md` has
the image, how the mode is entered, the diff, and the findings (two of them about reaching hex.pm and GitHub
from inside the mode).
