# Slice 122 — Foundation Sandbox proposal package (owner-gated)

| Field | Value |
|---|---|
| Phase | 13 Open source & donation |
| Milestone | M9 Donatable |
| Size | M |
| Depends on | 120, 121, and the owner's declaration that the repo is ready to be public |
| Labels | owner-action, legal-review |

## Goal
Assemble, in the tree, everything the AAIF project-proposals repository asks for (ADR-0012), so the owner can file
the proposal by copying: the 1–2 page thesis; the proposal information list filled from the tree (license, repo,
public CI/release process, contribution process, issue tracker, dependency licenses, maintainers, governance,
comms channels, website, sponsorship, infra needs); the optional items (integrations with AAIF projects, roadmap,
Scorecard/Best Practices status); an integration demo with goose (Trinity's skills loaded by goose; goose's MCP
servers used by Trinity) recorded as a proof; the AARM and CoSAI mapping docs; the "not an endorsement" README
line ready to insert on acceptance.

## Legal review (answered in NOTES.md, owner's word, before the proposal leaves the tree)
1. Trademark: is the "Trinity" mark offered, and if it is used elsewhere, what is offered instead?
2. IP scope: the tree carries nothing that is not this project's to publish (R21), and the LF technical charter's
   IP terms are read rather than summarised.
3. Three-shelf compliance of every sentence in the thesis and README.

## Acceptance criteria
1. [auto] `docs/aaif/proposal.md` and `docs/aaif/thesis.md` exist and every factual claim cites a command, a tag, or a
   board item.
2. [manual] The goose interop proof (screenshots + commands) is in `proof/`.
3. [auto] The three review questions carry the owner's recorded answers.
4. [manual] Filing is an owner action; this slice is done when the package is complete, not when it is filed.

## Scope
**In:**
- `docs/aaif/thesis.md`, one to two pages.
- `docs/aaif/proposal.md`, the information list filled from the tree: licence, repo, public CI and release process, contribution process, issue tracker, dependency licences, maintainers, governance, comms, website, sponsorship, infra needs.
- Optional items: integrations with foundation projects, roadmap, Scorecard and Best Practices status.
- A goose interop proof: Trinity's skills loaded by goose, goose's MCP servers used by Trinity.
- The standards mapping docs.
- The "Sandbox is not an endorsement" README line, drafted and ready to insert on acceptance.
**Out:**
- Filing. That is an owner action, and this slice is done when the package is complete, not when it is filed.

## Deliverables
- `docs/aaif/thesis.md`, `docs/aaif/proposal.md`, mapping docs, interop proof under `proof/`.

## Proof required
- For each acceptance criterion: the command and its output, or a test name and its result, or a screenshot under `proof/`. A sentence is not proof.

## Manual verification queue
Every `[manual]` criterion below needs a person. Listed here so the owner sees the queue at G1 rather
than at review time.
- **AC2** — The goose interop proof (screenshots + commands) is in `proof/`.
- **AC4** — Filing is an owner action; this slice is done when the package is complete, not when it is filed.

## Definition of Done
- [ ] `mix gate` green · [ ] AC1–4 proven · [ ] docs/ADR/VERSIONS updated if affected · [ ] ROADMAP status → done · [ ] final commit + tag

## Commit & tag
`docs(s122): complete slice 122 — AAIF Sandbox proposal package` · tag `slice/122`
