# Slice NNN: <Title>

| Field | Value |
|---|---|
| Phase | |
| Milestone | |
| Size | S / M / L |
| Depends on | |
| Status | see ROADMAP.md |

## Goal
One paragraph. What exists at the end that did not exist before.

## Why
Which vision goal or scorecard property this serves.

## Scope
**In:**
- …
**Out (explicitly):**
- …

## Design notes
Modules, behaviours, key decisions, sketches. Reference docs/01-architecture.md sections.

## Deliverables
- `lib/…`
- `test/…`
- migrations / docs / config

## Acceptance criteria
Every criterion is tagged `[auto]` or `[manual]`. `[auto]` means a command or a test proves it with no human at a
keyboard. `[manual]` means it needs a person: a screenshot, a fresh machine, a live provider, a real account.
1. [auto] …
2. [manual] …

## Proof required
For each criterion: the command/test/screenshot that demonstrates it.

## Manual verification queue
Every `[manual]` criterion, listed in the G1 plan so the owner sees the queue before the work starts rather than
at review time. One line each: what they do, and what a pass looks like.

## Definition of Done
- [ ] `mix gate` green
- [ ] All acceptance criteria proven in PROOF.md
- [ ] Tests added
- [ ] Docs/ADR/VERSIONS updated if affected
- [ ] ROADMAP status → done
- [ ] Final commit + tag

## Commit & tag
`feat(sNNN): complete slice NNN (<title>)` · tag `slice/NNN`

## Risks / open questions
- …
