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
