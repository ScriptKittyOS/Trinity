<!-- SPDX-License-Identifier: Apache-2.0 -->
# Trinity

A personal AI agent that runs on your own machine. It remembers you, learns procedures, acts
through tools under a permission gate, reaches you on whatever surface you are using, and does
not lose your work when something crashes.

Trinity is built on Elixir and the BEAM, with Phoenix LiveView for the interface, and ships as a
desktop application. Apache-2.0, developed in the open from the first commit.

## Status

Pre-alpha, and usable from source. Milestones M0 to M4 are approved, and four slices of M5a
(050, the scheduler; 059, the MCP measurement; 060, the MCP client; 061, the MCP server) with
them: 23 slices, each merged with a merge commit and tagged `slice/NNN` (`git tag -l 'slice/*'
| wc -l` → 23, on 2026-09-22). What that means in practice:

- **Talks.** Streaming chat with any provider behind one behaviour (`Trinity.LLM`), switched by
  configuration; the assistant's text is persisted as a draft every 500 ms or 2 KB while it
  streams, so a crash mid-turn loses at most that much. Context compaction with lineage when a conversation outgrows the
  model's window.
- **Acts.** Filesystem, web and shell tools behind a permission gate with fingerprint-bound
  approvals; every effect passes one membrane and leaves a signed, hash-chained receipt you can
  verify offline (`mix trinity.receipts.verify`). A FIPS build leg in CI proves the receipt scheme
  under OpenSSL's FIPS provider.
- **Remembers.** A persona (its SOUL), a small always-on memory with a byte budget and a
  consolidator instead of truncation, full-text search over every past conversation, a semantic
  tier filled by an observer after each turn and recalled by meaning (local embeddings, never a
  hosted call unless you opt in), project context from `AGENTS.md`, and export and import of the
  whole thing as one archive.
- **Learns.** Skills as directories with a `SKILL.md` in the agentskills.io format, found under
  the project, the data directory and the bundled set, shown to the model by progressive
  disclosure (an index in the prompt, the body on request). The agent can propose new skills and
  changes to them, and distil a document into one, but nothing it proposes is applied until you
  approve it on the skills page: every proposal is staged with a diff, scanned for shell pipes,
  credentials and instructions to ignore safety, and promoted through the permission gate with a
  receipt.
- **Connects.** MCP servers you add on the `/mcp` page, over stdio (a child process that sees
  only the environment variables you name) or Streamable HTTP, at the 2026-07-28 revision with
  2025-11-25 as the fallback. Every tool a server lists becomes a tool the assistant can call,
  namespaced so it can never borrow a built-in tool's permissions, asking you until you write a
  rule; every result is marked untrusted; and when a server needs input mid-call it asks you,
  on the permissions page, before the call continues. The other direction too: Trinity is an
  MCP server at `POST /mcp` (and over stdio), exporting the read-only tools by default and
  any others you name; a client's call passes the same gate and leaves the same receipts as
  the assistant's own, and one that needs your approval waits for it on the permissions page
  while the client carries a sealed state it can retry with. A headless release runs the same
  tree as a server, in a container or under systemd (`docs/mcp-server.md`).
- **Runs on a schedule.** Tasks on the `/tasks` page: a prompt, a persona, the skills to hint,
  and when (a cron expression, a one-shot time, or a phrase like "every weekday at 9am" the
  model turns into cron). Each run is a fresh conversation you can open, its result waits on
  the page until you have read it, and the work is a durable job (Oban on the app's own
  database) that survives a restart and retries a failed turn. The memory observer and a
  curator that marks old memories stale and archives the untouched ones (never deleting)
  run on the same queues; `/oban` shows the jobs.

