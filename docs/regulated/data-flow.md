<!-- SPDX-FileCopyrightText: Sudo Apt Holdings LLC -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
# Data flow: what may enter a prompt, and what must not leave

The model endpoint is outside the accredited boundary (`authorization-boundary.md`). Everything in a
prompt has therefore left your boundary by the time the model sees it. This page says what Trinity
puts in a prompt, what it will not put there, and which of those is enforced in code rather than by
policy.

## What enters a prompt

Assembled by `Trinity.Sessions.Prompt.build/5`, `lib/trinity/sessions/prompt.ex:45`.

| Tier | What it is | Path |
|---|---|---|
| Persona | The always-on instructions for the session's persona | `lib/trinity/personas.ex` |
| Always-on memory | Memory entries in the session, persona and global scopes | `lib/trinity/memory.ex` |
| Project context | `AGENTS.md` from the project root, when one is set | `lib/trinity/context.ex` |
| Conversation | The recent turns of this session | `lib/trinity/sessions/store.ex` |
| Tool definitions | Name, description and JSON schema of each available tool | `lib/trinity/tools/registry.ex` |
| Retrieved memory | Entries recalled for this turn | `lib/trinity/memory.ex` |

Each tier has a token budget and is truncated rather than dropped silently; a truncation is itself
recorded as a query receipt. The budgets are `config :trinity, :prompt_budgets`.

**Everything in that table is customer data by default.** A file read by a tool, a memory entry, a
line of `AGENTS.md` and the text of a conversation all go to the model. If any of it is CUI or PHI,
then CUI or PHI is leaving your boundary on every turn that includes it.

## What never enters a prompt

**Token material does not reach model context.** An inbound MCP request is validated and reduced to
a principal before anything downstream sees it, and the principal is defined not to carry the token.
`lib/trinity/mcp/auth/principal.ex:7`:

> Who a validated request is from (slice 062): the issuer, the subject, the scopes, the client, the
> token's id when it has one, and the profile that admitted it. What the server puts in the context
> and the receipts carry; never the token.

The same rule holds on the way out: a refusal reason is "a word or two, never a token"
(`lib/trinity/mcp/auth_host.ex:168`), and `Trinity.MCP.Auth.authorize/2` returns "the principal, or
why not (never the token)" (`lib/trinity/mcp/auth.ex:45`).

The receipt signing key never enters a prompt either. It is read only by the custody module,
`lib/trinity/receipts/key_custody.ex`, which no prompt tier touches.

**A last line, not the control.** `lib/trinity/telemetry/redaction.ex` masks credential-shaped
strings on their way into a log. It is a Logger filter, it does not sit between the session and the
model, and its own moduledoc says it is not the control. Do not rely on it to keep a secret out of a
prompt.

## CUI and PHI

**This is the part that is policy, not code.**

The requirement: CUI or PHI must not leave the boundary except to a model the lab has approved for
that category of data, under a contract that permits it.

The enforcement: **NOT IN TREE.** There is no allow-list of approved models in this repository, and
nothing refuses a call to an unapproved endpoint at runtime. The model in force is configuration
(`config/llm.exs:14`, and `TRINITY_MODEL` at runtime). Trinity will call whatever it is pointed at.

What this means for an accreditation:

1. **Model selection is a configuration-controlled item.** Treat a change to the model endpoint as a
   change to the boundary, because it is one.
2. **Egress restriction is yours.** A security group, an egress proxy or a firewall rule is what
   actually stops a prompt reaching an unapproved endpoint. See `customer-responsibility-matrix.md`.
3. **If no approved model exists for the category, the data must not enter a session at all.** Once
   it is in the conversation it is in the prompt on the next turn, because the conversation tier is
   sent verbatim.

## What leaves for an embedding service

Semantic memory needs an embedding model. Two configurations send text off the Trinity process to
get one: `:hosted` (a provider's embedding endpoint) and `:ollama` (an Ollama the operator runs,
`docs/tier3-embedder.md`). In both, **the text of every memory the observer writes and of every
query a turn recalls with leaves in the clear**, the latter prefixed by the configured query
template. Nothing is hashed or redacted on the way.

| What crosses | Raw or hashed | To | Path |
|---|---|---|---|
| Memory text and query text | Raw | The configured embedding endpoint | `lib/trinity/memory/embedders/hosted.ex`, `lib/trinity/memory/embedders/ollama.ex` |
| The model name, `num_ctx`, `truncate: false` | Raw | The same endpoint, `:ollama` only | `lib/trinity/memory/embedders/ollama.ex` |
| The model's weights, at import only (`mix trinity.tier3.import`) | Raw | The operator's own service | `lib/trinity/memory/tier3/import.ex` |
| No text: the pin check is two reads, `GET /api/tags` and `GET /api/version` | Not applicable | The same endpoint, `:ollama` only | `lib/trinity/memory/embedders/ollama/watch.ex` |

What constrains it: the endpoint's locality is declared by the operator (`:within_boundary` or
`:external`), never inferred from the address; `:external` needs `external_opt_in: true`; and under
`TRINITY_PROFILE=regulated` the endpoint must be on `TRINITY_REGULATED_LLM_ENDPOINTS` or the node does
not boot (`lib/trinity/memory/embedder_config.ex`). Whether CUI or PHI may go to that endpoint is the
same policy question as for the model endpoint above. An embedding service the operator runs inside
the boundary may still reach out on its own: see the operating notes in `docs/tier3-embedder.md`.

## Where the data rests

| Store | Contents | Encrypted by Trinity? | Path |
|---|---|---|---|
| Primary database | Sessions, messages, memory, approvals | **No.** Left to the volume, by design | `docs/encryption-at-rest.md` |
| Receipts database | The signed chain, separate file and pool | **No.** Left to the volume | `lib/trinity/repo/receipts.ex` |
| Skill files, staged changes, archives | Blobs nothing indexes | **Yes.** AES-256-GCM, fresh data key each | `docs/encryption-at-rest.md` |
| Keys directory | Signing key, device id | Mode 0600 in a 0700 directory | `lib/trinity/paths.ex` |

The split is deliberate and the reasoning is in `docs/encryption-at-rest.md`: anything SQLite indexes
is left to the volume beneath it, because encrypting it in code would defeat the index.
