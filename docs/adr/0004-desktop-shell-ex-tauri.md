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
