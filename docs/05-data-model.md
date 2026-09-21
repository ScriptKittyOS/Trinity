# 05: Data model

All tables have `id` (UUIDv7 as binary_id, sortable, minted by `Trinity.UUID` since slice 010), `inserted_at`, `updated_at` (utc_datetime_usec).
SQLite is primary; every migration must also run on Postgres in the CI matrix. Use Ecto types that map on both
(`:binary_id`, `:map` → JSON text on SQLite, `:utc_datetime_usec`). Vector columns and FTS tables are created
with adapter-specific `execute/1` guarded by `repo().__adapter__()`.

## Entities

### personas (Slice 030)
| column | type | notes |
|---|---|---|
| name | string, unique | e.g. "default" |
| soul | text | SOUL.md body (identity, tone, boundaries) |
| model | string | default model id ("anthropic:claude-…", "openrouter:…") |
| settings | map | temperature, tool policy overrides |

### sessions (Slice 010)
| column | type | notes |
|---|---|---|
| title | string | auto-generated after first turn |
| persona_id | fk personas | |
| parent_id | fk sessions, nullable | lineage across compactions (Slice 023) |
| origin | string | "desktop" \| "telegram" \| "discord" \| "console" \| "cron" \| "subagent" \| "mcp" \| "a2a" |
| origin_ref | map | platform ids (chat_id, channel_id) |
| status | string | "active" \| "archived" \| "compacted" |
| model | string | current model (may differ from persona default) |
| token_usage | map | running totals |
| last_activity_at | utc_datetime_usec | |
Slice 033 adds `project_root` (string, nullable): the directory the session's tools work in (the filesystem allowlist's `cwd`) and its `AGENTS.md` is read from; set from the chat's bar or `Trinity.Sessions.set_project_root/2`.

### messages (Slice 010)
| column | type | notes |
|---|---|---|
| session_id | fk | index |
| seq | integer | monotonic per session; unique (session_id, seq) |
| role | string | "system" \| "user" \| "assistant" \| "tool" |
| content | text | plain text or JSON for tool payloads |
| parts | map | structured content parts (text, tool_call, tool_result, image ref). Every part carries `origin`, `source_ref`, `digest` and `taint ∈ {trusted, untrusted, blocked}`; summaries inherit the maximum taint of their inputs (Slice 022) |
| tool_call_id | string, nullable | the assistant row's call id a `tool` row answers (Slice 012); its `parts` carry `tool`, `ok`, `tool_result` (`content`, `truncated`, `meta`, `artifacts`, or `error`) and `tool_definition_digest`, and the assistant row's `provider_meta.tool_surface` maps every declared tool name to its digest (Slice 020) |
| (compaction rows, Slice 023) | | a `system` row whose `parts.compaction` carries `from_seq`, `to_seq`, `rows`, `digests` (of the summarised rows' content parts), `summary`, `open_threads`, `decisions`, `facts` and `previous` (the earlier compaction's id); `parts.taint` the maximum of the inputs'. Nothing it covers is edited or deleted: the prompt builder renders the newest compaction into the system prompt and drops the rows it covers from the list. A fork (past the hard threshold) is a child session with `parent_id` whose first row is the compaction and whose second is the user's message; the parent's last row carries `parts.forked_to` |
| usage | map, nullable | prompt/completion tokens, cost |
| provider_meta | map | model, finish reason, latency |
Append-only. Editing is a new message with `parts.supersedes`. One edit is allowed and named (slice 012): an
assistant row written as a draft during a turn (`parts.draft = true`, content updated every 500 ms or 2 KB) becomes
final at the end of the turn (`draft = false`, plus `tool_calls`, `usage`, and `interrupted`, `error` or `cap` when the
turn ended that way); the role, seq and session never change.

### messages_fts (Slice 031): SQLite `fts5(content, session_id UNINDEXED, message_id UNINDEXED)`; on Postgres a
`tsvector` generated column on `messages`.

