# Slice 021: Permission gate + approval UI

| Field | Value |
|---|---|
| Phase | 2 Tools |
| Milestone | M2 Acts |
| Size | M |
| Depends on | 020, 013 |

## Goal
`Trinity.Permissions` decides allow/deny/ask per tool call from layered policy; `:ask` suspends the Session in
`approval_wait`, shows an approval card in LiveView (and later gateways), records decisions, supports "allow once /
allow for session / always allow / deny", and has a full audit trail. Per `docs/07-security-model.md`.

## Why
Vision goal 5. Nothing side-effecting runs without consent.

## Scope
**In:**
- `Trinity.Permissions.Policy` behaviour (`decide/3`); default policy by `risk/0`; `tool_permissions` + `approvals` tables.
- `Trinity.Permissions.decide/3` resolution order (session grants → persona → global → default); pattern matching on args (glob for paths, prefix for commands).
- `Trinity.Permissions.Gate` GenServer: creates approval requests, broadcasts on `approvals:<session_id>` and `approvals:all`, applies decisions, expiry (default 10 min → deny).
- Session integration: `approval_wait` state; resumes tool execution on allow; records a tool error on deny; timeout handled.
- LiveView: approval card (tool, risk badge, args pretty-printed, danger explanation for `:exec`/`:destructive`), 4 decision buttons, pending-approvals indicator in header, audit list at `/permissions`.
- Config: `permissions: [default: %{read: :allow, network: :allow, write: :ask, exec: :ask, destructive: :ask}]`.
**Out:**
- Gateway approvals (070 hooks into the same topics), skill approvals (041 reuses Gate).

## Design notes
- Decisions are data: everything the UI does is `Trinity.Permissions.decide_request(id, decision, opts)`.
- "Always allow" writes a `tool_permissions` row with the arg pattern the user confirms (pre-filled, editable).

## Deliverables
- `lib/trinity/permissions/{policy,default_policy,gate,rule,approval}.ex`, `lib/trinity/permissions.ex`, migrations, session changes, LiveView components/pages, tests.

## Acceptance criteria
1. [auto] Read-risk tool executes with no approval (Mox on Gate not called).
2. [manual] Write-risk tool → Session enters `approval_wait`; approval card renders (LiveView test + screenshot); "allow once" → tool runs → final message.
3. [auto] "Allow for session" → second identical call runs without asking; a new session asks again (test).
4. [auto] "Always allow" with a path pattern → persisted rule; a call outside the pattern still asks (test).
5. [auto] Deny → tool message contains a denial the model can see; session continues (test).
6. [auto] Expiry → auto-deny after configured timeout (test with short timeout).
7. [manual] Every decision has an `approvals` row with `decided_at`; `/permissions` lists them (screenshot).
8. [auto] Killing the Session during `approval_wait` → after restart the approval is still pending and decidable (crash test).

## Proof required
- Tests, screenshots of the card and audit page.

## Manual verification queue
Every `[manual]` criterion below needs a person. Listed here so the owner sees the queue at G1 rather
than at review time.
- **AC2**: Write-risk tool → Session enters `approval_wait`; approval card renders (LiveView test + screenshot); "allow once" → tool runs → final message.
- **AC7**: Every decision has an `approvals` row with `decided_at`; `/permissions` lists them (screenshot).

## Definition of Done
- [ ] gate green · [ ] AC1–8 proven · [ ] docs/07 synced · [ ] ROADMAP → done · [ ] commit + tag

## Commit & tag
`feat(s021): complete slice 021 (permission gate and approval UI)` · tag `slice/021`

## Risks / open questions
- Pattern language: start with glob for paths and prefix for commands; regex only via manual rule editing.

## Platform alignment (appended 2026-09-05)
- **M2 binding:** an approval binds `approval_fingerprint = sha256(rfc8785_canonical({tool, args, scope, cwd,
  canonicalization_version}))`. "Allow once" and "allow for session" bind that fingerprint; "always allow" binds a
  rule pattern and is recorded as a rule, not an approval. At execution the fingerprint is re-derived from the
  args actually passed and compared; divergence denies and receipts (replace the AC3/AC4 wording accordingly:
  a second call with different args asks again even under "allow for session").
- **M7:** a click-through past a warning is recorded as input to `Trinity.Permissions.Policy.decide/3`, which is
  deterministic and server-side; the UI cannot authorize by rendering.
- **Approvals are DB rows before they are broadcast**; a Session restart re-reads them (already AC8).
- **This slice writes no receipts.** It owns its own audit trail, the `approvals` table, which records every
  decision with its fingerprint, decider and timestamp. Slice 024 owns the `receipts` table, its schema, its chain
  and its signer, and reads the approvals audit when it builds decision receipts. The earlier plan had this slice
  writing unsigned rows into a table slice 024 creates, which is both an ordering error and a naming one: a row in
  a table called `receipts` that is neither chained nor signed is a name making a claim it cannot meet.
