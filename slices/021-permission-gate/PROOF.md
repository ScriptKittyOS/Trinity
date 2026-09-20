# Proof for slice 021: Permission gate + approval UI

Agent: Trinity · Coding Agent · Date: 2026-09-20 · Branch: slice/021-permission-gate · Final commit: (the commit carrying this file; named in the closing correction)

## Summary
The gate docs/07 specifies: a tier from the tool name alone (written once by the registry from the core
modules' declared risks), a layered policy (session grants, the unspent decision for the fingerprint, persona,
global rules, the default by tier), approvals as rows before broadcasts with a fingerprint over RFC 8785
canonical JSON re-derived at execution, a Gate with expiries that survive restarts, the Session's
`approval_wait`, the card, the header indicator and the `/permissions` audit. Every decision is
`decide_request/3`; no button carries authority. The canonicalisation library was measured first (NOTES.md):
`rfc8785` refuses this tree's OTP, `jcs` matches the RFC's own vector, which is now a test. Eight findings in
NOTES.md, the sharpest being a screenshot server that wrote into the test database and a stale gzip the
endpoint served over a fresh stylesheet.

## Gate
```
$ mix gate                                   (this machine, OTP 28.5.0.5, Elixir 1.20.4, under a 32 GiB cgroup, tree 1f3727f)
885 mods/funs, found no issues.
... SCAN COMPLETE ...                        (sobelow --exit --skip: no finding)
No retired or security advisory packages found
No vulnerabilities found.
Result: 233 passed, 10 excluded
trinity.coverage: 020 67.18% vs 013 64.41%: OK
plan_check: PASS
exit=0
```
`mix credo --strict --all`: 885 mods/funs, found no issues. `mix assets.build`: exit 0.

## Tests
```
$ mix test --cover                           (tree 1f3727f)
Result: 233 passed, 10 excluded
    |      0.00% | Trinity.Permissions.Policy.Default     |
    |     60.00% | Trinity.Permissions.Approval           |
    |     82.14% | Trinity.Permissions.Policy.Layered     |
    |     86.36% | Trinity.Permissions.Rule               |
    |     88.68% | Trinity.Permissions.Gate               |
    |     89.23% | TrinityWeb.PermissionsLive             |
    |     89.80% | TrinityWeb.ApprovalComponents          |
    |     91.67% | Trinity.Permissions                    |
    |     95.83% | Trinity.Permissions.Store              |
    |    100.00% | Trinity.Permissions.Fingerprint        |
    |    100.00% | Trinity.Permissions.Policy             |
    |     72.45% | Total                                  |
```
`coverage.tsv` row: `021  72.45  1f3727f  2026-09-20` (from 67.18 at 020).

