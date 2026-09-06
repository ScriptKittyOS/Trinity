# Slice 120 — Open-source hygiene and governance, audited

| Field | Value |
|---|---|
| Phase | 13 Open source & donation |
| Milestone | M9 Donatable |
| Size | S |
| Depends on | 000 (files exist), 090 |

## Goal
Everything Slice 000 created is re-audited against the AAIF proposal information list and the Apache-2.0 / REUSE /
DCO requirements after the codebase has grown: every file carries a valid SPDX header or a `.license` sidecar;
`NOTICE` is correct for every vendored or bundled third-party asset (Bumblebee model weights, fonts, icons,
`receipt-verification` vendor copy with its CC/Apache terms); `THIRD_PARTY_LICENSES.md` derived from `mix.lock`
(`mix licenses` or equivalent, command named); `GOVERNANCE.md` states the committer process; README carries the
three-shelf disclosure sentence and, once in Sandbox, the "not an endorsement" line.

## Acceptance criteria
1. [auto] `reuse lint` exit 0; the derived third-party license list is complete (a planted dependency without a license
   entry makes the check fail).
2. [auto] The name check from slice 000 exits 0 over contents and paths: zero hits for either code name, and the
   four platform names only inside the README's connection section.
3. [auto] R21 recorded: the tree carries no IP that is not this project's to publish, by the owner's word on the 024 field set.
4. [auto] `git log --all` contains zero commits without `Signed-off-by` (command + count).

## Scope
**In:**
- Re-audit every file created since commit 1 for a valid SPDX header or a `.license` sidecar.
- `NOTICE` correct for every vendored or bundled third-party asset, including model weights, fonts and icons.
- `THIRD_PARTY_LICENSES.md` derived from `mix.lock` by a named command, not by hand.
- `GOVERNANCE.md` states the committer process as it actually stands.
- README disclosures current.
**Out:**
- Supply chain signing and SBOM (121); the proposal package (122).

## Deliverables
- Updated `NOTICE`, `THIRD_PARTY_LICENSES.md`, `GOVERNANCE.md`, README section, audit output in PROOF.md.

## Proof required
- For each acceptance criterion: the command and its output, or a test name and its result, or a screenshot under `proof/`. A sentence is not proof.

## Definition of Done
- [ ] `mix gate` green · [ ] AC1–4 proven · [ ] docs/ADR/VERSIONS updated if affected · [ ] ROADMAP status → done · [ ] final commit + tag

## Commit & tag
`chore(s120): complete slice 120 — OSS hygiene and governance audit` · tag `slice/120`
