# Proof for slice 070: Gateway core (adapter behaviour, routing, PubSub fan-out)

Agent: Claude Opus 5 (1M context) · Date: 2026-09-22 · Branch: slice/070-gateway-core · Final commit: written at the close, below

## Summary

A channel can reach Trinity now: `Trinity.Gateways.Adapter` is the behaviour a platform
implements, `Router` is the one road from a channel to a session, and `Console` is an in-process
adapter that ships, so every criterion here runs without an account, a token or a network. An
unknown sender gets a pairing code and nothing else; a paired one gets slash commands, a streamed
reply, and any approval the turn raises rendered into the same conversation. What a channel may
approve is capped below what the desktop may, and a capped answer is refused in words and
receipted. What was hard: three bugs the suite found rather than review (NOTES, "Findings"), one
of them a self-call deadlock and one a reference mix-up in the console's own log. Deferred: the
real platforms are 071 and 072, as the slice says.

## Gate

```
$ mix gate
prod_check: PASS
3095 mods/funs, found no issues.
... SCAN COMPLETE ...
Result: 564 passed, 18 excluded
trinity.coverage: 050 80.31% vs 061 80.05%: OK
plan_check: PASS
gate exit 0
```

## Tests

```
$ mix test --cover
Finished in 109.2 seconds (0.7s async, 108.4s sync)
Result: 564 passed, 18 excluded
|     80.89% | Total                                  |
```

This slice's modules:

```
|    100.00% | Trinity.Gateways                       |
|    100.00% | Trinity.Gateways.Adapter               |
|    100.00% | Trinity.Gateways.Console               |
|     96.77% | Trinity.Gateways.Format                |
|     95.59% | TrinityWeb.GatewaysLive                |
|     92.86% | Trinity.Gateways.Cap                   |
|     92.00% | Trinity.Gateways.Identities            |
|     90.00% | Trinity.Gateways.Receipts              |
|     84.00% | Trinity.Gateways.Commands              |
|     70.59% | Trinity.Gateways.Router                |
|     40.00% | Trinity.Gateways.Identity              |
```

`Identity` is a schema: its uncovered lines are the changeset's unexercised validation branches.
`Router`'s uncovered lines are the paths a platform adapter reaches and the console does not: the
no-edit branch of the stream (`Console` can edit) and the `{:error, _}` broadcast.

The slice's own suites, named:

```
$ mix test test/trinity/gateways test/trinity_web/live/gateways_live_test.exs --trace
Result: 39 passed
```

## Acceptance criteria evidence

### AC1 [auto]: Console adapter: inbound from a paired identity creates a session with `origin: "console"` and returns a streamed reply

```
* test AC1: a paired identity's message creates a session with the adapter's origin, and the reply streams back (29.6ms)
```

`test/trinity/gateways/router_test.exs`. The message is placed, the reply arrives in the channel,
and the session's `origin` is `"console"` with `origin_ref` `%{"adapter", "conversation",
"external_user_id"}`. The user's message is in the session's history, so the channel and the
desktop are looking at one conversation and not two.

### AC2 [manual + auto]: an unpaired identity receives only a pairing prompt; after the code shown in the UI, the next message is processed

Automatic half:

```
* test AC2 (auto): an unknown sender is shown a code and nothing else happens (1.4ms)
* test an unknown sender is pending with a live code, and nothing else is created (0.3ms)
* test the code pairs the sender once; a wrong code, an expired one and a second use are refused (0.4ms)
* test an expired code is refused, and the next message is given a fresh one (1.0ms)
* test a revoked identity cannot pair and is not admitted (0.5ms)
* test an allowlisted id is paired at first sight, with no code shown (0.3ms)
* test the same external id on two adapters is two identities (0.6ms)
```

"Nothing else" is asserted and not asserted loosely: no session exists (`Sessions.list_sessions()
== []`) and the provider was never called (`Fake.calls() == 0`) after an unknown sender writes.

Manual half, from a running application (`scripts/dev_gateways.sh`, the full transcript in
`proof/ac2-pairing-transcript.txt`):

```
=== AC2: an unknown sender is answered with a pairing code and nothing else ===
  they say: are my tasks done?
  result:   {:error, :pending}
  trinity:  Trinity does not know you yet. Open the desktop app, go to Settings → Gateways, and you will
            see the code HEFAXD. Send that code here to pair. It lasts 10 minutes.
  sessions created so far: 0 (a stranger gets no session)
=== the wrong code is refused, and says only that ===
  they say: AAAAAA
  result:   {:error, :pending}
=== the code from /gateways pairs them ===
  they say: HEFAXD
  result:   {:ok, :paired}
  trinity:  Paired. Say anything and Trinity will answer.
=== and the next message is a message ===
  they say: are my tasks done?
  result:   {:ok, :placed}
  trinity:  Yes: three tasks are due today, and the notes directory changed.
  sessions now: 1
