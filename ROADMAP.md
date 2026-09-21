# Roadmap

Status values: `planned` → `ready` (deps approved) → `in_progress` → `done` (agent) → `approved` (human).
`blocked` is also a status, as `docs/04-slice-process.md` has always defined it, and was missing from this legend.
A slice marked `blocked` names its blocker and a lift condition a stranger can check. `withdrawn` means the slice
is not being built in this tree; the row stays so the numbering gap is explained.
Sizes: S ≈ half a day, M ≈ 1–2 days, L ≈ 3–5 days of agent work. Sizes are estimates for planning, not deadlines.
A size given as `M or L` is conditional on a decision named in that slice's file.

## Milestones

| Milestone | Meaning | Reached when |
|---|---|---|
| **M0 Stands** | Repo, gate, packaging path proven | 000, 001 approved |
| **M1 Talks** | Streaming chat with any provider, persisted, crash-safe | 010–013 approved |
| **M2 Acts** | Tools with permission gate, one side-effect membrane, local receipts, context compaction; the FIPS build leg that proves 024's properties | 003, 020–024 approved |
| **M3 Remembers** | Persona, always-on memory, FTS + semantic recall, project context, and data you can take with you | 030–034 approved |
| **M4 Learns** | Skills system with agent self-management + approval | 040–041 approved |
| **M5a Automates** | Cron tasks and MCP, client and server, with authorization | 050, 059–062 approved |
| **M5b Reaches** | Gateways over PubSub, subagents | 070–072, 080 approved (081 optional, outside the milestone) |
| **M6 Ships** | Observability, native desktop shell, signed releases | 090–101 approved |
| **M7 Sandboxed** | Executable skills in an in-VM sandbox | 110 approved |
| **M9 Donatable** | OSS hygiene audited, supply chain signed, AAIF Sandbox package complete, shared libraries extracted | 002, 120–123 approved (122 filing is an owner action) |

Slices 025 and 026 carry no milestone: they serve regulated deployments after M2 and are assigned when the
standards register names the rows that ask for them.

## Slices