As built: SQLite `messages_fts` with `tokenize = 'porter unicode61'`, `rowid` equal to the message row's, kept
by three triggers (`messages_fts_ai`, `_ad`, `_au` on `content`) and backfilled by the migration; rebuildable by
`mix trinity.search.reindex`. Postgres: `messages.content_tsv` generated as `to_tsvector('english', content)` with
the GIN index `messages_content_tsv_idx`; nothing to rebuild. Stemming is suffix-based on both: "running" meets
"runs" at `run` and never "ran". `Trinity.Memory.Search.messages/2` binds the query as a parameter and quotes
every term for FTS5, so operators are text.

### memories (Slice 030/032)
| column | type | notes |
|---|---|---|
| tier | string | "profile" (USER.md-like) \| "always_on" (MEMORY.md-like) \| "semantic" (retrievable) |
| scope | string | "global" \| "persona:<id>" \| "project:<path>" |
| key | string, nullable | for always_on/profile: short stable key, unique within (tier, scope) |
| body | text | |
| embedding | vector(384), nullable | semantic tier only; sqlite_vec virtual table `memories_vec` on SQLite |
| source_message_id | fk, nullable | provenance |
| confidence | float | agent-assigned |
| last_used_at | utc_datetime_usec | for decay/pruning |
Invariant: total bytes of `always_on` + `profile` for a persona ≤ configurable budget (default 8 KB), enforced by
`Trinity.Memory.Budget`, which triggers consolidation instead of silent truncation.

As built at slice 030: `memories` carries `persona_id` (the budget's unit) beside the columns above, the scope
vocabulary is `global | persona:<id> | project:<path> | session:<id>` (a session reads the chain `session`,
`persona`, `global`), `key` is required for the two always-on tiers (`^[a-z0-9][a-z0-9_.-]{0,63}$`, unique with
tier and scope), and the semantic tier's columns wait for 032. Two tables beside it:

As built at slice 032 (the semantic tier): no `memories_vec` virtual table and no `sqlite_vec` (its only release
needs `nx ~> 0.9`; NOTES decision 1). The vector is three columns on the row, on both databases:
`embedding` (binary: float32, little-endian, `dim * 4` bytes), `embedding_model` (the embedder that produced it,
e.g. `bumblebee:sentence-transformers/all-MiniLM-L6-v2`, `fake:sha256-384` in the suite) and `embedding_dim`
(integer), all nullable, under an index on (`persona_id`, `tier`, `embedding_model`). On Postgres the migration
also creates the `vector` extension, a fourth column `embedding_vector vector(384)` and an HNSW cosine index on
it where `tier = 'semantic'`; `Trinity.Memory.VectorStores.Pgvector` keeps it in step with the bytes column and
searches it with `<=>`, and `VectorStores.Brute` (SQLite) loads the filter's rows and scores them in Elixir.
A search takes the scope list as a required argument (M6) and runs only over rows whose `embedding_model` is the
embedder in force's: models are never mixed, a change of embedder is a re-embed. Semantic rows are written by
`Trinity.Memory.Semantic.add/2` (the observer after a turn, `by: "observer"`; the page, `by: "ui"`), keyed
`<slug of the body>-<6 hex of its SHA-256>`, and every write is a `memory_changes` row (`add`, `remove`, `pin`).
The change log's `action` vocabulary grows by `pin` (a semantic memory promoted to `always_on` through
`AlwaysOn.add/2`, so the budget applies) and `by` by `observer`. Recall marks its memory hits' `last_used_at`,
which the retriever's recency decay reads.

### memory_changes (Slice 030)
`persona_id`, `action` (add | replace | remove | promote | consolidate), `tier`, `scope`, `key`, `before`,
`after`, `by` (tool | ui | consolidator), `session_id`, `proposal_id`, `inserted_at`. Every write to the
always-on tiers appends one; a consolidation's writes carry its proposal id, so no entry leaves the tiers
without a row here.

### memory_proposals (Slice 030)
`persona_id`, `entries` (the proposed set), `bytes_before`, `bytes_after`, `budget`, `status` (applied | pending |
rejected), `decided_at`. The consolidator applies a proposal under budget at once and holds one over budget for
the owner (the memory page).

