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

## Deviations from SLICE.md and the G1 plan (recorded before the commit that carries them)

1. **The channel trust cap applies to `Console` too, and docs/07 is amended to say so.** That
   paragraph read "`:exec` and `:destructive` are desktop or console only", written before there
   was a console adapter. There is one now. Exempting it would make the in-process channel the one
   channel that may approve a destructive effect, which is a hole shaped exactly like the thing
   the cap exists for, and it would leave AC8 with nothing to test against. So `Cap` applies a
   ceiling to every adapter, configurable per adapter, `:write` by default; docs/07 now reads
   "desktop only" with an amendment note naming this slice.
2. **No `hammer`.** SLICE.md said "Hammer or a simple token bucket". The bucket is in the router's
   own state, so the slice adds no dependency and `VERSIONS.md` gains no row. AC6 measures the
   behaviour rather than the library.
3. **`/attach` binds through a pure state transition** (`Router.bind_state/4`), not through
   `Router.attach/3`. Commands run inside the router process, so a command calling the router's
   own API is that process calling itself: the suite found the deadlock the first time `/attach`
   ran. `attach/3` stays for callers outside the process.
4. **`Trinity.Gateways` is a boundary under `Trinity`**, and the `/gateways` page reaches it
   through `Trinity`'s exports, the way the tasks page reaches `Scheduler`. `TrinityWeb` could not
   list it as a dependency directly: the library allows only a sibling, a parent, or an ancestor's
   dependency, and the compiler said so.
5. **The adapter's name is derived, not declared** (`Adapter.name/1`: the last segment of the
   module, underscored). A declared name a module can contradict is a second source of truth
   (CLAUDE.md section 8).
6. **No adapter supervisor of its own.** The slice's tree listed `Trinity.Gateways.Supervisor`;
   `Console` and `Router` are ordinary supervised children and a platform adapter will be one too,
   so a supervisor whose only job is to hold one child was not written. docs/01's tree is updated
   to what exists.

## Findings

- **F1.** `Commands` runs inside the router's process, so `/attach` calling `Router.attach/3`
  deadlocked ("process attempted to call itself"). Fixed by making the binding a pure state
  transition. Found by the AC3 test the first time it ran.
- **F2.** `/attach <prefix>` reached `Sessions.get_session/1` with something that is not a UUID,
  and Ecto raised `Ecto.Query.CastError` **inside the router**, taking every conversation's
  binding down with it. Two fixes, because the second is the one that matters: the prefix is
  resolved without a cast, and `dispatch/2` now rescues, so a command that raises costs its own
  message and nothing else. A test holds the router's pid across a malformed command.
- **F3.** `Console.text/1` renumbered message references per conversation while `deliver/2` hands
  out a counter global to the process, so an edit landed on a different message and a later reply
  could overwrite an earlier one. The reference is now recorded beside the message. Found by the
  approvals suite, where a cap refusal overwrote the turn's reply.
- **F4.** `Format.plain/1` used `^\s*[-*]\s+` for a list marker; `\s` matches a newline, so the
  blank line before a list was eaten and two paragraphs became one. `[ \t]` now.
- **F5.** Two approval tests asserted on "the last thing the channel was shown" while the opening
  turn's reply was still in flight: they passed alone and failed when the suite ran whole. The
  helper waits the opening turn out and reads everything shown rather than the last message.

## Follow-ups

- The real platforms (071, 072). This slice's `Console` is the shape they implement; nothing of
  the router should need to change for them, and if one does, that is the finding to record.
- `Router` holds every conversation in one process. Fifty conversations are fine (AC7); a
  deployment with thousands would want one process per conversation under a registry, which is a
  slice of its own rather than a change to make on a guess.
- The `/gateways` page shows no per-identity message counts or last-seen time; 090's observability
  is where that belongs.
- `Console.capabilities/0` carries `images: false`: an adapter that carries images needs a path
  for them, which the SLICE's "Out" line already defers.
