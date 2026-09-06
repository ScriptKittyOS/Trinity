# Slice 071 — Gateway: Telegram

| Field | Value |
|---|---|
| Phase | 7 Gateways |
| Milestone | M5 Always-on |
| Size | S |
| Depends on | 070 |

## Goal
A Telegram adapter (Telegex or ex_gram — choose in NOTES with justification; long-polling by default, webhook
optional) supporting DMs and group mentions, streaming via message edits (throttled), inline approval buttons,
images in/out, and the cron delivery target.

## Scope
**In:** adapter module; bot token from `Trinity.Config.secret/1`; markdown → Telegram MarkdownV2 escaping; chunking at 4096; typing indicator; edit-throttle ≥ 1 s; inline keyboard for approvals; photo download to data dir and attach as image part (vision support depends on provider caps); `/start` pairing flow; UI status.
**Out:** voice notes (follow-up: Whisper via Bumblebee), stickers/polls.

## Acceptance criteria
1. [manual] Live-tagged test (or manual with proof) — send a DM, get a streamed reply that updates in place, ending with the final text (screenshot sequence).
2. [manual] Approval buttons work from Telegram and the desktop UI reflects the decision (screenshot).
3. [manual] An image sent to the bot is stored and passed to a vision-capable model; the reply references it (live/manual proof).
4. [auto] Unit tests for formatting/escaping/chunking with tricky markdown (code blocks, underscores, links).
5. [auto] Adapter crash (kill its process) → supervisor restarts it; polling resumes; no duplicate processing of the last update (offset persisted) (test with a fake Telegram API server).
6. [manual] Cron task delivers to Telegram (manual proof).

## Definition of Done
- [ ] gate green · [ ] AC1–6 proven · [ ] VERSIONS (telegram lib ✅) · [ ] ROADMAP → done · [ ] commit + tag

## Commit & tag
`feat(s071): complete slice 071 — Telegram gateway` · tag `slice/071`