Not there yet: MCP's authorization roles (M5a), messaging gateways and subagents (M5b),
the native desktop shell and signed releases (M6), executable skills in a sandbox (M7). `ROADMAP.md` carries the live status of every
slice, and the [Milestones](#milestones) section below explains how to read it.

The interface is a local web page; the desktop shell exists as a packaging spike, not a product.
If you want to follow along, watch the roadmap and the tags.

## Why the BEAM

Agents of this shape tend to fail in the same few ways: one synchronous loop that exits and loses
a run, database corruption when two processes write the same file, memory that degrades every
time it is compressed, and a note in the documentation asking you not to run two copies at once.
Those are failures of the substrate, not of the product. The BEAM was built to remove that class
of failure, so on it these properties can be structural rather than aspirational:

- A crash in one session, tool or gateway never affects another and never loses persisted state.
- One agent, seen on the desktop, in Telegram and in Discord at the same time, in real time.
- Memory in tiers: a small always-on set of facts plus unlimited retrievable history.
- Every side-effecting action passes a permission gate, and dangerous ones need explicit approval.
- Any model or provider, cloud or local, switched by configuration.

`docs/00-vision.md` states the goals, the non-goals and the properties the design has to
demonstrate, each tied to the slice that proves it.

## Running from source

Requires the pinned toolchain in `.tool-versions` (Erlang 28.5.0.5, Elixir 1.20.4, Zig 0.16.0),
installed with `asdf install`. Rust 1.92.0 is pinned separately in `rust-toolchain.toml` and is
only needed for the desktop shell.

```
git config core.hooksPath .githooks   # once, before your first commit
cp .env.example .env                  # then put a provider key in it
mix setup                             # dependencies, database, assets
mix phx.server                        # or: iex -S mix phx.server
```

Then open [localhost:4000](http://localhost:4000): new conversation, pick a model, talk. The
model registry is `config/llm.exs`; keys come from the environment (`.env` is gitignored). The
pages: `/` conversations, `/s/:id` a conversation and `/s/:id/receipts` its receipts, `/search`
full-text search, `/personas` and `/memory` the persona and its memory (with the semantic tab and
the embedding model's download), `/skills` the skills, the changes waiting for your decision and
the learn form, `/mcp` the MCP servers you connect to (their health and the tools they
contribute), `/permissions` the rules and pending approvals (a server's question to you, when
one of its tools asks for input mid-call, is answered there too), `/tasks` the scheduled tasks and
their results, `/oban` the jobs (in development, or when configured), `/settings` the export. `mix trinity.export` and `mix trinity.import` do what `/settings` does from a terminal;
`docs/backup.md` explains the archive.

Semantic recall needs the local embedding model (91 MB, downloaded from the memory page on your
say-so, never on its own). Without it the tier is off and full-text search still works;
`docs/perf.md` has what it costs.

`mix gate` runs the full quality gate and has to pass before every commit: format check, compile
with warnings as errors, Credo, Sobelow, dependency audits, version verification, the naming and
secret checks, the tests with coverage, and `scripts/plan_check.sh`, which checks the plan
documents themselves for consistency.

Packaging as a single binary is documented in `docs/packaging.md`, with measured sizes and
start-up times for each target; `docs/fips-leg.md` describes the FIPS build leg.

## How the work is organised

Trinity is built in slices. A slice is one unit of planning, work, proof, review and history:
small enough to review in one sitting and large enough to deserve a tag.

Each slice has a folder under `slices/` holding its specification (`SLICE.md`), the working notes
and deviations recorded while it was built (`NOTES.md`), and the evidence that it met its
acceptance criteria (`PROOF.md`). Proof means the command that was run and the output it produced,
pasted in, or a screenshot for anything visual. A sentence saying something works is not proof.

A slice moves through `planned`, `ready`, `in_progress`, `done` and `approved`. Only the
maintainer sets `approved`, after reading the proof. Each approved slice is merged with a merge
commit and tagged `slice/NNN`, so the history is the audit log.

Two rules shape everything else. Records are appended to and never rewritten: a wrong line stays
where it is and is corrected below it, saying what it supersedes. And a count, a hash, a date or
a version is never typed from memory; it is derived from the tree by a command that is named next
to it.

`docs/04-slice-process.md` has the full lifecycle and the review gates. `CLAUDE.md` is the
engineering contract that every change is held to.

## Milestones

| Milestone | Meaning | Reached when |
|---|---|---|
| M0 Stands | Repository, quality gate and packaging path proven | 000 and 001 approved |
| M1 Talks | Streaming chat with any provider, persisted and crash-safe | 010 to 013 approved |
| M2 Acts | Tools behind a permission gate, one side-effect membrane, local receipts, context compaction; the FIPS build leg | 003 and 020 to 024 approved |
| M3 Remembers | Persona, always-on memory, full-text and semantic recall, project context, export and import | 030 to 034 approved |
| M4 Learns | A skills system the agent can extend itself, behind approval and a scanner | 040 and 041 approved |
| M5a Automates | Scheduled tasks and MCP, client and server, with authorization | 050 and 059 to 062 approved |
| M5b Reaches | Messaging gateways and subagents | 070 to 072 and 080 approved |
| M6 Ships | Observability and a cost ledger, native desktop shell, signed releases | 090 to 101 approved |
| M7 Sandboxed | Executable skills in an in-VM sandbox | 110 approved |
| M9 Donatable | Open-source hygiene audited, supply chain signed, shared libraries extracted | 002 and 120 to 123 approved |

M0 to M4 are approved as of 2026-09-22, and 050, 059, 060 and 061 of M5a with them. Slice numbers have gaps on purpose (000, 001, 010, 011 and so on) so that a slice can be inserted
later without renumbering anything.

## What is in the repository

| Path | Purpose |
|---|---|
| `ROADMAP.md` | Every slice with its phase, milestone, dependencies and current status |
| `VERSIONS.md` | The verified dependency versions, generated from `lib/trinity/versions.ex` |
| `CLAUDE.md` | The engineering contract: slice rules, definition of done, proof standard |
| `docs/` | Vision, architecture, tech stack, conventions, slice process, data model, risks, security model, standards; packaging, the FIPS leg, backup and restore, performance measurements |
| `docs/mcp-server.md` | Connecting a client to Trinity's MCP server (Claude Code, VS Code, Codex, goose), stdio, approvals over the wire, the headless profile |
| `slices/059-mcp-library-spike/FINDINGS.md` | What the MCP server core (`beam_mcp`) ships, carries, refuses or leaves open against the 2026-07-28 checklist; the reference for the MCP phase |
| `docs/adr/` | Architecture decision records. One is added whenever a decision changes |
| `slices/` | One folder per slice: specification, notes and proof |
| `templates/` | The templates a new slice, proof or decision record starts from |
| `lib/`, `test/`, `config/` | The application |
| `src-tauri/` | The native desktop shell |
| `scripts/`, `credo_checks/` | The plan checker, the benchmark scripts and this project's own Credo checks |
| `ci/fips/` | The container the FIPS leg builds its toolchain in |
| `coverage.tsv` | Test coverage per slice, appended at each close |

## Connecting Trinity to the platform

Trinity runs standalone, and it is also one component of **Sanction OS**, the platform formed by Requisition and
Ultraviolet.

**Requisition** is the authority layer. Point `TRINITY_AUTHORITY` at the adapter module and Trinity delegates every
catalogued effect to it: Trinity proposes, Requisition decides, and Trinity keeps no executor for those effects.
Trinity refuses to start if the module is absent or does not implement `Trinity.Authority`. See
`docs/adr/0008-authority-is-an-adapter.md` and `docs/adr/0010-authority-selection-at-boot.md`.

**Ultraviolet** is the purple-team tool. Add it on the `/mcp` page like any other MCP server (since slice 060 a server is a row, not a config entry). Its
read tools return query-receipted results, its proposal tools return proposal ids rather than effects, and content
coming back from it is tagged untrusted like any other external content.

Both are optional. `TRINITY_AUTHORITY=local` with no MCP servers configured is a complete Trinity.

## Contributing, security and governance

See `CONTRIBUTING.md` for how a change gets in, `SECURITY.md` for how to report a vulnerability,
and `GOVERNANCE.md` and `MAINTAINERS.md` for who decides what. `CODE_OF_CONDUCT.md` applies in
every project space.

## Related projects

[beam_mcp](https://github.com/ScriptKittyOS/beam_mcp) is a Model Context Protocol server core for
the BEAM from the same organisation, on Hex as `beam_mcp`. Trinity depends on it since slice 059,
pinned at 0.8.0 and reached only through the `Trinity.MCP` boundary; slice 059's `FINDINGS.md`
measures what it ships against the 2026-07-28 checklist, and the MCP phase (milestone M5a) builds
Trinity's client driver (slice 060: a thin driver over the core's decoder and validator, stdio
and Streamable HTTP, 2026-07-28 preferred and 2025-11-25 as the fallback, a server's mid-call
question answered as an approval), the approval loop and authorization above it. The client side
and the authorization server are Trinity's own work. `docs/adr/0007-mcp-2026-07-28-target-and-library.md`
records the protocol target and the layering.

## License

Apache-2.0. See `LICENSE` and `NOTICE`.
