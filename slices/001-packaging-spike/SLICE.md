# Slice 001 — Packaging spike: Burrito + ex_tauri smoke build

| Field | Value |
|---|---|
| Phase | 0 Foundation |
| Milestone | M0 Stands |
| Size | M |
| Depends on | 000 |

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
2. [manual] `mix ex_tauri.dev` opens a native window showing the LiveView scaffold (screenshot) on macOS.
3. [manual] The same on Windows (screenshot) — or a documented failure with the fallback that succeeded (screenshot) and ADR-0004 amended.
4. [auto] Linux: same, or documented "not tested — no machine" (acceptable).
5. [auto] Binary size and cold-start-to-first-paint time recorded per OS in `docs/packaging.md`.
6. [manual] Killing the window terminates the sidecar within 5 s (heartbeat) — verified with `ps`/Task Manager.
7. [auto] `mix gate` still green; `mix phx.server` still works without Tauri.

## Proof required
- Build logs (trimmed), curl output, screenshots under `proof/`, size/time table, process-list before/after window close.

## Manual verification queue
Every `[manual]` criterion below needs a person. Listed here so the owner sees the queue at G1 rather
than at review time.
- **AC2** — `mix ex_tauri.dev` opens a native window showing the LiveView scaffold (screenshot) on macOS.
- **AC3** — The same on Windows (screenshot) — or a documented failure with the fallback that succeeded (screenshot) and ADR-0004 amended.
- **AC6** — Killing the window terminates the sidecar within 5 s (heartbeat) — verified with `ps`/Task Manager.

## Definition of Done
- [ ] gate green · [ ] AC1–7 proven (or explicitly waived by the human for untested OSes) · [ ] ADR-0004 finalised · [ ] `VERSIONS.md` rows for burrito/ex_tauri/OTP flipped to ✅ with exact versions · [ ] ROADMAP → done · [ ] commit + tag

## Commit & tag
`feat(s001): complete slice 001 — packaging spike (Burrito + ex_tauri)` · tag `slice/001`

## Risks / open questions
- ex_tauri may require OTP 27 or 28 specifically; if OTP 28 fails, record it — this is the ADR-0005 check.
- Windows ERTS unpacking needs 7-Zip per Burrito notes; document.
