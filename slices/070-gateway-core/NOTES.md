# Slice 070: NOTES

## Read before code, 2026-09-22

Tree at `8b31ee5` on `main` (062 approved; **M5a Automates reached**; 012, the dependency,
approved since 2026-09-20). Chosen from the ready set by the coding agent on the owner's
instruction to pick, and why it rather than the others: 080 and 090 also have approved
dependencies, but 070 unblocks two slices (071, 072) where 080 unblocks one optional slice, and
090's own goal instruments "gateway event" telemetry, which does not exist until this slice
builds it. So the ROADMAP's own text implies 070 before 090. 070 also needs nothing of the
owner to start: every acceptance criterion runs against the in-process `Console` adapter, and the
real platforms are 071 and 072.

**Correction in this commit.** `SLICE.md`'s milestone field read `M5 Always-on`, the name that was
split into M5a and M5b on 2026-09-08; slices 059 to 062 were corrected then and 070 was missed.
It now reads `M5b Reaches`, matching ROADMAP's milestone table. No scope changes with it.

What this slice joins, measured today rather than remembered: sessions carry `origin` and
`origin_ref` already (010's migration), so the router needs no migration but its own
(`gateway_identities`); the stream is `Trinity.Sessions.Events`, topic `session:<id>`, events
`{:user_message, _}`, `{:assistant_delta, _}`, `{:assistant_message, _}`, `{:tool_call, _}`,
`{:state, _}`, `{:turn_interrupted, _}`, `{:error, _}`, `{:compaction, _}`, `{:forked, _}`;
approvals broadcast on `approvals:<session_id>` and `approvals:all` (021), and the only way to
decide one is `Trinity.Permissions.decide_request/3`; 050's delivery is a behaviour with
`deliver(Run.t(), Task.t())` and one implementation (`Delivery.Desktop`). `hammer` is **not** a
dependency and this slice does not add one: the rate limit is a token bucket in the router's own
state, so VERSIONS.md gains no row (AC6 measures the behaviour, not the library).

The security model already decides the question this slice would otherwise have to ask: docs/07
"Gateways" fixes the channel trust cap (`:read`, `:network`, `:write` approvable from a paired
gateway; `:exec` and `:destructive` desktop or console only, the cap applied **after** the gate's
own decision, never instead of it) and says a capped request is answered, not dropped. AC8 is that
paragraph as a test.

## G1 plan, 2026-09-22

Branch `slice/070-gateway-core`; ROADMAP row 070 to `in_progress`. Each line names its test.

1. `Trinity.Gateways` (a boundary whose deps follow docs/01's row and `Trinity.Scheduler`'s
   shape: `[Trinity, Trinity.Sessions]`, with Permissions and PubSub reached through `Trinity`'s
   exports), `Gateways.Adapter` (the behaviour:
   `child_spec/1`, `capabilities/0`, `deliver/2`, `format/2`, `render_approval/2`) and
   `Gateways.Console` (in-process adapter: a mailbox a test reads). Test: the behaviour's
   callbacks are all implemented by Console, and `capabilities/0` drives chunking.
2. Migration `gateway_identities` (adapter, external_user_id, state, paired_at, allowlisted) with
   `Gateways.Identities`; `Gateways.Pairing` (a one-time code, ten minutes, shown in the UI).
   Tests: an unknown identity gets the pairing prompt and nothing else; a used or expired code is
   refused (AC2's automatic half).
3. `Gateways.Router`: inbound tuple → identity check → rate limit → session lookup or create with
   `origin` and `origin_ref` → `Sessions.send_user_message/2`; a per-conversation subscriber to
   `session:<id>` that coalesces `{:assistant_delta, _}` into an edit or a final message per the
   adapter's capabilities. Tests: AC1 (streamed reply, `origin: "console"`), AC6 (the bucket),
   AC7 (50 conversations under the fake provider, then `integrity_check`).
4. `Gateways.Commands` (a registry: `/new`, `/sessions`, `/model`, `/skills`, `/memory`,
   `/approve`, `/deny`, `/attach`, `/help`). Tests: AC3 (`/attach` makes the desktop LiveView and
   the console see one stream, both subscribed in the test), and each command's refusal path.
5. Approvals over chat: the router renders `approvals:<session_id>` into the conversation and
   `/approve` and `/deny` call `Permissions.decide_request/3`, **after** `Gateways.Cap` refuses a
   tier the channel may not approve. Tests: AC4 (an approval mid-turn resumes on `/approve`) and
   AC8 (a `:destructive` request is refused with the reason, the conversation is told where to
   decide, and the refusal is receipted).
6. `Trinity.Scheduler.Delivery.Gateway` (050's behaviour, second implementation). Test: AC5, a
   cron run delivered to a console conversation.
7. `/gateways` LiveView (adapter status, pairing codes, identities with allow and revoke) and
   `mix trinity.console` for a dev REPL. Tests: the page lists, pairs and revokes.
8. Docs: docs/01 (the boundary and its modules), docs/07 (the Gateways section as built, the cap
   as a property rather than a plan), README's "Not there yet" line; PROOF.

Manual verification queue, so the owner sees it now and not at review: **AC2** (the pairing
prompt, then the code entered in the UI, as a screenshot) and **AC9** (the `/gateways` page).
Both are screenshots this machine can take with the cached headless chromium, as slices 013 to
060 did; neither needs an external account, a platform token or anything of the owner's.

Not built here: the real platform adapters (071, 072), voice transcription, media beyond images,
and any change to the gate's own decision (the cap is applied after it, never instead of it).