```

The code as the owner sees it: `proof/ac9-gateways-page.png` (the "Waiting to pair" row). That
screenshot is the other half of this criterion as well as AC9's: the code is shown on that page
and nowhere else, which is what makes reading it the proof of pairing.

### AC3 [auto]: `/attach` puts a console conversation and a desktop session on one stream

```
* test AC3: /attach puts the conversation and the desktop on one session (1058.9ms)
```

Both directions are asserted in one test: a message sent through `Sessions.send_user_message/2`
as the LiveView sends it appears in the console's stream, and a message from the console lands in
that same session (`Sessions.list_sessions()` still holds one).

### AC4 [auto]: an approval raised during a gateway turn is rendered in the console; `/approve` resumes it

```
* test AC4: a request raised in a gateway session is rendered there and /approve decides it (56.4ms)
* test /deny from the channel denies it, and an unknown id says so (56.9ms)
* test a raised request in someone else's session is not rendered into this channel (129.1ms)
```

The decision goes through `Permissions.decide_request/3`, so the row records
`decided_by: "gateway:console:u-1"`: who answered is the channel and the account, never "the UI".
A request raised in another session is not rendered here, which is the other half of "an approval
belongs to the surface that asked for it".

### AC5 [auto]: cron delivery to a gateway conversation

```
* test AC5: the run's summary reaches the conversation, and the run is marked delivered (1.6ms)
* test a summary longer than the channel's limit arrives in chunks, not truncated (0.9ms)
* test an unknown adapter or a missing conversation is an error, and nothing is marked delivered (19.7ms)
```

`Trinity.Scheduler.Delivery.Gateway` is 050's behaviour with a second implementation, resolved
from the task row by `Delivery.for/1`. The row names an adapter, never a module: a module name in
a row the scheduler would call is a way to run any module by writing a row.

### AC6 [auto]: past N messages a minute an identity is throttled

```
* test AC6: past its rate limit an identity is answered, not dropped, and recovers (2.1ms)
```

A token bucket in the router's own state, above the session lookup, so a flood costs a row lookup
and nothing more. Each identity has its own bucket, and a throttled sender is told rather than
ignored. No new dependency: `hammer` is not in the tree and this slice does not add one.

### AC7 [auto]: 50 console conversations complete; `integrity_check` ok

```
* test AC7: fifty conversations complete, each in its own session, and the database is intact (210.9ms)
```

Fifty paired identities talk at once through one router process. Every message is placed, every
conversation is answered **in its own channel** (`refute text =~ "hello from"` catches a stream
leaking into another conversation), there are fifty distinct sessions, and `PRAGMA
integrity_check` is `ok` (asked only of SQLite, by `Trinity.Repo.__adapter__()`).

### AC8 [auto]: a `:destructive` approval from a gateway is refused under the default cap, the conversation is told where to decide, and the refusal is receipted

```
* test AC8: a destructive request is refused by the cap, receipted, and left for the desktop (64.2ms)
* test the ceiling is per adapter and configurable, and an unknown tier is refused (0.9ms)
```

Four things are asserted, and the third is the one that matters: the rendered request already
says the channel cannot answer it; `/approve` is refused in words; **the gate is never asked**
(`%Approval{status: "pending", decided_by: nil}` afterwards, so the request is still there for
the desktop); and the refusal is a decision receipt on the session's own chain with basis
`channel_cap`, naming the adapter, the account and the tier. An unknown tier is refused rather
than waved through.

### AC9 [manual]: the `/gateways` page

`proof/ac9-gateways-page.png`, from the running application. It shows the channel with the tier it
may approve (`console … approves up to write`), a live pairing code with allow and revoke, and the
identities list with a paired and a pending row. Automatic half:

```
* test the page lists the channel, whether it runs, and the tier it may approve (2.8ms)
* test a waiting identity's code is shown here, and allow pairs it without a code (3.6ms)
* test revoking keeps the row and shows it as revoked (89.8ms)
* test with no identity and no adapter configured the page says so (1.9ms)
```

## Manual verification for the reviewer

Both `[manual]` criteria have an artefact in `proof/` above. To see either again:

```
$ mix assets.build && ./scripts/dev_gateways.sh    # prints the transcript, then PORT=<n>
```

Then open `http://127.0.0.1:<n>/gateways`. The script runs on `trinity_screenshots.db`, never the
suite's. Kill it by the pid `pgrep -af beam.smp` prints, never by a pattern that also matches your
own shell.

For the channel side by hand rather than scripted: `mix trinity.console` talks to the same router
from a terminal, and pairs the same way.

## Deviations from SLICE.md

See NOTES.md, "Deviations". In short: the cap applies to `Console` like every other adapter
(docs/07 said "desktop or console only" before a console adapter existed, and is amended in this
slice); the rate limit is a token bucket rather than Hammer, so no dependency is added; and
`/attach`'s binding is a pure state transition because a command runs inside the router process.

## Versions touched

`VERSIONS.md` unchanged: this slice adds no dependency.

## Git

```
$ git log --oneline main..HEAD
```
