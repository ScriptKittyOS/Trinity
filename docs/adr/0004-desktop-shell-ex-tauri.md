# ADR-0004 — Desktop shell: ex_tauri (Tauri 2 + Burrito sidecar), decided by the Slice 001 spike
Status: proposed → to be confirmed by Slice 001 · Date: 2026-09-05

## Context
Options: ex_tauri, hand-rolled Tauri sidecar, elixir-desktop (wxWidgets), Electron, local server + tray.
ex_tauri offers tray/notifications/dialogs from Elixir, heartbeat cleanup, and Burrito packaging, but its site
lists macOS and Linux only; Windows is unverified. elixir-desktop supports Windows but lists signing/auto-update
as roadmap items.

## Decision (provisional)
Target ex_tauri. Slice 001 must produce a running smoke build on macOS **and** Windows (and Linux if available).
If Windows fails with ex_tauri, fall back to a hand-rolled Tauri sidecar (the phoenix_tauri pattern) and record it
here as the final decision. elixir-desktop is the third option. Local-server+tray remains the dev/CI mode always.

## Consequences
- Slice 001 is early and blocking for the desktop phase precisely to surface this risk.
- All desktop OS integration goes through `Trinity.Desktop` behaviour so the shell can be swapped.

---

## Correction, 2026-09-06 — Slice 001. **Not confirmed. Status stays `proposed`, and the reason is stated.**

**This supersedes the status line at the top of this file only in what it explains, not in what
it says: the status is still `proposed`.** Slice 001 was supposed to end this ADR. It does not,
and stamping `accepted` on it would be the defect this project keeps catching — a mark whose
meaning is assumed rather than measured.

### What this ADR's own decision demanded

> Slice 001 must produce a running smoke build on macOS **and** Windows (and Linux if
> available).

Neither exists. What follows is what was measured instead, so the next person reads facts and
not a status word doing work the facts do not support.

### Measured, and it does resolve part of the question

**`ex_tauri` 0.2.0 runs on the pinned toolchain.** ADR-0005 pins OTP 28.5.0.5 and `ex_tauri`
declares `otp_release: "~> 27.0"`, which read like a refusal. It is not one. That key is
declarative metadata — Mix enforces `:elixir` as a version requirement and has no built-in
`:otp_release` enforcement — and the behaviour lives in a runtime check on
`:erlang.system_info(:otp_release)` with three branches: below 27 raises, **above 27 warns**,
27 is silent. On OTP 28 it warns and continues.

```
$ mix deps.compile ; echo "exit=$?"
exit=0
$ mix run -e 'ExTauri.TaskHelpers.check_otp_version()' ; echo "exit=$?"
Warning: ExTauri targets OTP 27 but you are running OTP 28. …
exit=0
```

The warning's stated reason — "Burrito may not have pre-compiled ERTS for OTP 28 yet" — is
refuted by ADR-0005's second correction, which measured the opposite: Burrito 1.6.0 **can**
fetch OTP 28 ERTS for all four targets and **cannot** fetch OTP 27 for macOS or Linux.

**Burrito packages the app on Linux, and it serves.** `BURRITO_TARGET=linux_x86_64 MIX_ENV=prod
mix release desktop --overwrite` exits 0 and produces one statically linked 20 777 960-byte
ELF; `curl` against the port it prints returns 200. Figures and commands are in
`docs/packaging.md`.

### Not measured, and why each one is not

| ADR-0004 asked for | State | Why |
|---|---|---|
| Running smoke build on **macOS** | **not done** | The `macos_aarch64` target cross-compiles under Zig, unsigned. Nothing here can execute it. That it links says nothing about whether it runs. |
| Running smoke build on **Windows** | **not built** | Burrito unpacks the Windows ERTS `.exe` with 7z; no `7z`/`7zz`/`7za`/`7zr` is installed and installing one needs root. |
| A native window on any OS | **not done** | The owner's only machine is Ubuntu with no desktop session in use. |

The fallback path this ADR names — hand-rolled Tauri sidecar, then elixir-desktop — is
**untriggered**, because its trigger is "Windows fails with ex_tauri" and Windows was never
attempted. **The alternatives table above is kept, as it must be:** the next person to reach
this decision needs it, and nothing here has eliminated an option.

### One defect found that this ADR should carry

The Burrito wrapper does not forward termination to the BEAM it launches: `kill <wrapper pid>`
leaves `beam.smp` running, reparented to init. Whatever shell is chosen has to answer for that,
because "closing the window stops the sidecar" is a requirement of all three alternatives, not
of `ex_tauri` in particular.

### Lift condition

**Owner: Ayla Croft. This ADR is confirmed or amended when a smoke build has been run on a
macOS machine and on a Windows machine.** `.github/workflows/package.yml` builds and smokes on
`macos-latest` and `windows-latest`, and a green run there satisfies the *build and launch*
half on both. It does not satisfy the window half on any OS, and no runner will.

