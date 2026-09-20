# Slice 021: NOTES

## The canonicalisation, measured 2026-09-20 before any code

The fingerprint docs/07 and this slice's M2 rule name is `sha256(rfc8785_canonical({tool, args, scope, cwd,
canonicalization_version}))`. Two RFC 8785 packages on hex, read from their tarballs in a scratch directory and
run against the RFC's own example (section 3.2.3: the `numbers`, `string` and `literals` object):

| Candidate | Result | Derived by |
|---|---|---|
| `rfc8785` 1.0.0 (2026-07-24, 935 downloads, no runtime deps, 1,377 lines, an ES6 number corpus in its own suite) | **Refuses to compile on this tree's OTP**: `rfc8785 requires Erlang/OTP 29 or later (found OTP 28)`. The OTP pin is 28.5.0.5 for Burrito's ERTS (VERSIONS.md), so it is out until the pin moves. | `mix deps.get && mix run` in the scratch project |
| `jcs` 0.2.0 (2025-03-31, 91,772 downloads, depends on jason, 402 lines, Apache-2.0) | **Matches the RFC vector byte for byte**, numbers included (`1e+30`, `4.5`, `0.002`, `1e-27`, and `2.0` as `2`), through `:erlang.float_to_binary(:short)`; keys sorted as the RFC asks. Pre-1.0 and eighteen months since its release: R11's trigger, noted. | the same, `Jcs.encode/1` against `expected.txt` |

**Decision at G1: `jcs ~> 0.2`**, with the RFC vector as a test in the tree so a later version that stops
matching fails the gate, and `canonicalization_version` 1 bound into every fingerprint so a change of scheme is a
new version rather than a silent difference. Open to the owner's veto.

## G1 plan, 2026-09-20

Tree at `81b8da1` on `main` (020 and 013 approved); branch `slice/021-permission-gate`; ROADMAP row 021 set to
`in_progress` in this commit. docs/07's permission gate section is the contract. Each line names its test.

1. `chore(s021): add jcs ~> 0.2`; `Trinity.Permissions.Fingerprint`: `canonical/1` (jcs) and `of/4`
   (`sha256` hex over `{tool, args, scope, cwd, canonicalization_version: 1}`). Tests: the RFC 8785 vector; the
   same call twice is the same digest; a changed argument, scope or cwd is a different one.
2. Migrations: `tool_permissions` (tool, pattern, decision, scope, expires_at, decided_by, timestamps) and
   `approvals` (session_id, tool, args, risk, fingerprint, status, decision, decided_at, decided_by, consumed_at,
   expires_at, timestamps); schemas `Permissions.Rule` and `Permissions.Approval`; `Permissions.Store` inside the
   boundary. docs/05 synced. Test: the two tables through the store on SQLite; the postgres job on both.
3. The tier's source. 020 left `Permissions.tier/1` an empty attribute because Permissions may not read the
   registry; here the registry hands the core tools' declared risks to Permissions at admission
   (`Permissions.put_core_tiers/1`, Tools → Permissions, the allowed direction), a dynamic tool never does, and
   `tier/1` reads that table by name alone. Test: the census's "every mapped name is a core tool" gains content;
   `tier("echo")` is `:read`, `tier("mcp:fake:echo")` is `:ask`.
4. `Permissions.Policy.Layered` (the implementation in force): session grants (rules scoped `session:<id>`, a
   fingerprint pattern `fp:<hex>`, unexpired) → an unconsumed "once" approval for the fingerprint (consumed on
   use) → a denied approval for the fingerprint in this turn → persona policy (`settings.permissions`) → global
   rules (a glob on one named argument, `key=glob`, `*` for any; prefix as a trailing `*`) → the default by
   tier (config `permissions: [default: %{read: :allow, network: :allow, write: :ask, exec: :ask, destructive:
   :ask}]`, unmapped `:ask`). Tests: each layer in isolation and the order between two.
5. `Permissions.Gate` (GenServer): `request/4` writes the pending row, broadcasts `{:approval, :requested, a}` on
   `approvals:<session_id>` and `approvals:all` (row before broadcast), arms the expiry
   (`permissions: [expiry_ms: 600_000]`, short in test); `decide_request/3` (`:once | :session | :always |
   :deny`) updates the row, writes the grant or the rule (always: the pattern the user confirmed), broadcasts
   `{:approval, :decided, a}`; expiry decides `:deny` as `"expiry"`; pending rows are reloaded at init with their
   timers. Tests: AC6 (expiry within the short timeout, the row `expired`, the decision `deny`), AC7's auto half
   (every decision a row with `decided_at`), a decided row cannot be decided twice.
6. The runner: an `:ask` answer creates the request through the Gate and returns
   `{:error, {:approval_required, approval_id}, meta}`; the Session, seeing one in the turn's results, holds those
   calls, enters `approval_wait` (the state 012 left without an inbound transition), subscribes to
   `approvals:<id>` at init, and on the last decision re-runs the held calls, where the runner asks the policy
   again: the once grant or the session grant allows, the denial denies, and the fingerprint is re-derived from
   the arguments actually passed (a divergence is `:deny`). Tests: AC1 (Echo, `:read`, runs with the Gate's
   `request/4` never called, a Mox on the Gate's behaviour), AC3 (a session grant: the second identical call
   runs without asking, a different argument asks again, a new session asks), AC4 (an always rule with a glob:
   a call inside runs, outside asks; the rule row exists), AC5 (deny: the tool row says denied, the turn goes
   on to a final message), AC8 (kill during `approval_wait`: the row is pending after the restart, deciding it
   updates the row and broadcasts; the restarted session is idle, as 012's reset-is-total requires).
7. LiveView: `TrinityWeb.ApprovalComponents.approval_card` (tool, risk badge, arguments pretty-printed, the danger
   line for `:exec` and `:destructive`, the four buttons; "always" shows the pre-filled, editable pattern),
   rendered in `SessionLive.Show` while a request is pending; a pending count in the shell's bar from
   `approvals:all`; `PermissionsLive` at `/permissions` listing approvals (decided and pending) and rules with
   a revoke. Everything the UI does is `Permissions.decide_request/3`; the buttons carry no authority (M7).
   Tests: the card renders on `{:approval, :requested, _}`; each button decides; `/permissions` lists the row.
8. Screenshots for AC2 and AC7 from the dev server driven by chromium, as at 013, with a write-risk test tool
   available in dev (the fake provider flag gains a tool script). docs/07 synced; docs/01 tree.
9. Gate, coverage row, PROOF.md, ROADMAP to `done`, pull request (signed merge body), tag.

Manual verification queue, for the owner at G4:
- **AC2**: `TRINITY_FAKE_PROVIDER=1 mix phx.server`, a session, send "write"; the fake calls a write-risk tool;
  the card appears; "Allow once"; the tool runs and the final message follows. Screenshot.
- **AC7**: after a few decisions, open `/permissions`: every decision listed with its time. Screenshot.

Deviations from SLICE.md, stated before building: the runner asks the policy at execution and the Session never
pre-checks, so `decide/3` stays exactly once per execution attempt (020 AC7) and the M2 re-derivation is the same
call; "allow once" is an approval row consumed at its one use, not a rule; a denial is bound to the fingerprint
for the turn that asked and never outlives it; the persona layer reads `personas.settings["permissions"]`
(`tool => decision`), the smallest shape 030 can grow.
