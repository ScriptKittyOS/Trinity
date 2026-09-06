# Slice 100 — Desktop shell: native window, tray, notifications, keychain

| Field | Value |
|---|---|
| Phase | 10 Desktop |
| Milestone | M6 Ships |
| Size | L |
| Depends on | 001, 013 |

## Goal
Trinity as a real desktop application using the shell decided in ADR-0004 (ex_tauri unless 001 amended it): native
window hosting the LiveView UI, system tray with quick actions, OS notifications for approvals/cron results/
gateway messages, global hotkey to summon the window, native file/folder dialogs for the FS allowlist, secrets in
the OS keychain, launch-at-login, single-instance behaviour, and graceful shutdown that never loses a turn.

## Scope
**In:**
- `Trinity.Desktop` behaviour (`notify/2`, `tray_update/1`, `open_dialog/1`, `show_window/0`, `quit/0`) with `ExTauri` impl (or the 001 fallback) and a `Noop` impl for headless/CI.
- Tray: status (idle/thinking/pending approvals count), "New session", "Pause gateways", "Open data folder", "Quit".
- Notifications: approval requests (click → focus window at the approval), cron results, gateway messages when window hidden. Setting to mute.
- Global hotkey (configurable) to show/hide.
- Dialogs: pick folders for the FS allowlist from Settings.
- **Signing-key migration.** Slice 024 generates the receipt signing key into a 0600 file because no keychain
  exists until this slice, which is phase 2 to phase 10 on a file-backed key. This slice moves it: import the
  existing key into the keychain, or generate a new one and mark the old `key_id` `retired` with a `valid_until`
  in the registry so receipts already signed under it still verify. Never silently re-key: an unverifiable chain
  is worse than a rotated one. The registry is append-only, so this is a new row, not an edit.
- `Trinity.Secrets` with keychain backend (Tauri stronghold/store plugin via the bridge, or a small NIF/CLI shim per OS) and env fallback; provider keys entered in a Settings page, never stored in the DB.
- Launch-at-login (autostart plugin) and single-instance (second launch focuses the first).
- Graceful shutdown: on quit, sessions in `thinking` are cancelled and persisted as interrupted before the VM stops (`Application.prep_stop` + supervisor shutdown order), and Oban drains.
- Settings LiveView: model keys, data dir, allowlists, hotkey, notifications, gateways enable, budgets.
- **First-run onboarding.** On a machine with no configuration the app currently opens a chat window that cannot
  answer: no provider key, no model, no confirmed data dir, no filesystem allowlist. A settings page is where you
  change those, not a path that gets a new user to a working first turn. Add a short setup path reusing the
  Settings components: choose a provider and enter a key, confirm the data dir, pick initial project roots.
- Verify in the packaged binary: FTS5 present, `sqlite_vec` loads, `file_system` watcher works (or reindex fallback), Bumblebee cache dir resolves.
**Out:** signing/notarization/updater (101), Windows-specific polish beyond parity items.

## Acceptance criteria
1. [manual] Packaged build launches to the chat window with no dev tooling on the machine (fresh user account or VM): macOS + Windows screenshots (Linux if available).
2. [manual] Tray menu actions work (screenshots); pending-approval count updates live.
3. [manual] An approval requested while the window is hidden produces an OS notification; clicking it focuses the window on the approval card (GIF).
4. [manual] Global hotkey shows/hides the window (GIF).
5. [manual] Keychain: a provider key entered in Settings is retrievable after restart and absent from the DB file (`strings trinity.db | grep` returns nothing) and from logs (tests + manual).
6. [auto] Receipts signed before the keychain migration still verify after it; the retired `key_id` carries a `valid_until` and the chain is unbroken across the boundary (test).
7. [manual] Quit during a streaming turn → draft persisted as interrupted; on relaunch the banner shows (manual).
8. [manual] Second launch focuses the first instance (manual).
9. [auto] Packaged-binary checks pass: FTS5, sqlite_vec, watcher (or documented fallback), embeddings cache (log excerpt).
10. [auto] Headless `mix phx.server` still works with `Noop` desktop impl (test).
11. [manual] First launch with no configuration reaches a working first turn through the setup path, on a fresh account (manual, screenshots).

## Manual verification queue
Every `[manual]` criterion below needs a person. Listed here so the owner sees the queue at G1 rather
than at review time.
- **AC1** — Packaged build launches to the chat window with no dev tooling on the machine (fresh user account or VM): macOS + Windows screenshots (Linux if….
- **AC2** — Tray menu actions work (screenshots); pending-approval count updates live.
- **AC3** — An approval requested while the window is hidden produces an OS notification; clicking it focuses the window on the approval card (GIF).
- **AC4** — Global hotkey shows/hides the window (GIF).
- **AC5** — Keychain: a provider key entered in Settings is retrievable after restart and absent from the DB file (`strings trinity.db | grep` returns….
- **AC7** — Quit during a streaming turn → draft persisted as interrupted; on relaunch the banner shows (manual).
- **AC8** — Second launch focuses the first instance (manual).
- **AC11** — First launch with no configuration reaches a working first turn through the setup path, on a fresh account (manual, screenshots).

## Definition of Done
- [ ] gate green · [ ] AC1–11 proven · [ ] docs/packaging.md, docs/07 synced · [ ] ADR-0004 status accepted · [ ] ROADMAP → done · [ ] commit + tag

## Commit & tag
`feat(s100): complete slice 100 — desktop shell` · tag `slice/100`

## Risks / open questions
- Keychain access from the BEAM: prefer the Tauri bridge (Rust side does the OS work) so no NIF is needed.
- Windows: if the ex_tauri path was replaced in 001, the bridge protocol must be reimplemented in the chosen shell — budget time.
