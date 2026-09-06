# Slice 101 — Release pipeline: signing, notarization, auto-update

| Field | Value |
|---|---|
| Phase | 10 Desktop |
| Milestone | M6 Ships |
| Size | L |
| Depends on | 100 |

## Goal
A CI release workflow that builds, signs, notarizes (macOS), signs (Windows), packages installers (`.dmg`/`.app`,
`.msi`/`.exe`, `.AppImage`/`.deb`), publishes to GitHub Releases with an updater manifest, and an in-app updater
that checks, downloads, verifies, and applies updates — with migrations run safely on first launch of a new
version and a rollback story.

## Why
Vision goal 7. Also risk R2: this slice is where cert/notary friction lands, so the human should start
procurement (Apple Developer Program; Windows OV/EV cert on HSM/cloud signing; note the 460-day cert cap
effective March 2026) at M0.

## Scope
**In:**
- `mix trinity.release` orchestrating Burrito targets + the shell's bundler; version from `mix.exs` + git tag.
- CI (GitHub Actions) matrix: macos-latest (arm64 + x86_64 or universal), windows-latest, ubuntu-latest; secrets for certs; artifact upload; release notes from conventional commits.
- macOS: Developer ID signing, hardened runtime, entitlements (network client, file access as needed), notarization via `notarytool`, stapling; Gatekeeper check documented.
- Windows: Authenticode signing via cloud/HSM signer (Azure Trusted Signing or vendor tool) — the pipeline supports a "sign step" that the human configures; SmartScreen note.
- Updater: Tauri updater plugin (if ex_tauri path) with signed manifest; otherwise a minimal in-app updater (download, verify signature/sha, swap, relaunch; Windows rename-running-exe trick). Update channel setting (stable/beta). Check on launch + daily.
- Data safety: backup the SQLite file before running migrations on a new version; keep last 3 backups; migration failure → restore + show error.
- `docs/release.md`: full runbook.
**Out:** Store distribution (Mac App Store, MS Store), Linux repos.

## Acceptance criteria
1. [auto] CI release run on a tag produces artifacts for each target (run URL/log).
2. [manual] macOS: `spctl --assess --type execute` and `stapler validate` pass on the produced app (output).
3. [manual] Windows: `signtool verify /pa` passes (output) — or documented "unsigned pending cert" with the pipeline step proven using a self-signed cert in a test run.
4. [manual] Updater: install version N, publish N+1 to a test channel, app detects, downloads, verifies, updates, relaunches on N+1 (GIF/screenshots per OS).
5. [manual] Migration backup: simulate a failing migration on update → DB restored, error shown, app still opens on N (manual with a deliberately broken migration in a test branch).
6. [auto] Release notes generated from commits since last tag (excerpt).
7. [auto] `docs/release.md` complete; a second person could run a release from it.

## Manual verification queue
Every `[manual]` criterion below needs a person. Listed here so the owner sees the queue at G1 rather
than at review time.
- **AC2** — macOS: `spctl --assess --type execute` and `stapler validate` pass on the produced app (output).
- **AC3** — Windows: `signtool verify /pa` passes (output) — or documented "unsigned pending cert" with the pipeline step proven using a self-signed cert in a….
- **AC4** — Updater: install version N, publish N+1 to a test channel, app detects, downloads, verifies, updates, relaunches on N+1 (GIF/screenshots per OS).
- **AC5** — Migration backup: simulate a failing migration on update → DB restored, error shown, app still opens on N (manual with a deliberately broken….

## Definition of Done
- [ ] gate green · [ ] AC1–7 proven (cert-dependent ACs may be conditionally waived by the human with a follow-up slice) · [ ] docs/release.md · [ ] ROADMAP → done · [ ] commit + tag

## Commit & tag
`feat(s101): complete slice 101 — release pipeline` · tag `slice/101` (and the app's first `v0.1.0` tag)

## Risks / open questions
- Notarization can take minutes to hours; the workflow must poll, not assume.
- Universal macOS binary vs two artifacts — decide by Burrito/Tauri support at the time.
