# Slice 013 — LiveView chat UI with streaming

| Field | Value |
|---|---|
| Phase | 1 Core loop |
| Milestone | M1 Talks |
| Size | M |
| Depends on | 012 |

## Goal
A usable chat: session list, new session, message composer, streaming assistant output rendered as markdown,
tool-call/status indicators, model switcher, cancel button, interrupted-turn banner, reconnect-safe. This is the
desktop app's primary surface (webview in 100).

## Why
M1 "Talks" is only real if a human can use it. Also the surface where every later feature shows up.

## Scope
**In:**
- Routes: `/` (sessions index + new), `/s/:id` (chat). Scopes per Phoenix 1.8 (single local user scope).
- `TrinityWeb.SessionLive.Index`, `TrinityWeb.SessionLive.Show` with `Trinity.Sessions.subscribe/1` on mount; `ensure_started/1` on mount.
- Streaming render for the in-progress assistant message; completed messages rendered once. The renderer is selected in this slice, not mandated before it. `phoenix_streamdown` is the first candidate but is at `1.0.0-beta.4` (2026-05-03), and VERSIONS.md's own rule forbids pinning a pre-release, so it is adopted only if this slice measures it sound and the owner accepts the pre-release. Fallback: `earmark` or `mdex` with chunk buffering.
- Components: message bubble (role, timestamp, usage badge), tool-call card (name, args summary, status, expandable result), composer (Enter to send, Shift+Enter newline; disabled while thinking), model picker (from `Trinity.LLM.models/0`; changes `sessions.model`), cancel button, interrupted banner with "Retry".
- Reconnect: on LiveView remount, load history from DB and current state from the Session; no duplicated messages.
- Keyboard: `Cmd/Ctrl+K` new session; `Esc` cancel turn.
- **The design language is decided here, not inherited from the scaffold.** Every later surface takes its
  component vocabulary from this slice: the approval card (021), memory panel (030), skills list (040), tasks
  (050), gateways (070), activity and cost (090), settings (100). Deciding now costs one pass; retrofitting costs
  seven. Dark by default, a light/dark toggle retained, Ubuntu or Comfortaa with a real fallback stack, clean
  rounded panels. Commit the palette, type scale, radius and spacing as tokens so later slices consume them
  rather than reinventing them.
- LiveView tests for: send → stream → final; cancel; reconnect; model switch; interrupted banner.
**Out:**
- Approvals UI (021), memory/skills panels (030/040), settings pages, desktop shell (100), mobile layout polish.

## Design notes
- Keep LiveView assigns bounded: `streams` for messages; in-progress text held in one assign, replaced not appended, and cleared when the final message arrives.
- Use `phx-update="ignore"` regions for completed markdown blocks per streamdown guidance.
- Session id in URL; no server-side session for the single-user local app (Scopes still used to be generator-compatible).

## Deliverables
- `lib/trinity_web/live/session_live/*`, components, router, assets (hooks), tests, `docs/` screenshots in `proof/`.

## Acceptance criteria
1. [manual] Manual: create session, send "hello", see streamed markdown response (FakeProvider in dev via config flag, and a real provider) — screenshot/GIF.
2. [auto] LiveView test: send → `assistant_delta` updates → final message appears once in the DOM (no duplication).
3. [manual] Cancel during streaming: button works; interrupted message rendered with banner (test + screenshot).
4. [manual] Kill the Session process while the page is open: banner appears; page remains usable; next message works (manual + test using `Process.exit`).
5. [auto] Reload the page mid-stream: history renders from DB; no duplicate or missing messages (test).
6. [auto] Model picker changes `sessions.model` and the next turn uses it (test with FakeProvider recording the model).
7. [auto] Render performance: 1,000 deltas in 1 s do not exceed ~25 DOM patches (count via `phx-update` hooks or telemetry) — number recorded.
8. [auto] Gate green; `mix sobelow` no new findings.

## Proof required
- Screenshots/GIF, LiveView test output, patch-count measurement.

## Manual verification queue
Every `[manual]` criterion below needs a person. Listed here so the owner sees the queue at G1 rather
than at review time.
- **AC1** — Manual: create session, send "hello", see streamed markdown response (FakeProvider in dev via config flag, and a real provider) — screenshot/GIF.
- **AC3** — Cancel during streaming: button works; interrupted message rendered with banner (test + screenshot).
- **AC4** — Kill the Session process while the page is open: banner appears; page remains usable; next message works (manual + test using `Process.exit`).

## Definition of Done
- [ ] gate green · [ ] AC1–8 proven · [ ] VERSIONS (phoenix_streamdown ✅ or fallback noted) · [ ] ROADMAP → done · [ ] commit + tag

## Commit & tag
`feat(s013): complete slice 013 — LiveView chat UI with streaming` · tag `slice/013`

## Risks / open questions
- The first-candidate renderer is a pre-release four months without a release. Treat the `earmark`/`mdex` chunk-buffering fallback as a live option, not a formality, and record the measurement and the choice in NOTES + VERSIONS.
