# ADR-0012 — Open source from commit 1; target AAIF Sandbox when the owner says it is ready
Status: accepted · Date: 2026-09-05

## Context
Owner goal: Trinity ends up open source and is donated to the Agentic AI Foundation. AAIF's lifecycle policy
(effective 2026-03-18; Sandbox added 2026-09-01) requires for Sandbox, as the Sandbox announcement states it: a
working implementation, plus either early external interest or a credible thesis, plus a named active maintainer.
Corrected 2026-09-05: the first version of this Context also listed an OSI licence, a thesis length, transfer of
project trademarks and assets to the LF, the LF technical charter and a TC majority vote. The announcement states
none of those at Sandbox. The charter text has not been read; everything about asset transfer and the Growth bar is
**unverified** until it is. Sandbox READMEs
must state that Sandbox is not an endorsement. Proposals go through `github.com/aaif/project-proposals` with a fixed
information list (license, public repo, public CI/release process, contribution process, issue tracker, dependency
licenses, maintainers, governance, comms channels, website, sponsorship, infra needs; optional: integrations with AAIF
projects, roadmap, OpenSSF Best Practices badge).

## Decision
1. **Apache-2.0** with `NOTICE` naming the three roles (owner of the IP, builder, author), SPDX headers, REUSE,
   DCO from commit 1.
   The repo is private until the owner declares it ready; the history is publishable at every commit.
2. Governance files exist from Slice 000 and grow honestly: single maintainer stated, committer process documented.
3. Supply chain (slice 121): CycloneDX SBOM per release, Sigstore-signed artifacts, SLSA provenance via GitHub
   attestations, OpenSSF Scorecard workflow, Best Practices badge pursued.
4. Standards integrations with AAIF projects are deliberate: MCP (core + Tasks + EMA), AGENTS.md, Agent Skills
   compatibility, goose interop tested (skills and MCP), A2A optional.
5. **Legal review before any proposal** (slice 122): what is offered (the "Trinity" mark, the agent code) and what
   is retained; confirmation that the tree carries no IP that is not this project's to publish; the LF technical
   charter read rather than summarised.
6. Target stage: **Sandbox**, with the thesis: a BEAM-native, authority-separated personal agent that composes
   with an external authority plane, and reference implementations of MCP auth/EMA and Agent Skills on the BEAM.

## Consequences
- Every public-facing claim in the README follows the three-shelf rule: agent claims here, authority claims cited.
- Sandbox's 12-month Growth clock means the proposal is filed only when two unaffiliated adopters are plausible.
