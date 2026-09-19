<!-- SPDX-License-Identifier: Apache-2.0 -->
# Trinity

A personal AI agent that runs on your own machine. It remembers you, learns procedures, acts
through tools under a permission gate, reaches you on whatever surface you are using, and does
not lose your work when something crashes.

Trinity is built on Elixir and the BEAM, with Phoenix LiveView for the interface, and ships as a
desktop application. Apache-2.0, developed in the open from the first commit.

## Status

Pre-alpha. The repository, quality gate and packaging path are in place and proven (milestone M0).
There is no chat, no model integration and no tool execution yet; those arrive with milestones
M1 and M2. `ROADMAP.md` carries the live status of every slice of work, and the
[Milestones](#milestones) section below explains how to read it.

Nothing here is ready to use. If you want to follow along, watch the roadmap and the tags.

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
mix setup                             # dependencies, database, assets
mix phx.server                        # or: iex -S mix phx.server
```

Then open [localhost:4000](http://localhost:4000). Today that is a scaffold page, not an agent.

`mix gate` runs the full quality gate and has to pass before every commit: format check, compile
with warnings as errors, Credo, Sobelow, dependency audits, version verification, the naming and
secret checks, the tests with coverage, and `scripts/plan_check.sh`, which checks the plan
documents themselves for consistency.

Packaging as a single binary is documented in `docs/packaging.md`, with measured sizes and
start-up times for each target.

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
| M2 Acts | Tools behind a permission gate, one side-effect membrane, local receipts, context compaction | 020 to 024 approved |
| M3 Remembers | Persona, always-on memory, full-text and semantic recall, project context, export and import | 030 to 034 approved |
| M4 Learns | A skills system the agent can extend itself, behind approval and a scanner | 040 and 041 approved |
| M5a Automates | Scheduled tasks and MCP, client and server, with authorization | 050 and 059 to 062 approved |
| M5b Reaches | Messaging gateways and subagents | 070 to 072 and 080 approved |
| M6 Ships | Observability and a cost ledger, native desktop shell, signed releases | 090 to 101 approved |
| M7 Sandboxed | Executable skills in an in-VM sandbox | 110 approved |
| M9 Donatable | Open-source hygiene audited, supply chain signed, shared libraries extracted | 120 to 123 approved |

Slice numbers have gaps on purpose (000, 001, 010, 011 and so on) so that a slice can be inserted
later without renumbering anything.

## What is in the repository

| Path | Purpose |
|---|---|
| `ROADMAP.md` | Every slice with its phase, milestone, dependencies and current status |
| `VERSIONS.md` | The verified dependency versions, generated from `lib/trinity/versions.ex` |
| `CLAUDE.md` | The engineering contract: slice rules, definition of done, proof standard |
| `docs/` | Vision, architecture, tech stack, conventions, slice process, data model, risks, security model, standards |
| `docs/adr/` | Architecture decision records. One is added whenever a decision changes |
| `slices/` | One folder per slice: specification, notes and proof |
| `templates/` | The templates a new slice, proof or decision record starts from |
| `lib/`, `test/`, `config/` | The application |
| `src-tauri/` | The native desktop shell |
| `scripts/`, `credo_checks/` | The plan checker and this project's own Credo checks |

## Connecting Trinity to the platform

Trinity runs standalone, and it is also one component of **Sanction OS**, the platform formed by Requisition and
Ultraviolet.

**Requisition** is the authority layer. Point `TRINITY_AUTHORITY` at the adapter module and Trinity delegates every
catalogued effect to it: Trinity proposes, Requisition decides, and Trinity keeps no executor for those effects.
Trinity refuses to start if the module is absent or does not implement `Trinity.Authority`. See
`docs/adr/0008-authority-is-an-adapter.md` and `docs/adr/0010-authority-selection-at-boot.md`.

**Ultraviolet** is the purple-team tool. Add it to `config :trinity, :mcp_servers` like any other MCP server. Its
read tools return query-receipted results, its proposal tools return proposal ids rather than effects, and content
coming back from it is tagged untrusted like any other external content.

Both are optional. `TRINITY_AUTHORITY=local` with no MCP servers configured is a complete Trinity.

## Contributing, security and governance

See `CONTRIBUTING.md` for how a change gets in, `SECURITY.md` for how to report a vulnerability,
and `GOVERNANCE.md` and `MAINTAINERS.md` for who decides what. `CODE_OF_CONDUCT.md` applies in
every project space.

## License

Apache-2.0. See `LICENSE` and `NOTICE`.
