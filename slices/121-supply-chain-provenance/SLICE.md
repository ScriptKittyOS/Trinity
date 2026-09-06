# Slice 121 — Supply chain: SBOM, signed releases, provenance, Scorecard, MCP Registry entry

| Field | Value |
|---|---|
| Phase | 13 Open source & donation |
| Milestone | M9 Donatable |
| Size | M |
| Depends on | 101, 120 |

## Goal
Every release ships a CycloneDX SBOM (generated from `mix.lock` plus the ERTS/Tauri/Rust layers where a tool exists;
what cannot be enumerated is stated), artifacts signed with Sigstore (`cosign`) and carrying SLSA provenance via
GitHub artifact attestations, an OpenSSF Scorecard workflow with its results linked from the README, a Best
Practices badge application, and a `server.json` for the MCP Registry describing Trinity's MCP server.

## Acceptance criteria
1. [auto] CI release job produces `sbom.cdx.json` per artifact; a validator exits 0 (command).
2. [auto] `cosign verify-blob` and `gh attestation verify` succeed on a released artifact from a clean machine (outputs).
3. [auto] Scorecard workflow runs on `main`; score recorded in PROOF.md with the date; each sub-check below 5 has a NOTES
   entry (fix or reason).
4. [manual] `server.json` validates against the MCP Registry schema (command); publication itself is an owner action.
5. [auto] Release notes name what is signed and how to verify, in ≤ 10 lines.

## Scope
**In:**
- CycloneDX SBOM per release artifact, generated from `mix.lock` plus the ERTS and shell layers where a tool exists. What cannot be enumerated is stated, not omitted.
- Sigstore signing of artifacts; SLSA provenance via GitHub artifact attestations.
- OpenSSF Scorecard workflow on `main`, results linked from the README.
- OpenSSF Best Practices badge application.
- `server.json` for the MCP Registry.
**Out:**
- Publishing to the registry; that is an owner action.

## Deliverables
- Release workflow additions, `sbom.cdx.json` per artifact, `.github/workflows/scorecard.yml`, `server.json`, `docs/release.md` updates.

## Proof required
- For each acceptance criterion: the command and its output, or a test name and its result, or a screenshot under `proof/`. A sentence is not proof.

## Definition of Done
- [ ] `mix gate` green · [ ] AC1–5 proven · [ ] docs/ADR/VERSIONS updated if affected · [ ] ROADMAP status → done · [ ] final commit + tag

## Commit & tag
`feat(s121): complete slice 121 — supply chain and provenance` · tag `slice/121`
