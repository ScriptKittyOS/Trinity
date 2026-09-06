# Slice 072 — Gateway: Discord (Nostrum)

| Field | Value |
|---|---|
| Phase | 7 Gateways |
| Milestone | M5 Always-on |
| Size | S |
| Depends on | 070 |

## Goal
A Discord adapter on Nostrum: DMs and channel mentions/threads, streaming via edits, buttons for approvals,
attachments in/out, slash commands registered with Discord, cron delivery target.

## Scope
**In:** Nostrum consumer under `Trinity.Gateways.Supervisor`; intents config; per-channel-or-thread → session mapping; 2000-char chunking; components (buttons) for approvals; slash command registration mirroring `Trinity.Gateways.Commands`; UI status.
**Out:** voice channels.

## Acceptance criteria
1. [manual] Manual/live proof: mention the bot in a channel → threaded streamed reply (screenshots).
2. [manual] Button approvals round-trip (screenshot).
3. [manual] Slash commands `/new`, `/model` work and are registered (screenshot of Discord command list).
4. [auto] Unit tests for formatting/chunking and the event→Router mapping with recorded Nostrum event fixtures.
5. [auto] Consumer crash → restart without duplicate replies (test with fixtures).
6. [manual] Cron delivery to a channel (manual proof).

## Manual verification queue
Every `[manual]` criterion below needs a person. Listed here so the owner sees the queue at G1 rather
than at review time.
- **AC1** — Manual/live proof: mention the bot in a channel → threaded streamed reply (screenshots).
- **AC2** — Button approvals round-trip (screenshot).
- **AC3** — Slash commands `/new`, `/model` work and are registered (screenshot of Discord command list).
- **AC6** — Cron delivery to a channel (manual proof).

## Definition of Done
- [ ] gate green · [ ] AC1–6 proven · [ ] VERSIONS (nostrum ✅) · [ ] ROADMAP → done · [ ] commit + tag

## Commit & tag
`feat(s072): complete slice 072 — Discord gateway` · tag `slice/072`
