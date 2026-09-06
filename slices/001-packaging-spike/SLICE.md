# Slice 001 — Packaging spike: Burrito + ex_tauri smoke build

| Field | Value |
|---|---|
| Phase | 0 Foundation |
| Milestone | M0 Stands |
| Size | M |
| Depends on | 000 |
| Status | done |

## Goal
Prove — or disprove — that the scaffold from 000 can be packaged as a single Burrito binary and opened in a
native Tauri window via ex_tauri on each target OS. This slice exists to retire risk R1 before we build on it.
It ends with ADR-0004 confirmed or amended.

## Why
Desktop packaging is the riskiest, least-Elixir-native part of the plan. Finding out in Slice 100 is too late.

## Scope
**In:**
- Add `burrito` (release step) and `ex_tauri` (dev dep) to `mix.exs`; run `mix ex_tauri.install`.
- Burrito targets: `darwin_arm64`, `darwin_x86_64`, `linux_x86_64`, `windows_x86_64` (only build the ones the
  human's machines can test; document which).
- A `Trinity.Release` module that runs migrations explicitly (skipped under `BURRITO_TARGET` at boot, per known pattern).
- Data dir resolution (macOS `~/Library/Application Support/Trinity`, Windows `%APPDATA%\Trinity`, Linux `$XDG_DATA_HOME/trinity`).
- Runtime port selection: bind to `127.0.0.1:0`, read the assigned port, pass to the shell (ex_tauri does this).
- `mix ex_tauri.dev` opens the scaffold in a native window; `mix ex_tauri build` produces an installable artifact.
- A `docs/packaging.md` with exact commands, prerequisites (Rust, Tauri deps, Zig if cross-building), and gotchas found.
**Out:**
- Signing, notarization, updater (101). Tray/notifications (100). Any app features.

## Design notes
- Keep all desktop-shell specifics in `tauri/` and `Trinity.Desktop` stubs; the core app must still run with plain `mix phx.server`.
- Measure binary size and cold-start time; they are baselines for 100/101.
- If ex_tauri fails on Windows: try the hand-rolled sidecar pattern (phoenix_tauri repo) in the same slice; if that
  fails too, try elixir-desktop for Windows only. Whatever works is written into ADR-0004 as accepted.

## Deliverables
- `tauri/` scaffold, Burrito config in `mix.exs`, `lib/trinity/release.ex`, `lib/trinity/paths.ex`, `docs/packaging.md`, ADR-0004 updated.

## Acceptance criteria
1. [auto] `MIX_ENV=prod mix release` with Burrito produces a binary for the host OS; running it starts Phoenix on an ephemeral port and serves the scaffold page (curl output shown).
2. [manual] `mix ex_tauri.dev` opens a native window showing the LiveView scaffold (screenshot) on macOS. **No machine available — Ubuntu is the only machine.**
3. [manual] The same on Windows (screenshot) — or a documented failure with the fallback that succeeded (screenshot) and ADR-0004 amended. **No machine available — Ubuntu is the only machine.**
4. [manual] The same on Linux (screenshot). Retagged from `[auto]` at G1: a native window on a desktop session is not a command's output, and the spec's "or documented not tested" clause is a waiver rather than an automation. **No desktop session available on this machine.**
5. [auto] Binary size and cold-start-to-serving are recorded for **linux x86_64** in `docs/packaging.md`, measured with `stat -c %s` and a timed loop against the port the smoke run prints.
6. [manual] The same figures for macOS and Windows, and cold-start-to-first-**paint** on any OS. Split from AC5 at G1: "per OS" needs machines that do not exist, and "first paint" needs a window. **No machine available.**
7. [auto] Running the binary under `--smoke` exits 0 and leaves no process behind: `ps -eo pid,ppid,comm` before and after shows no surviving sidecar. Split from AC6 at G1 — this is the property underneath it, and it is measurable on linux today.
8. [manual] Killing the **window** terminates the sidecar within 5 s (heartbeat), verified with `ps` or Task Manager. Split from AC6 at G1: killing a window needs a desktop. **No machine available.**
9. [auto] `mix gate` still green; `mix phx.server` still works without Tauri.

## Proof required
- Build logs (trimmed), curl output, screenshots under `proof/`, size/time table, process-list before/after window close.

## Manual verification queue
Five `[manual]` criteria, and they are one missing thing: **a machine that is not this one.** The owner's only
machine is Ubuntu. Each names the machine or account it needs.

| AC | Needs | What a GitHub Actions runner can prove instead |
|---|---|---|
| 2 | a **macOS desktop** | the artifact builds, launches and exits clean under `--smoke`, and the launch log |
| 3 | a **Windows desktop** | the same |
| 4 | a **Linux desktop session** | the same, plus the shell under `xvfb-run` if that is what the job does |
| 6 | a **macOS and a Windows machine** | binary size on each; not first paint |
| 8 | any one of the three desktops | nothing — no runner can watch a window close |

A runner **cannot** produce a screenshot of a real window on a real desktop, and no artifact from one will be
offered as though it had. These five exit the slice **unproven and named**, not counted.

## Definition of Done
- [x] gate green · [ ] AC1–9 proven — **AC1, 5, 7, 9 proven; AC2, 3, 4, 6, 8 unproven and named, awaiting the human's waiver for the untested OSes** · [ ] ADR-0004 finalised — **not finalised; its own exit condition is a smoke build on macOS AND Windows and neither exists, so it stays `proposed` with an appended correction** · [x] `VERSIONS.md` rows for burrito/ex_tauri/OTP flipped to ✅ with exact versions · [x] ROADMAP → done · [ ] commit + tag — **the human's, at G4**

Two boxes are deliberately left unticked. They are the slice's result, not an oversight: the
packaging spike answered what one machine can answer and says plainly what it could not reach.
See `PROOF.md` for the evidence and the manual queue, and `NOTES.md` for the nine deviations.

## Commit & tag
`feat(s001): complete slice 001 — packaging spike (Burrito + ex_tauri)` · tag `slice/001`

## Risks / open questions
- ex_tauri may require OTP 27 or 28 specifically; if OTP 28 fails, record it — this is the ADR-0005 check.
- Windows ERTS unpacking needs 7-Zip per Burrito notes; document.