| ID | Slice | Phase | Size | Depends on | Status |
|---|---|---|---|---|---|
| 000 | Toolchain, repo bootstrap, quality gate | 0 Foundation | L | none | approved |
| 001 | Packaging spike: Burrito + ex_tauri smoke build | 0 Foundation | M | 000 | approved |
| 002 | Supply chain, early: SBOM, build provenance, the TLS floor | 0 Foundation | S | 000 | planned |
| 003 | FIPS build leg in CI, from source | 0 Foundation | M | 000 | approved |
| 010 | Core domain + persistence (Ecto/SQLite, schemas, Repo owner) | 1 Core loop | M | 000 | approved |
| 011 | LLM provider layer (req_llm behind `Trinity.LLM` behaviour) | 1 Core loop | M | 010 | approved |
| 012 | Session process + agent loop (gen_statem, DynamicSupervisor, rehydration) | 1 Core loop | L | 010, 011 | approved |
| 013 | LiveView chat UI with streaming | 1 Core loop | M | 012 | approved |
| 020 | Tool protocol + registry | 2 Tools | M | 012 | approved |
| 021 | Permission gate + approval UI (M2 fingerprint-bound, M7) | 2 Tools | M | 020, 013 | approved |
| 022 | Core tools: filesystem, web fetch/search, shell (MuonTrap) | 2 Tools | L | 021 | approved |
| 023 | Context compaction + session lineage | 2 Tools | M | 012 | approved |
| 024 | Effect catalog, authority selection (`TRINITY_AUTHORITY`), local receipts | 2 Tools | L | 021, 022 | approved |
| 025 | Encryption at rest, and the key-custody seam | 2 Tools | M | 010, 024 | planned |
| 026 | Store-and-forward receipts for disconnected operation | 2 Tools | L | 024 | planned |
| 030 | Persona (SOUL) + always-on memory tier | 3 Memory | M | 012 | approved |
| 031 | Session search (SQLite FTS5) | 3 Memory | S | 010 | approved |
| 032 | Embeddings + semantic memory + hybrid retrieval | 3 Memory | L | 031 | approved |
| 033 | Project context: AGENTS.md | 3 Memory | S | 030, 022 | approved |
| 034 | Export, import, restore | 3 Memory | S | 030, 031 | approved |
| 040 | Skills registry + agentskills.io format + progressive disclosure | 4 Skills | M | 020 | approved |
| 041 | Skill self-management with staged approval + scanner | 4 Skills | M | 040, 021 | done |
| 050 | Scheduler: Oban cron agent tasks with delivery targets | 5 Automation | M | 012 | planned |
| 059 | MCP capability gap against beam_mcp, and the server seam probe | 6 MCP | S/M | 020 | planned |
| 060 | MCP client: Trinity's thin driver (2026-07-28 preferred, 2025-11-25 compat, MRTR, Tasks) | 6 MCP | L | 059, 021 | planned |
| 061 | MCP server (stateless 2026-07-28 + compat, MRTR approvals, headless profile) | 6 MCP | M | 060, 024 | planned |
| 062 | MCP authorization: OAuth client role, RS, embedded AS, Enterprise Managed Authorization (ID-JAG) | 6 MCP | L | 061 | planned |
| 070 | Gateway core: adapter behaviour, routing, PubSub fan-out | 7 Gateways | M | 012 | planned |
| 071 | Gateway: Telegram | 7 Gateways | S | 070 | planned |
| 072 | Gateway: Discord (Nostrum) | 7 Gateways | S | 070 | planned |
| 080 | Subagents + delegation | 8 Orchestration | M | 020, 023 | planned |
| 081 | A2A v1.0 Agent Card + task intake (optional) | 8 Orchestration | M | 080, 061 | planned (optional) |
| 082 | withdrawn: delegating effects to an external authority layer is the adapter's job, outside this tree | none | none | none | withdrawn |
| 083 | withdrawn: verifying another system's receipts belongs with that system's adapter | none | none | none | withdrawn |
| 084 | withdrawn: connecting to a specific MCP server is configuration, not a slice | none | none | none | withdrawn |
| 090 | Observability: telemetry, cost ledger, LiveDashboard | 1 Core loop | M | 011 | planned |
| 100 | Desktop shell: ex_tauri window, tray, notifications, keychain | 10 Desktop | L | 001, 013 | planned |
| 101 | Release pipeline: signing, notarization, auto-update | 10 Desktop | L | 100 | planned |
| 110 | Luerl sandbox + executable skills | 11 Sandbox | L | 041 | planned |
| 120 | OSS hygiene and governance, audited | 13 Open source & donation | S | 000, 090 | planned |
| 121 | Supply chain: SBOM, Sigstore, SLSA, Scorecard, MCP Registry entry | 13 Open source & donation | M | 101, 120 | planned |
| 122 | Foundation Sandbox proposal package (owner-gated, needs legal review) | 13 Open source & donation | M | 120, 121 | planned |
| 123 | Extract shared components as Hex packages | 13 Open source & donation | L | 062, 040, 120 | planned |

## Minimum viable Trinity

The subset that is a usable product on its own: **000, 010, 011, 012, 013, 020, 021, 022, 030, 031, 090, 100.**

A desktop agent that talks to any provider, uses filesystem, web and shell tools under a permission gate, remembers
you, searches its own history, shows what it costs, and runs as a real application. It omits skills, automation,
MCP, gateways, subagents and the sandbox, all of which are additive rather than load-bearing.

Named so that work can stop at a shippable point rather than wherever the calendar stops. Sizes remain estimates
for planning, not deadlines; the point here is the cut line, not a duration.

## Dependency graph (what can run in parallel)

