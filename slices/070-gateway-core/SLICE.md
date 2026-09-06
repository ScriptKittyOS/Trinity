# Slice 070 — Gateway core: adapter behaviour, routing, PubSub fan-out

| Field | Value |
|---|---|
| Phase | 7 Gateways |
| Milestone | M5 Always-on |
| Size | M |
| Depends on | 012 |

## Goal
The platform-agnostic gateway layer: `Trinity.Gateways.Adapter` behaviour, a router that maps external
conversations to sessions (per-platform isolation + optional "continue my desktop session" linking), identity
allowlist + DM pairing, slash-command dispatch, approval handling over chat, delivery of cron results, and the
proof that one session is observed by the desktop UI and a gateway simultaneously. Includes a `Console` adapter
(in-process fake) used for tests.

## Why
Vision goal 2. Gateways are PubSub subscribers in the same node, not a separate process holding its own copy of the state.

## Scope
**In:**
- Behaviour: `child_spec/1`, `capabilities/0` (markdown, images, buttons, max length), `deliver/2` (outbound message/edit/typing), `format/2` (assistant message → platform text with chunking), `render_approval/2`.
- `Trinity.Gateways.Router`: inbound `{adapter, external_conv_id, external_user_id, text, attachments}` → `gateway_identities` check → session lookup/create (`origin`, `origin_ref`) → `Trinity.Sessions.send_user_message/2`; per-conversation subscription to `session:<id>` that streams to the adapter (delta coalescing → edits or final-only per capability).
- Pairing: unknown user → one-time code shown in desktop UI; user sends code → paired. Allowlist config for pre-approved ids.
- Slash commands: `/new`, `/sessions`, `/model <id>`, `/skills`, `/memory`, `/approve <id>`, `/deny <id>`, `/help` via `Trinity.Gateways.Commands` (extensible registry).
- Approvals: `approvals:*` events rendered to the originating conversation with buttons/text commands; decisions routed back to Gate, **subject to the per-channel trust cap** (`docs/07`): `:exec` and `:destructive` are not approvable from a gateway by default, and the requester is told where to decide rather than being ignored.
- Delivery impl for 050: `Trinity.Scheduler.Delivery.Gateway`.
- Rate limiting per external user (Hammer or a simple token bucket).
- UI: `/gateways` page with adapters status, pairing codes, identities list with allow/revoke.
- `Console` adapter for tests and a dev REPL (`mix trinity.console`).
**Out:**
- Real platforms (071, 072), voice transcription (follow-up), media uploads beyond images.

## Design notes
- Adapters never call the LLM or Sessions directly — only Router.
- Session linking: a gateway conversation can attach to an existing desktop session via `/attach <session_id>` — both surfaces then see the same stream (this is the demo).

## Deliverables
- `lib/trinity/gateways/{adapter,router,pairing,commands,format,console}.ex`, `lib/trinity/gateways.ex`, migration (`gateway_identities`), UI, tests.

## Acceptance criteria
1. [auto] Console adapter: inbound message from a paired identity creates a session with `origin: "console"` and returns a streamed reply (test).
2. [manual] Unpaired identity receives only a pairing prompt; after entering the code shown in the UI, the next message is processed (test + screenshot).
3. [auto] `/attach` a console conversation to a desktop session: a message sent from the LiveView appears in the console stream and vice versa (test subscribing both).
4. [auto] An approval requested by a tool during a gateway-originated turn is rendered in the console; `/approve <id>` resumes the turn (test).
5. [auto] Cron delivery to a gateway conversation works (test with 050 worker).
6. [auto] Rate limit: > N messages/min from one identity → throttled reply (test).
7. [auto] Concurrency: 50 console conversations active with FakeProvider; all complete; DB `integrity_check` ok (stress test).
8. [auto] A `:destructive` approval arriving from a gateway adapter is refused under the default cap, the conversation is told where to decide, and the refusal is receipted (test).
9. [manual] `/gateways` UI screenshot.

## Proof required
- Tests, screenshots.

## Definition of Done
- [ ] gate green · [ ] AC1–9 proven · [ ] docs/01, docs/07 synced · [ ] ROADMAP → done · [ ] commit + tag

## Commit & tag
`feat(s070): complete slice 070 — gateway core` · tag `slice/070`
