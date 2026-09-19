# 00: Vision

## One sentence
A personal AI agent that runs on your machine, remembers you, learns procedures, acts through tools, reaches
you on any surface, and never loses your work, built on the BEAM so those properties are structural,
not aspirational.

## What we are building

A self-hosted agent with curated memory, a self-improving skills library, a persona, a tool ecosystem, cron
automations, and gateways to messaging platforms.

Agents of this shape usually fail in the same few ways: a single synchronous loop that can exit and lose a run,
database corruption when more than one process writes the same file, memory that degrades every time it is
compressed, and a rule somewhere in the documentation saying not to run two of them at once. Those are failures of
substrate, not of product design. The BEAM was built to eliminate exactly that class, which is why it is the
substrate here.

## Goals

1. **Never lose work.** A crash in one session, tool, or gateway never affects another and never loses persisted state.
2. **One agent, every surface.** Desktop UI, Telegram, Discord (and more) see the same session in real time.
3. **Memory that scales.** Tiered: small always-on facts + unlimited retrievable episodic/semantic memory.
4. **Skills that grow safely.** The agent can write its own procedures, gated by approval and a scanner.
5. **Tools with consent.** Every side-effecting action passes a permission gate; dangerous ones need explicit approval.
6. **Provider-agnostic.** Swap models/providers (cloud or local) by config, mid-conversation.
7. **Runs as a real desktop app.** Native window, tray, notifications, signed builds, auto-update.
8. **Inspectable.** Every process, cost, and decision is visible (LiveDashboard, telemetry, cost ledger).
9. **Standards-covering.** Trinity implements or consumes the open standards its own surfaces touch, and the
   pieces that do so are built to be extractable as libraries in their own right.
10. **Donatable.** Trinity is built from commit 1 as an open-source project that can be proposed to the Agentic AI
   Foundation at Sandbox stage (ADR-0012): OSI license, governance files, DCO, SBOM, signed releases, a thesis.
   It is developed in the open from the first commit.

## Non-goals (for v1)

- A hosted multi-tenant SaaS. This is single-user, local-first. (Design does not preclude it.)
- Training/RL pipelines. Trajectory export may come later.
- Mobile apps. (elixir-desktop could enable it later; not in scope.)
- Breadth of integrations at launch. We ship depth first: 2 gateways, roughly 10 tools.

## Principles

- **OTP is the architecture.** Processes are the unit of isolation. Supervisors are the recovery strategy.
- **Behaviours + registries = modularity.** Nothing pluggable is hard-wired. Adding a tool is adding a module.
- **Data outlives processes.** Every process rehydrates from the DB. The DB is the source of truth.
- **Safety is a gate, not a suggestion.** Permission checks and sandboxes are in the execution path, not documentation.
- **Proof over claims.** Every slice ends with evidence.
- **Latest stable, verified.** Not "latest", not "what I remember".

## Scorecard: the properties this design must demonstrate

| Property | How it is demonstrated (slice) |
|---|---|
| A turn survives the death of the process running it | Kill a Session mid-turn; it restarts and resumes from persisted state (012) |
| The database cannot be corrupted by concurrent writers | Concurrent sessions + gateway writes with zero corruption under a stress test (010, 070), **and a data-dir lock so a second OS process cannot open the same file at all** (010) |
| Many sessions and personas run in one node, isolated | N sessions, M personas, in one node, isolated (012, 030). One node per data dir is enforced, not assumed (010) |
| Memory has no compression ceiling | Always-on tier stays small; retrieval tier is unbounded with hybrid search (030–032) |
| One session is observed on several surfaces at once | Same session streamed to LiveView and Telegram simultaneously (070–071) |
| Delegation costs a process, not a subprocess | Supervised subagent processes with message passing (080) |
| Scheduled work is durable, retried and observable | Durable, retried, observable Oban jobs (050) |
| A write cannot silently truncate a file | Write-validation hook rejects truncation markers (022) |
| Skill promotion cannot bypass approval, and every artifact write is gated and receipted | Promotion through the gate with a receipt; per-file digests (024, 040, 041) |
