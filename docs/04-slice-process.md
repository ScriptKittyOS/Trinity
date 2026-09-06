# 04 — Slice process

A slice is the unit of planning, work, proof, review, and history. It is small enough to review in one sitting
and large enough to be worth a tag.

## Lifecycle

```
planned ──(deps approved)──▶ ready ──(agent starts)──▶ in_progress ──(DoD met)──▶ done ──(human reviews)──▶ approved
                                                            │                                     │
                                                            └──── blocked (agent asks) ◀──────── changes requested
```

A `blocked` slice carries, in ROADMAP.md and in its NOTES.md, the thing it waits on and a lift condition someone
outside the project could check. "Blocked" without both is a status with no content.

## Gates

| Gate | Who | What passes |
|---|---|---|
| G0 Ready | human | Dependencies approved; SLICE.md reviewed; questions answered |
| G1 Plan | agent | Agent posts a ≤ 15-line implementation plan in NOTES.md before coding (files, modules, tests), **plus the slice's `[manual]` verification queue**. Human may veto within the same turn; otherwise proceed. |
| G2 Gate | CI/agent | `mix gate` green |
| G3 Proof | agent | PROOF.md complete; every acceptance criterion has evidence |
| G4 Review | human | Reads PROOF.md, spot-checks code, runs the manual verification if listed. Sets `approved` or `changes requested` in ROADMAP.md |

## The per-slice folder

```
slices/NNN-short-name/
├── SLICE.md      # spec (written by the plan; may be amended by the human)
├── NOTES.md      # agent: plan, deviations, follow-ups, version proposals
├── PROOF.md      # agent: evidence
└── proof/        # screenshots, GIFs, logs
```

## Amending a slice

The human may edit SLICE.md before `in_progress`. After that, changes go into NOTES.md as "Amendment" entries
with the human's approval quoted, and the acceptance criteria list in SLICE.md is updated in the same commit.

## Inserting a slice

Numbering has gaps (000, 001, 010, 011 …). Insert `NNN` between neighbours, add to ROADMAP.md with dependencies,
add a SLICE.md from the template. Never renumber existing slices.

## Splitting a slice

If a slice grows past L, split it: `NNNa`, `NNNb` with the original as parent. Record in ROADMAP change log.

## What "approved" means

The human has read the proof and accepts the slice as delivered. It is now history. Bugs found later are new
slices or fix commits referencing the original (`fix(s022): …`), never rewrites.

## Working with multiple coding agents

Assign disjoint dependency branches (see ROADMAP graph). Each agent owns its slice branch. Merges to `main`
happen in ID order within a phase, by the human or a designated agent. Conflicts are resolved on the later branch.