The 29 tests of `test/trinity/permissions` and `test/trinity_web/live/approval_live_test.exs`, with timings from `--trace`:
```
test AC1: a read-risk tool runs with no request: the Gate sees nothing  * test AC1: a read-risk tool runs with no request: the Gate sees nothing (4.0ms) [L#37]
test AC2 (LiveView half): the card renders with tool, risk and arguments; Allow once runs the tool and the final message follows  * test AC2 (LiveView half): the card renders with tool, risk and arguments; Allow once runs the tool and the final message follows (12.2ms) [L#43]
test AC2 (test half): a write-risk call enters approval_wait; allow once runs it; the final message follows  * test AC2 (test half): a write-risk call enters approval_wait; allow once runs it; the final message follows (5.0ms) [L#49]
test AC3: allow for session: the second identical call runs without asking; other arguments ask; a new session asks  * test AC3: allow for session: the second identical call runs without asking; other arguments ask; a new session asks (1044.2ms) [L#74]
test AC5: deny: the tool row carries a denial the model reads; the turn goes on to a final message  * test AC5: deny: the tool row carries a denial the model reads; the turn goes on to a final message (5.0ms) [L#108]
test AC8: killed in approval_wait, the request is still pending and decidable; the restarted session is idle  * test AC8: killed in approval_wait, the request is still pending and decidable; the restarted session is idle (7.5ms) [L#136]
test Always allow writes the edited pattern as a rule; Deny denies  * test Always allow writes the edited pattern as a rule; Deny denies (50.1ms) [L#70]
test jcs matches the RFC 8785 example vector byte for byte  * test jcs matches the RFC 8785 example vector byte for byte (6.4ms) [L#9]
test key=glob: * within a segment, ** across, ? one character, a trailing * is a prefix  * test key=glob: * within a segment, ** across, ? one character, a trailing * is a prefix (0.1ms) [L#15]
test keys are sorted and numbers are ES6 shortest, whatever the map's order  * test keys are sorted and numbers are ES6 shortest, whatever the map's order (0.02ms) [L#15]
test * matches anything; fp: matches the fingerprint only  * test * matches anything; fp: matches the fingerprint only (0.00ms) [L#9]
test /permissions lists every decision with its time and decider, the pending ones decidable, the rules revocable (AC7's page)  * test /permissions lists every decision with its time and decider, the pending ones decidable, the rules revocable (AC7's page) (84.9ms) [L#110]
test re: is accepted from a hand-edited row; a broken regex matches nothing  * test re: is accepted from a hand-edited row; a broken regex matches nothing (0.03ms) [L#26]
test the changeset refuses a pattern outside the language and a scope outside the vocabulary  * test the changeset refuses a pattern outside the language and a scope outside the vocabulary (0.06ms) [L#31]
test the Gate AC6: an undecided request expires into a denial decided by expiry, within the configured timeout  * test the Gate AC6: an undecided request expires into a denial decided by expiry, within the configured timeout (1001.6ms) [L#167]
test the Gate AC7: every decision is a row with decided_at, listed newest first  * test the Gate AC7: every decision is a row with decided_at, listed newest first (0.8ms) [L#185]
test the Gate a decided request cannot be decided twice; an unknown id is not found  * test the Gate a decided request cannot be decided twice; an unknown id is not found (0.5ms) [L#160]
test the Gate always: a global rule with the confirmed pattern; a call outside it still asks (AC4)  * test the Gate always: a global rule with the confirmed pattern; a call outside it still asks (AC4) (32.5ms) [L#137]
test the Gate a request is a row, then a broadcast on the session's topic and on all  * test the Gate a request is a row, then a broadcast on the session's topic and on all (0.8ms) [L#96]
test the Gate deny: the row is denied, the fingerprint is denied once, then asks again (AC5's core)  * test the Gate deny: the row is denied, the fingerprint is denied once, then asks again (AC5's core) (2.2ms) [L#149]
test the Gate once: the row is allowed with decided_at and decider, the fingerprint allows one execution, then asks again  * test the Gate once: the row is allowed with decided_at and decider, the fingerprint allows one execution, then asks again (0.8ms) [L#107]
test the Gate session: a grant row scoped to the session with an expiry; the second identical call allows  * test the Gate session: a grant row scoped to the session with an expiry; the second identical call allows (0.7ms) [L#127]
test the header indicator counts everyone's pending requests on every page  * test the header indicator counts everyone's pending requests on every page (61.4ms) [L#134]
test the layers a global rule with a glob allows inside the pattern and not outside (AC4's core)  * test the layers a global rule with a glob allows inside the pattern and not outside (AC4's core) (0.6ms) [L#29]
test the layers an expired session grant no longer allows  * test the layers an expired session grant no longer allows (0.4ms) [L#78]
test the layers a persona policy sits above global rules and below session grants  * test the layers a persona policy sits above global rules and below session grants (0.7ms) [L#43]
test the layers a session grant is bound to the fingerprint: other arguments ask, another session asks (AC3's core)  * test the layers a session grant is bound to the fingerprint: other arguments ask, another session asks (AC3's core) (0.8ms) [L#60]
test the layers the default by tier: read allows, write asks, an unmapped name asks  * test the layers the default by tier: read allows, write asks, an unmapped name asks (0.7ms) [L#23]
test the same call is the same digest; a changed argument, scope or cwd is another  * test the same call is the same digest; a changed argument, scope or cwd is another (6.0ms) [L#20]
```

## Acceptance criteria evidence

