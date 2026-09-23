<!-- SPDX-FileCopyrightText: Sudo Apt Holdings LLC -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
# Changelog

Trinity is developed in reviewed units of work, each merged through a pull request with the
quality gate green and then tagged. This file records what each tag delivered and how it was
verified. It is derived from the tags themselves (`git tag -l 'slice/*'`), not written from
memory.

The project is pre-alpha: there is no supported release series yet, and tags mark reviewed
increments rather than supported versions. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
loosely; versioning is by increment, and semantic versions begin at the first supported release.

Every entry below was gated on: formatting, a compile with warnings as errors, the architectural
boundary check, Credo (strict), Sobelow, dependency and licence audits, the full test suite and a
coverage floor. Entries from 2026-09-22 onward also required a release build check. Verification
evidence for each increment is retained by the maintainers and summarised here.

## Unreleased

- Repository restructured for public review: internal planning material moved out of the published
  tree, engineering rules consolidated into `docs/03-conventions.md`, and this changelog added as
  the public record of delivered work.

## 2026-09-23

### `slice/070` — Gateway core
Trinity becomes reachable from channels other than the desktop. An adapter behaviour carries text
and nothing else; a router admits the sender, applies a rate limit, dispatches commands and binds
the conversation to a session, streaming the reply back. An unknown sender receives a pairing code
and nothing else: no session is created and no model is called until they are paired. Approvals
raised during a channel-originated turn are rendered into that conversation, and what a channel may
approve is capped below what the local desktop may, with the refusal recorded in the receipt chain.
Ships an in-process console adapter; messaging platforms follow.

## 2026-09-22

### `slice/062` — MCP authorization
OAuth 2.1 in every role for the Model Context Protocol surface: a resource server validating
audience-bound tokens against an external authorization server, an optional personal-profile
authorization server for a single operator's own machine, and a client role that obtains tokens
from protected servers. Identity is separated from authority throughout: a token establishes who is
calling, while the permission gate and the selected authority adapter decide whether an effect may
happen. No token material reaches model context, logs or receipts.

### `slice/061` — MCP server
Trinity serves the Model Context Protocol at revision 2026-07-28 over Streamable HTTP and stdio,
with compatibility for 2025-11-25. Calls arriving over the protocol pass the same permission gate
and effect membrane as local ones and leave the same receipts. A call requiring approval is held
with sealed, tamper-evident state that the client retries once the operator has decided.

### `slice/050` — Scheduler
Scheduled agent tasks on durable jobs, surviving restart, with cron or one-shot schedules, delivery
targets, and a curator that marks stale records and archives untouched ones without deleting.

## 2026-09-21

### `slice/060` — MCP client
A thin client driver: outbound requests are built here while decoding and validation use the
protocol core's published functions. Every tool a server exposes becomes a namespaced tool that
cannot borrow a built-in tool's permissions, every result is treated as untrusted content, and a
server's mid-call question becomes an operator approval rather than an automatic answer.

### `slice/059` — MCP capability assessment
A measured gap analysis of the protocol core against the 2026-07-28 checklist, and a probe of the
extension seam the server side needs, recorded as findings rather than intentions.

### `slice/041` — Skill self-management
Skills the system proposes for itself pass through staged approval and a scanner before becoming
active.

### `slice/040` — Skills registry
A registry for the open `SKILL.md` format with progressive disclosure of instructions.

### `slice/032` — Semantic memory
Embeddings, semantic recall and hybrid retrieval, with a local model option and a vector store
behind a behaviour.

## 2026-09-20

### `slice/034` — Export, import, restore
The operator's data leaves in a documented archive format and comes back, with manifest validation.

### `slice/033` — Project context
`AGENTS.md` from a session's project roots is loaded into context with precedence and a size cap.

### `slice/031` — Session search
Full-text search over conversation history using SQLite FTS5.

### `slice/030` — Persona and always-on memory
A persona document and a memory tier always present in context, scoped session, persona and global,
with a budget and truncation recorded as evidence.

### `slice/024` — Effects, authority and receipts
The effect catalog, authority selection at boot, and locally signed receipts. Authority is an
adapter behind a behaviour: the shipped implementation decides locally, and a deployment may supply
an external one, in which case this tree keeps no executor for the effects that adapter governs.
Receipts are an Ed25519-signed hash chain with checkpoints and a verifier.

### `slice/023` — Context compaction
Conversations that outgrow the window are compacted with lineage retained.

### `slice/022` — Core tools
Filesystem, web fetch and search, and a shell tool, each behind the permission gate, with content
from outside the machine marked untrusted.

### `slice/021` — Permission gate
Every tool call is decided before it runs: allow once, for the session, or by a written rule, with
the decision and its basis receipted. Approval surfaces carry no authority of their own.

### `slice/020` — Tool protocol and registry
Tools are modules behind a behaviour plus a configuration entry; adding one requires no change to
any core module, and the registry test asserts it.

### `slice/013` — Chat interface
Streaming conversation in LiveView, with model output rendered through a single path.

### `slice/012` — Session process
One supervised process per session, with crash recovery proven by killing the process.

### `slice/011` — Model provider layer
Providers behind one behaviour, switched by configuration, with usage recorded per call.

### `slice/010` — Core domain and persistence
The data model and repository layer, SQLite first with PostgreSQL supported, with gapless ordering
under concurrent writers proven by a stress test.

### `slice/003` — FIPS build leg
A continuous integration leg that builds from source and runs the cryptographic properties inside a
FIPS-mode container, so claims about approved algorithms are measured rather than asserted.

## 2026-09-07

### `slice/001` — Packaging
A self-contained desktop binary produced for Linux, macOS and Windows, each smoke-tested in CI.

## 2026-09-06

### `slice/000` — Toolchain and quality gate
The repository, the pinned toolchain and the gate every later change has had to pass.