### skills (Slice 040)
| column | type | notes |
|---|---|---|
| name | string, unique within source | slug |
| version | integer | bumps on every change |
| source | string | "bundled" \| "user" \| "agent" \| "hub:<url>" \| "project" |
| path | string | on-disk dir containing SKILL.md |
| frontmatter | map | parsed YAML (description, requires_tools, triggers…) |
| body_hash | string | sha256 of SKILL.md |
| status | string | "active" \| "pending_approval" \| "rejected" \| "disabled" |
| scan_result | map | scanner findings |
| embedding | vector(384), nullable | for skill retrieval |
Filesystem is canonical for content; DB is the index (rebuildable via `mix trinity.skills.reindex`).

### skill_changes (Slice 041)
Staged proposals by the agent: `skill_id`, `diff`, `rationale`, `status`, `decided_by`, `decided_at`.

### tool_permissions (Slice 021, as built)
| column | type | notes |
|---|---|---|
| tool | string | |
| pattern | string | `*`, `key=glob` (`*` in a segment, `**` across, `?` one character; a trailing `*` is a prefix), `fp:<hex>` (a session grant bound to a fingerprint), `re:<regex>` (hand-edited rows only) |
| decision | string | "allow" \| "deny" \| "ask" |
| scope | string | "global" \| "session:<id>" \| "persona:<id>" |
| expires_at | nullable | set on "allow for this session" grants |
| decided_by | string, nullable | who wrote it ("liveview" from the card) |

### approvals (Slice 021, as built)
One row per request, the audit trail this slice owns; slice 024 reads it for decision receipts.
| column | type | notes |
|---|---|---|
| session_id | fk sessions | |
| tool, args, risk | string, map, string | the call and its tier at request time |
| fingerprint | string | `sha256(rfc8785({tool, args, scope, cwd, canonicalization_version}))`, re-derived at execution |
| status | string | "pending" \| "allowed" \| "denied" \| "expired" |
| decision | string, nullable | "once" \| "session" \| "always" \| "deny" |
| decided_at, decided_by | timestamp, string | every decided row has both ("expiry" is a decider) |
| consumed_at | nullable | a "once" allowance or a denial is spent by the execution that reads it |
| expires_at | timestamp | pending past it becomes "expired" with decision "deny" |

### tasks (Slice 050)
| column | type | notes |
|---|---|---|
| name | string | |
| schedule | string | cron expr or ISO one-shot |
| prompt | text | |
| persona_id | fk | |
| skill_names | {array, string} | |
| deliver_to | map | `{"gateway": "telegram", "ref": {...}}` or desktop |
| enabled | boolean | |
| last_run_at, next_run_at | | mirrors Oban state |
Execution history is in `oban_jobs` + a `task_runs` table (status, session_id, summary).

### usage_events (Slice 011; the ledger and budgets that read it are Slice 090)
One row per completed call, as built at slice 011:

| column | type | notes |
|---|---|---|
| model_id | string | the registry id (`"openrouter:ling"`), not the provider's model name |
| provider | string | the registry entry's provider atom as text |
| kind | string | "chat" \| "object" \| "embed" |
| input_tokens, output_tokens, cached_tokens, reasoning_tokens | integer | the names `Trinity.LLM.Event`'s usage map uses; `prompt_tokens` and `completion_tokens` in the first draft of this table are these two |
| cost_usd | float | computed from the registry's price in dollars per million tokens; the only cost Trinity reports |
| session_id | fk sessions, nullable | set when the call belongs to a session |
| provider_meta | map | `provider_cost`: the provider's own figure when it reports one, kept for comparison and never used |

Append-only; `inserted_at` only. Latency is not a column: it is a Telemetry measurement at slice 090, where the
call is timed at the one place every call passes.

### gateway_identities (Slice 070)
`adapter`, `external_user_id`, `display`, `paired_at`, `allowed`: DM pairing and allowlists.