### AC1 [auto]: a read-risk tool executes with no approval (the Gate not called)
`AC1: a read-risk tool runs with no request: the Gate sees nothing`: subscribed to `approvals:all`, a turn calling
`echo` never enters `approval_wait`, no `{:approval, _, _}` arrives, `list_approvals(session_id:)` is empty, the
tool row is the echo. The Gate is a process, not a behaviour, so "not called" is measured as "no row and no
broadcast", which is everything a call would produce. The policy's default: `the default by tier: read allows,
write asks, an unmapped name asks`.

### AC2 [manual]: write-risk tool → approval_wait; the card renders; allow once → the tool runs → final message
Tests: `AC2 (test half): a write-risk call enters approval_wait; allow once runs it; the final message follows`
(Session: the request broadcast, `state/1` says `approval_wait`, `pending/1` lists it; after `:once` the tool row
reads "wrote 2 bytes", the final message arrives, the approval is `allowed` and consumed) and `AC2 (LiveView
half)` (the card with tool, risk badge and arguments, status `approval_wait`, the header indicator at 1, the
suggested pattern `path=/home/me/notes/*`; Allow once clears the card, the tool result and the final text are on
the page, the row is `allowed once liveview`). Screenshots from the chat on the test registry
(`scripts/dev_chat_on_test_registry.sh`): `proof/ac2-approval-card.png` and `proof/ac2-allow-once-final.png`.

### AC3 [auto]: allow for session → the second identical call runs without asking; a new session asks again
`AC3: allow for session ...` (Session): after `:session`, the identical call runs with no request; other
arguments under the same grant ask again (M2: the fingerprint differs); a new session asks. Core: `a session
grant is bound to the fingerprint: other arguments ask, another session asks` and `an expired session grant no
longer allows`; the grant row: `session: a grant row scoped to the session with an expiry`.

### AC4 [auto]: always allow with a path pattern → a persisted rule; a call outside the pattern still asks
`always: a global rule with the confirmed pattern; a call outside it still asks` (the rule row with the pattern;
inside allows, `/home/me/secrets/k` asks; revoked, it asks again) and, through the page, `Always allow writes
the edited pattern as a rule; Deny denies` (the pattern edited to `path=/home/me/**` before the click, the rule
row carries it, the next call runs without a card, a call at `/etc/hosts` asks). The pattern language:
`Trinity.Permissions.RuleTest`.

### AC5 [auto]: deny → the tool message carries a denial the model can read; the session continues
`AC5: deny: the tool row carries a denial the model reads; the turn goes on to a final message`: two calls in
one turn, one denied and one echo; rows `["user", "assistant", "tool", "tool", "assistant"]`, the denied row
`error: :denied` with `ok: false`, the final message from the next model call. Screenshot
`proof/ac5-denied.png` (the fake's canned final text after the denial is the script's, not the model's).

### AC6 [auto]: expiry → auto-deny after the configured timeout
`AC6: an undecided request expires into a denial decided by expiry, within the configured timeout`: with
`expiry_ms: 1_000`, the `{:approval, :decided, %{status: "expired", decision: "deny", decided_by: "expiry"}}`
broadcast arrives within 1,500 ms, the row has `decided_at`, and the call asks again afterwards.

### AC7 [manual]: every decision has an approvals row with decided_at; /permissions lists them
`AC7: every decision is a row with decided_at, listed newest first` and `/permissions lists every decision with its
time and decider, the pending ones decidable, the rules revocable`. Screenshot `proof/ac7-permissions-audit.png`
(nine decisions from the screenshot runs, each with its time, tool, risk, arguments, decision and decider).

### AC8 [auto]: killing the Session during approval_wait → after restart the approval is still pending and decidable
`AC8: killed in approval_wait, the request is still pending and decidable; the restarted session is idle`:
`Process.exit(pid, :kill)` in `approval_wait`; the supervisor restarts the session idle with nothing pending
(012's reset is total); `pending/1` still lists the row; `decide_request/3` records it and broadcasts; the tool
did not run (the turn died with the process) and the session takes the next message.

### Platform alignment: M2 and M7
M2: `Trinity.Permissions.FingerprintTest` (the RFC vector; the same call the same digest; a changed argument,
scope or cwd another) and the AC3 test's "other arguments ask again". M7: the card's buttons and the audit page
push `approval_decide`, which calls `decide_request/3`; the LiveView tests drive the buttons and read the rows.

## Manual verification for the reviewer
1. AC2: `mix assets.build`, remove `priv/static/assets/**/*.gz`, then `scripts/dev_chat_on_test_registry.sh`;
   open the printed port, New session, send anything. Expected: the reply starts, the card appears with
   `write_note`, the `WRITE` badge, the arguments and the four buttons; Allow once; the tool result and the
   final message follow.
2. AC7: send another message, Deny; open `/permissions`. Expected: both decisions listed with times and
   `liveview` as the decider.

## Deviations from SLICE.md
See NOTES.md: the four stated at G1 (no pre-check, once as a consumed approval, a denial bound to its turn,
the persona layer's shape) and finding 1 (`decide/4`).

## Versions touched
`VERSIONS.md` updated: yes, `jcs ~> 0.2` added with its row (the `rfc8785` alternative and why not, in the row).
`mix hex.audit` and `mix deps.audit` clean.

## Git
```
$ git log --oneline main..HEAD
1f3727f feat(s021): the permission gate: layered policy, fingerprints, the Gate, approval_wait, the card and the audit
897be2b chore(s021): add jcs ~> 0.2
c3125f8 docs(s021): G1 plan with the canonicalisation measured, and the slice opens
```

## Closing correction, 2026-09-20
Supersedes the "Final commit" field in the header: the commit carrying this file is `a32d705`
(`feat(s021): complete slice 021 (permission gate and approval UI)`); the `git log` block above lists the
commits before it. The pull request, its merge commit (signed in its body) and the tag come after review.

## Correction, 2026-09-20: the postgres job
The `postgres` check failed on the closing tree (run 35528824468): the Gate's `init/1` read the `approvals`
table in a job that boots the application before migrating (NOTES.md finding 9). Fixed in the commit after this
record: the reload is a `handle_continue` that rescues into a warning. The `gate` job was green on the same tree.
The run that closes this is named in the next correction.
