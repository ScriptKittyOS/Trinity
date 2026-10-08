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

## Correction, appended 2026-10-08: Sandbox requires the transfer and the charter at entry

The 2026-09-05 correction above was wrong, and the first version of the Context was right. It read the
Sandbox announcement, which summarises, instead of the policy, which governs. The governing text is
`aaif/technical-committee`, `governance/project-lifecycle-policy.md`: Sandbox was added there on
2026-07-08 (commit `d26a92cd`) and Governing Board approval on 2026-08-17 (`b021aaa8`). Its Sandbox
acceptance criteria, verbatim:

1. "Released under an OSI-approved permissive license."
2. "Have a working implementation."
3. "Have at least one actively committing maintainer, with documented intent to grow the contributor base."
4. "Provide a short written thesis (1-2 pages) covering who would use the project, what would justify
   Growth graduation, and either documented early external interest or a credible argument for why the
   project matters pre-adoption."
5. "Meet the standard AAIF requirements: transfer of project trademarks and other assets to the LF, and
   adoption of the LF technical charter."
6. "Receive an absolute majority vote (>50%) of the Technical Committee, subject to final approval of the
   Governing Board."

The same policy sets the clock: "Projects are expected to apply for Growth within twelve months; otherwise
the Technical Committee opens an Emeritus/archival discussion." Graduation needs "documented production use
by at least two unaffiliated organizations" and "commits from at least two organizations over the prior six
months, named committers, and a documented committer-acceptance process." The proposal form asks the
proposer to agree to donate all project trademarks and accounts, and names an organisation signatory for the
contribution agreement. The copy of the process under `aaif/project-proposals` predates Sandbox and is stale.

What this changes:

- Point 5 of the Decision stands, and is now concrete: the contribution agreement assigns trademarks,
  domains and accounts (not copyright; Apache-2.0 and the DCO remain the inbound terms), so legal review
  must cover the signatory, the list of what transfers, and the name.
- **The name.** "Trinity" is a crowded mark, with registrations and pending applications in Class 42
  software and AI services. It stays the code name and the package prefix; a public mark is chosen and
  cleared by counsel before any proposal or public launch.
- **The binding constraint is the twelve-month clock, not the paperwork.** The Consequence above already
  said the proposal waits until two unaffiliated adopters are plausible; that is now the policy's own bar.
