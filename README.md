<!-- SPDX-License-Identifier: Apache-2.0 -->
# Trinity

[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/14772/badge)](https://www.bestpractices.dev/projects/14772)

A personal AI agent that runs on your own machine. It remembers you, learns procedures, acts
through tools under a permission gate, reaches you on whatever surface you are using, and does
not lose your work when something crashes.

Trinity is built on Elixir and the BEAM, with Phoenix LiveView for the interface, and ships as a
desktop application. Apache-2.0, developed in the open from the first commit.

## Status

Pre-alpha, and usable from source. Milestones M0 to M4 are approved, **M5a Automates** with them
(050, the scheduler; 059, the MCP measurement; 060, the MCP client; 061, the MCP server; 062, MCP
authorization), and the first slice of M5b (070, the gateway core): 25 slices, each merged with a
merge commit and tagged `slice/NNN` (`git tag -l 'slice/*' | wc -l` → 25, on 2026-09-23). What
that means in practice:

**Assessed against a recognised baseline.** Trinity holds the
[OpenSSF Best Practices **silver** badge](https://www.bestpractices.dev/projects/14772), awarded
2026-09-23. Silver is the Open Source Security Foundation's second tier: it takes the passing bar
for basics, change control, reporting, quality, security and analysis, which is the prerequisite
the Linux Foundation names for a project entering Incubation, and adds documented governance and
roles, continuity of access, a published roadmap, a written test policy, 80% statement coverage,
and an assurance case carrying a threat model, its trust boundaries, an argument that secure design
principles were applied and an argument that common implementation weaknesses were countered.

Every required criterion at both levels is met. What is *not* met is recorded rather than
stretched, because a sheet with nothing on it survives a spot check less well than one that says
where the gaps are: at silver, two suggested-tier criteria (a bus factor of two, and an
accessibility assessment) and one suggestion about signed version tags are marked unmet with the
reason. The [assurance posture](#assurance-posture) below states what the build enforces and what
enforces it.

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
- **Knows who is calling.** Trinity's MCP server is an OAuth 2.1 resource server for the
  authorization server you already run (`production`: a valid audience-bound token or `401`
  with the metadata a client needs to find that server; every refusal and every call is
  receipted with the caller's issuer, subject and scope, and the token itself never reaches a
  tool, a message or a receipt) or, for your own clients on your own machine, a small
  authorization server of its own (`personal`: a consent page in your browser, short-lived
  tokens that no production deployment accepts). A token's scope says what it may ask for;
  the permission gate still decides whether it happens. As a client, Trinity answers a
  protected server's `401` with "authorize" on the `/mcp` page and keeps the token it obtains.
  Trinity issues no production authority: the personal issuer refuses to start under an
  external authority adapter, by construction (`docs/07-security-model.md`).
- **Reachable from elsewhere.** A gateway is a channel Trinity answers from: the adapter carries
  text, and everything else (the session, the gate, the receipts) is the same machinery the
  desktop uses. A sender Trinity does not know gets a pairing code shown on the `/gateways` page
  and nothing else, no session and no model; once paired they get slash commands, the answer
  streaming back as the turn runs, and any approval the turn raises rendered into the same
  conversation. What a channel may approve is capped below what the desktop may: a `write` at
  most by default, so an `exec` or a `destructive` request is decided at the machine, and the
  refusal is receipted. The console adapter ships (`mix trinity.console`); the platforms are next.
- **Runs on a schedule.** Tasks on the `/tasks` page: a prompt, a persona, the skills to hint,
  and when (a cron expression, a one-shot time, or a phrase like "every weekday at 9am" the
  model turns into cron). Each run is a fresh conversation you can open, its result waits on
  the page until you have read it, and the work is a durable job (Oban on the app's own
  database) that survives a restart and retries a failed turn. The memory observer and a
  curator that marks old memories stale and archives the untouched ones (never deleting)
  run on the same queues; `/oban` shows the jobs.

Not there yet: the messaging platforms themselves and subagents (M5b),
the native desktop shell and signed releases (M6), executable skills in a sandbox (M7). The [Milestones](#milestones) section below sets out the order the
remaining work is being built in.

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
the learn form, `/gateways` the channels you can reach Trinity from, `/mcp` the MCP servers you connect to (their health and the tools they
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

**Transport and message authentication.** Outbound connections use Erlang/OTP's TLS, whose default
client versions on the pinned toolchain are TLS 1.3 and TLS 1.2: **1.2 is the floor**, and Trinity
does not lower it (TLS 1.1 and 1.0 are available in the runtime but are not in the default set). The
only message authentication code Trinity itself mints is the **AES-256-GCM** tag over the state
envelope a held tool call carries between round trips, which is an approved algorithm in **FIPS**
mode. Both statements are pinned by a test against the runtime and the source rather than against
the sentence, so the line cannot outlive the fact.

## How the work is organised

Trinity is built in reviewed increments. Each one is small enough to review in one sitting and
large enough to deserve a tag, and each is merged through a pull request with the quality gate
green, then tagged. `CHANGELOG.md` records what every tag delivered and how it was verified.

**Evidence, not assertion.** A claim that something works is not accepted in place of the command
that was run and the output it produced. Anything described as verified names its command and its
exit code; any statement of the form "every X" names the command that enumerates X; and no count,
hash, date or version is written from memory. Records are appended to and never rewritten: a wrong
line stays where it is and is corrected below it, saying what it supersedes. A test for a claimed
property is committed failing first, so that the fix is shown to be the thing that made it pass.

**The gate.** `mix gate` is the same command locally and in CI. It runs formatting, a compile with
warnings as errors, the architectural boundary check, a release build check, Credo (strict),
Sobelow, dependency and licence audits, the full test suite, and a coverage floor that fails on a
drop. Continuous integration runs it on SQLite and PostgreSQL, and again inside a FIPS-mode
container. `docs/03-conventions.md` carries the engineering rules, the proof standard and the
rules of evidence every change is held to.

## Assurance posture

For readers evaluating this project for adoption, the properties below are enforced by the build
rather than described by it.

| Property | How it is enforced |
|---|---|
| Memory safety | The application is Elixir on the BEAM; the desktop shell is Rust. Both are memory-safe by construction, so the classes of defect named in current national guidance on memory safety do not arise in the application tree. |
| Architectural integrity | Module dependency rules are compiled: a violation of the layering in `docs/01-architecture.md` fails the build, so the architecture is a property of the tree rather than a diagram. |
| Least privilege for effects | Every tool call is decided by a permission gate before it runs, and side effects pass one membrane. Identity is separated from authority: a credential establishes who is calling; the gate and the selected authority adapter decide whether an effect may happen. |
| Auditability | Decisions and effects are recorded in an Ed25519-signed hash chain with checkpoints and a verifier, so an operator can reconstruct what was done, by whom and under what decision. |
| Untrusted content | Anything arriving from outside the machine is marked untrusted at the boundary and is never treated as instruction. |
| Approved cryptography | A dedicated CI leg builds from source and runs the cryptographic properties inside a FIPS-mode container, so statements about approved algorithms are measured on that leg rather than asserted. |
| Supply chain | Dependency and licence audits run on every commit; dependency versions are pinned in `VERSIONS.md` and verified against the lock file by the gate. A CycloneDX bill of materials is generated by the gate on every commit and ships beside every packaged binary, so whoever holds the artifact holds the list of what is in it; the bill states its own coverage inside the document, including what it does not cover. |
| Provenance | Every commit carries a Developer Certificate of Origin sign-off, enforced by a hook and independently by CI. Every packaged binary carries build provenance attested through the workflow's own identity and recorded in a public transparency log, verified in the same run that produced it, so a holder can check where the bytes were built without trusting this page. |
| Independent self-certification | The project holds the [OpenSSF Best Practices **silver** badge](https://www.bestpractices.dev/projects/14772) (awarded 2026-09-23), assessed against the Open Source Security Foundation's published criteria at two tiers. Every required criterion at both is met. What is not met is stated rather than stretched: at passing, three suggested criteria (semantic versioning, which begins at the first supported release, and two concerning dynamic analysis tooling the project does not run); at silver, a bus factor of two and an accessibility assessment, both suggested-tier, and signed version tags. |
| Argued, not asserted | `docs/10-assurance-case.md` decomposes the top-level security claim into ten claims, each with its argument, the evidence a reader can check, and the limit on what it covers; the assumptions the case rests on are named rather than implied. |
| Claim discipline | `docs/09-standards-register.md` records one row per control a regulated deployment might ask about, each with an evidence path and a status. No public claim about a regulation or requirement is made without a row there saying it is true. |

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

M0 to M5a are approved as of 2026-09-22, and 070 of M5b on 2026-09-23. Slice numbers have gaps on purpose (000, 001, 010, 011 and so on) so that a slice can be inserted
later without renumbering anything.

**[`ROADMAP.md`](ROADMAP.md)** sets out what the project intends to do and what it intends not to
do over the next year, and why the order is what it is.

## What is in the repository

| Path | Purpose |
|---|---|
| `CHANGELOG.md` | What each tag delivered and how it was verified |
| `VERSIONS.md` | The verified dependency versions, generated from `lib/trinity/versions.ex` |
| `docs/` | Vision, architecture, tech stack, conventions, data model, risks, security model, standards register; packaging, the FIPS leg, backup and restore, performance measurements |
| `docs/mcp-server.md` | Connecting a client to Trinity's MCP server (Claude Code, VS Code, Codex, goose), stdio, approvals over the wire, the headless profile |
| `docs/adr/` | Architecture decision records. One is added whenever a decision changes |
| `docs/10-assurance-case.md` | The structured argument that the security claims hold, with the evidence for each and the assumptions and limits named |
| `docs/09-standards-register.md` | One row per control a regulated deployment may ask about, with its evidence path and status |
| `lib/`, `test/`, `config/` | The application |
| `src-tauri/` | The native desktop shell |
| `scripts/`, `credo_checks/` | The release check, the benchmark scripts and this project's own Credo checks |
| `ci/fips/` | The container the FIPS leg builds its toolchain in |
| `coverage.tsv` | Test coverage per increment, appended at each close |

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
question answered as an approval), the approval loop and authorization above it (slice 062: the
resource server, the client role and the personal profile's authorization server, all above the
core). The client side and the authorization roles are Trinity's own work. `docs/adr/0007-mcp-2026-07-28-target-and-library.md`
records the protocol target and the layering.

## License

Apache-2.0. See `LICENSE` and `NOTICE`.
