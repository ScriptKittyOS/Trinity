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

### messages (Slice 010)
| column | type | notes |
|---|---|---|
| session_id | fk | index |
| seq | integer | monotonic per session; unique (session_id, seq) |
| role | string | "system" \| "user" \| "assistant" \| "tool" |
| content | text | plain text or JSON for tool payloads |
| parts | map | structured content parts (text, tool_call, tool_result, image ref). Every part carries `origin`, `source_ref`, `digest` and `taint ∈ {trusted, untrusted, blocked}`; summaries inherit the maximum taint of their inputs (Slice 022) |
| tool_call_id | string, nullable | |
| usage | map, nullable | prompt/completion tokens, cost |
| provider_meta | map | model, finish reason, latency |
Append-only. Editing is a new message with `parts.supersedes`. One edit is allowed and named (slice 012): an
assistant row written as a draft during a turn (`parts.draft = true`, content updated every 500 ms or 2 KB) becomes
final at the end of the turn (`draft = false`, plus `tool_calls`, `usage`, and `interrupted`, `error` or `cap` when the
turn ended that way); the role, seq and session never change.

### messages_fts (Slice 031): SQLite `fts5(content, session_id UNINDEXED, message_id UNINDEXED)`; on Postgres a
`tsvector` generated column on `messages`.

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

### tool_permissions (Slice 021)
| column | type | notes |
|---|---|---|
| tool | string | |
| pattern | string | glob/regex on args (e.g. shell command prefix, path) |
| decision | string | "allow" \| "deny" \| "ask" |
| scope | string | "global" \| "session:<id>" \| "persona:<id>" |
| expires_at | nullable | "allow for this session" |

### approvals (Slice 021)
Pending/decided approval requests: `session_id`, `tool`, `args`, `risk`, `status`, `decided_at`, `channel`.

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
| key_id | string | inside the signed bytes; resolves in `priv/keys/registry.json`, whose row names the algorithm; the verifier reads the algorithm from there and nowhere else |
| kind | string | "decision" \| "effect" \| "query" \| "boot" \| "cap" |
| subject | map | refs to the session, tool call, approval or effect this receipts |
Append-only. Never updated, never deleted. Signing unavailable means the effect is denied, not that an unsigned
row is written. The signed bytes carry a scheme string naming the family (`receipt_v2_ed25519`, `receipt_v2_p384`,
`receipt_v2_mldsa87`); a chain never mixes families. Effect, decision, boot and cap receipts are signed one by one;
query receipts are hash-chained and checkpointed (the tail is signed every N rows, every T seconds, and on shutdown).

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