### receipts (Slice 024)
| column | type | notes |
|---|---|---|
| seq | integer | monotonic per `chain_scope`; unique (chain_scope, seq) |
| chain_scope | string | one chain per scope; appended by a single owning process |
| prev_hash | binary | the previous receipt's `receipt_hash`; null only for the first in a scope |
| receipt_hash | binary | over the canonical signed bytes |
| signed_payload | map | RFC 8785 canonical JSON. Field set is a legal-review question before Slice 024 |
| signature | binary | through the signer seam: Ed25519 by default, ECDSA P-384 in FIPS mode, ML-DSA-87 opt-in (slice 024 amendments 1 to 6) |
| key_id | string | inside the signed bytes; resolves in the key registry (as built: `<data dir>/keys/registry.json`, not `priv/`), whose row names the algorithm; the verifier reads the algorithm from there and nowhere else |
| kind | string | "decision" \| "effect" \| "query" \| "boot" \| "cap" |
| subject | map | refs to the session, tool call, approval or effect this receipts |
Append-only. Never updated, never deleted. Signing unavailable means the effect is denied, not that an unsigned
row is written. The signed bytes carry a scheme string naming the family (`receipt_v2_ed25519`, `receipt_v2_p384`,
`receipt_v2_mldsa87`); a chain never mixes families. Effect, decision, boot and cap receipts are signed one by one;
query receipts are hash-chained and checkpointed (the tail is signed every N rows, every T seconds, and on shutdown).

As built at slice 024, in its own database (`Trinity.Repo.Receipts`, `receipts.db`, `synchronous: :full`): `id`,
`chain_scope`, `seq`, `prev_hash` (hex), `receipt_hash` (hex: SHA-256 over the DSSE PAE of
`trinity/receipt/<scheme>` and the body), `scheme`, `kind`, `signed_payload` (**text**: the RFC 8785 body, whose
keys are `scheme, seq, chain_scope, prev_hash, kind, subject, decision, fingerprint, at, key_id`), `signature`
(binary; null for query rows), `key_id`, `subject` (map), `subject_ref` (string: `effect:<session>:<call>`,
`decision:…`, `query:…`, `boot:<node>`; the idempotency lookup), `meta` (map, unsigned: `core_policy_hash`,
`canonicalization_version`, `authority`, `tool_definition_digest`), `inserted_at`. Unique `(chain_scope, seq)`
and `receipt_hash`. Chain scopes: `session:<id>` and `boot`.

### receipt_checkpoints (Slice 024)
| column | type | notes |
|---|---|---|
| chain_scope, first_seq, last_seq | string, integer, integer | the query rows this checkpoint covers; unique `(chain_scope, last_seq)` |
| boot_receipt_hash | string | which boot wrote it (RFC 5848's reboot session id, by role) |
| tail_hash | string | the `receipt_hash` at `last_seq` |
| scheme, signed_payload, signature, key_id | | signed like a receipt, over the PAE of `trinity/checkpoint/<scheme>` and the canonical body |
| reason | string | "count" \| "time" \| "shutdown" \| "rehydrate" \| "manual" |
A row, never a write onto a receipt: `receipts` stays append-only and a checkpoint states its own coverage.

### mcp_servers (Slice 060)
`name`, `transport`, `command_or_url`, `env_refs`, `enabled`, `effect_default ∈ {none, artifact}`, per-tool
effect and risk overrides. A server config claiming `:catalog` is refused at load and receipted.

### task_runs (Slice 050)
`task_id`, `scheduled_at`, `session_id`, `status`, `summary`, `error`. Unique on `(task_id, scheduled_at)` so a
run is idempotent. Oban holds the job; this holds the outcome.

## Invariants (tested)

1. `messages.seq` is gapless per session (Slice 010 property test).
2. A Session's in-memory history equals `messages` for that session after rehydrate (Slice 012).
3. Always-on memory budget never exceeded (Slice 030).
4. Skill DB index == filesystem after reindex (Slice 040).
5. No tool executes without an `approvals` or `tool_permissions` decision recorded (Slice 021).
6. A receipt chain has no gap and no fork per `chain_scope`; every `prev_hash` resolves (Slice 024).