No date is set on this, because the condition is a machine becoming available and I do not know
when that is.

---

## Second correction, 2026-09-07 — Slice 001 G4. **Still `proposed`, and now for a different reason.**

**This supersedes two lines in the first correction's table above**, and nothing else in it. That
table read:

> | Running smoke build on **macOS** | **not done** | The `macos_aarch64` target cross-compiles under Zig, unsigned. Nothing here can execute it. |
> | Running smoke build on **Windows** | **not built** | Burrito unpacks the Windows ERTS `.exe` with 7z; none is installed and installing one needs root. |

**Both are now done, and neither is what this ADR is about.**

### What changed

**macOS**: the `package` workflow builds it natively on `macos-latest` — 12 435 992 bytes — and
it serves HTTP 200 under `--no-halt --smoke`, exiting on its own with the process list unchanged
either side.

**Windows**: the owner installed 7z, so it now cross-builds here as well —
`desktop_windows_x86_64.exe`, 27 316 224 bytes — and it builds natively on `windows-latest` and
runs under `--smoke`. **It has not been observed serving**; that step has been blocked by three
Windows-only defects in the workflow, all now fixed, and the answer is not yet in.

**So this ADR's literal exit condition — "a running smoke build on macOS and Windows" — is
satisfied for the sidecar.** The status still does not move, and the reason is that the
condition was written about the wrong thing.

### Why `proposed` is still right

**This ADR chooses a desktop shell.** Its subject is `ex_tauri` versus a hand-rolled Tauri
sidecar versus elixir-desktop versus Electron versus local-server-plus-tray. A Burrito binary
that boots and serves says nothing about any of them: **every alternative in the table would
pass that test**, because they all wrap the same BEAM.

What has been established about the *shell*, as opposed to the sidecar:

* **`mix ex_tauri.dev` opens a real window showing the scaffold** — on **one** operating system,
  Linux, run by the owner on 2026-09-07, with a screenshot at
  `slices/001-packaging-spike/proof/ac4-linux-window.png`. That is the first evidence in this
  project that the chosen shell does the thing it was chosen for.
* The shell **compiles** on all three targets in CI. Compiling is not running, and no job claims
  otherwise.
* On macOS and Windows the shell has **never been launched**. Those are AC2 and AC3, both
  `[manual]`, both needing a desktop that does not exist here.

**One shell running on one OS is not a decision about a cross-platform shell.** The fallback
path remains **untriggered**, not eliminated: its trigger is "Windows fails with `ex_tauri`",
and the Windows *shell* has still never been attempted.

### And a defect the choice has to answer for

Slice 001 G4 measured the sidecar's death when its parent dies, which is what "closing the
window stops the sidecar" means in practice:

* dev path, through a real window: **14–19 ms**, six runs — but **not** by `ex_tauri`'s
  heartbeat, whose 1500 ms timer never fired. `SIGKILL` matches `SIGTERM`, so it is the stdio
  pipe closing, which is the OS and not this library.
* production shape, three runs: **orphaned past 7.6 s, still answering HTTP 200**, with
  `ExTauri.ShutdownManager` compiled in.

**Across every measurement in slice 001 the heartbeat has never been observed to fire.** The
mechanism this ADR's chosen shell provides for the problem is present and unexercised. That is
not a reason to reject `ex_tauri` — no alternative has been shown to do better — but it is a
reason not to write `accepted` beside it yet.

### Lift condition, replacing the first correction's

**Owner: Ayla Croft.** This ADR is confirmed or amended when **`mix ex_tauri.dev` has opened a
window on macOS and on Windows**, and when the sidecar has been observed dying with its window
on at least one of them **by a mechanism this project owns**. The build-and-launch half is done
and was never the question.

No date: the condition is two machines becoming available, and I do not know when that is.

---

## Third correction, 2026-09-07 — "a runner has no desktop session" is measured once and assumed twice

Owner's word at G4. **This corrects a claim, not a decision: the status stays `proposed` and the
lift condition above is unchanged.**

Slice 001 wrote, in `docs/packaging.md`, in every `package.yml` job summary and in `PROOF.md`,
that **a runner has no desktop session**. That is measured for `ubuntu-latest`, where the job
states it smoked the sidecar alone with no display. **For `macos-latest` and `windows-latest` it
is assumed.** Those images run interactive sessions, and a window launched there and captured
with the platform's own screenshot tool would be a native window on that OS — which is exactly
what AC2 and AC3 ask for.

**Nobody has tried it.** The wording generalised from the one runner that was measured to the
two that were not, and the generalisation is the sort this project treats as a defect when it
appears in a mark or a count.

**It may retire AC2 and AC3 without a machine**, and it is the first thing to try before waiting
for one. It is not slice 001's work: this ADR records the correction and the manual queue
carries the step.
