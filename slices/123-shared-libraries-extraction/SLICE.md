# Slice 123 — Extract the shared components as Hex packages (ADR-0011)

| Field | Value |
|---|---|
| Phase | 13 Open source & donation |
| Milestone | M9 Donatable |
| Size | L |
| Depends on | 062, 082, 083, 040, 120; and the owner's package-naming decision |
| Labels | composition |

## Goal
Move the boundary-isolated components from in-repo apps to published Hex packages with their own CI, docs, SBOM
and signed releases: the MCP client and server, MCP authorization, receipt verification, content provenance, and
the agent-skills parser and registry. Trinity then consumes them by version like any other dependency. Package
names are an owner decision at this slice.

## Acceptance criteria
1. [auto] Each package builds, tests and publishes from its own repo; `mix hex.info <pkg>` shows the release.
2. [auto] Trinity's `mix.lock` pins the published versions; `boundary` still passes; behaviour unchanged (gate green).
3. [auto] A consumer smoke test: a fresh Phoenix app adds the MCP authorization package and serves PRM plus a CIMD
   login in the number of steps its README states (count recorded).
4. [auto] The cross-repo notes are posted (links recorded) and each asked question has a place for the answer.

## Scope
**In:**
- Move each boundary-isolated component from an in-repo app to its own repo and Hex package, with its own CI, docs, SBOM and signed releases.
- Trinity consumes them by version like any other dependency.
- A consumer smoke test from a fresh Phoenix app.
**Out:**
- Extracting anything whose boundary is not already clean; fix the boundary first.

**Rationale: to be written on standalone merits.**

## Deliverables
- One repo and Hex release per component, `mix.lock` pinning the published versions, consumer smoke test recorded.

## Proof required
- For each acceptance criterion: the command and its output, or a test name and its result, or a screenshot under `proof/`. A sentence is not proof.

## Definition of Done
- [ ] `mix gate` green · [ ] AC1–4 proven · [ ] docs/ADR/VERSIONS updated if affected · [ ] ROADMAP status → done · [ ] final commit + tag

## Risks / open questions
- One of the working package names is already taken on hex (measured 2026-09-05: `provenance`, 0.1.0, 2026-03-05).
  The replacement is the owner's call at this slice. The other working names were free on that date. Names also
  need revisiting against the naming policy before anything is published.

## Commit & tag
`feat(s123): complete slice 123 — shared libraries extracted` · tag `slice/123`