```
000 ─┬─ 001 ─────────────────────────────────────────── 100 ── 101
     ├─ 002 (supply chain, early)
     ├─ 003 (FIPS build leg; runs 024's FIPS tests)
     └─ 010 ─┬─ 011 ─┬─ 090
             │       └─ 012 ─┬─ 013 ── 021 ── 022 ── 024 ─┬─ 061 ── 062
             │               │                             ├─ 025 (also needs 010)
             │               │                             └─ 026
             │               ├─ 020 ─┬─ 040 ── 041 ── 110
             │               │       ├─ 059 ── 060 ── 061
             │               │       └─ 080 ── (081 optional, also needs 061)
             │               ├─ 023
             │               ├─ 030 ─┬─ 033
             │               │       └─ 034
             │               ├─ 050
             │               └─ 070 ─┬─ 071
             │                       └─ 072
             └─ 031 ─┬─ 032
                     └─ 034
```

After 012, multiple branches are independent. If running more than one coding agent, assign disjoint branches
(e.g. one on 020→022, another on 030→032). Merge order is by ID within a phase.

## Change log

| Date | Change |
|---|---|
| 2026-09-05 | Initial plan. 26 slices, 8 milestones. |
| 2026-09-05 | Project named Trinity. |
| 2026-09-05 | Standards pass: MCP 2026-07-28 is the target; anubis_mcp (≤ 2025-11-25, LGPL) no longer assumed; 059 spike added; 060/061 rewritten; 062 added (MCP RS auth); 033 (AGENTS.md) and 081 (A2A, optional) added. ADR-0007. |
| 2026-09-05 | Enterprise auth folded into Trinity's own MCP authorization server plus the managed-authorization extension (062, resized to L). Open-source posture made first-class: ADR-0012, OSS hygiene from commit 1 in slice 000, phase 13 (120–123), milestone M9. |
| 2026-09-05 | Authority made an adapter behind a behaviour rather than a mode (ADR-0008, ADR-0010). ADR-0009 opened for the Jido question, decided at the 012 checkpoint. Slice 024 added: effect catalog, `TRINITY_AUTHORITY`, local receipts. Alignment appendices on 012, 020, 021, 022, 023, 030, 032, 040, 041. |
| 2026-09-05 | Review pass before commit 1. Counts in the three entries above were typed, not derived, and none matches the tree; a decreasing count is impossible under insert-never-renumber. Derived this date: `find slices -name SLICE.md | wc -l` → **38**. Milestones are derived from the Milestones table, not from memory. From here, any count in this log names the command that produced it. Entries above are not rewritten. |
| 2026-09-06 | Plan corrections, round 2. **Supersedes the slice count in the entry above:** that entry derived **38** on 2026-09-05, before slices 082, 083 and 084 were withdrawn and slice 034 was added. Re-derived this date, not adjusted by arithmetic: `find slices -name SLICE.md | wc -l` → **36**. The entry above is not rewritten. `scripts/plan_check.sh` now enforces this count, the acceptance-criteria numbering, the Definition-of-Done ranges, ROADMAP/SLICE.md agreement, and the absence of references to paths not in `git ls-files`. |
| 2026-09-20 | The MCP phase replanned under owner decisions of 2026-09-08, recorded in ADR-0007 decisions 5 to 8: beam_mcp 0.8.0 is the server core; 059 measures the capability gap and probes the `:server` seam (S/M); 060 is Trinity's thin driver (L, the M/L condition decided); the OAuth client role moves from 060 to 062; 061 carries a named blocker on the MRTR wrapper; the four `M5 Always-on` headers on 059 to 062 read M5a Automates, as this file has since 2026-09-08. R14 re-scoped, R15 closed. Re-derived this date: `find slices -name SLICE.md | wc -l` → **36**. |
| 2026-09-20 | Four slices added under the accepted 2026-09-20 plan: 002 (supply chain, early: SBOM, provenance, TLS floor; counted in M9), 003 (FIPS build leg from source; counted in M2 because it runs 024's FIPS properties), 025 (encryption at rest and the key-custody seam) and 026 (store-and-forward receipts; blocked on the external plane's answer). Re-derived this date: `find slices -name SLICE.md | wc -l` → **40**. |
