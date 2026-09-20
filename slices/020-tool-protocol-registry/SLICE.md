# Slice 020: Tool protocol + registry

| Field | Value |
|---|---|
| Phase | 2 Tools |
| Milestone | M2 Acts |
| Size | M |
| Depends on | 012 |

## Goal
The `Trinity.Tools.Tool` behaviour, a registry that discovers tools from config (and later from MCP and skills),
JSON-schema generation for the LLM, and the real `Trinity.Sessions.ToolRunner` that executes tool calls in
supervised Tasks with timeouts, parallelism, and structured results. No side-effecting tools yet: one `echo`
tool and one deliberately crashing tool for tests.

## Why
Modularity promise: "adding a tool is adding a module". Everything in phases 2, 6, 8 plugs in here.

## Scope
**In:**
- Behaviour: `name/0`, `description/0`, `schema/0` (JSON schema map; validated with NimbleOptions-style helper), `risk/0`, `execute/2` (`(args, %Trinity.Tools.Context{session_id, cwd, persona, caller})` → `{:ok, %Result{}} | {:error, term}`), optional `timeout/0`, `format_result/1`.
- `%Trinity.Tools.Result{content: text | map, artifacts: [], truncated?: bool, meta: map}` with size capping (config, default 64 KB) and a truncation marker.
- Registry: `Trinity.Tools.Registry` (GenServer + ETS) loading `config :trinity, :tools`; `register/1`, `unregister/1` for dynamic (MCP) tools; `list/1` filtered by persona toolsets; `to_llm_tools/1`.
- Toolsets: config groups (`:core`, `:web`, `:shell`…) that personas/sessions enable.
- ToolRunner: executes N tool calls from one assistant turn concurrently via `Task.Supervisor.async_stream_nolink` with per-tool timeout; each result becomes a `tool` message; crash → error result, session continues.
- Argument validation against `schema/0` before execute; invalid → error result the model can read.
- Permission hook point: `Trinity.Permissions.decide/3` called before execute: stub returns `:allow` (real in 021).
- Test tools in `test/support/tools/`: `Echo`, `Sleep`, `Crash`, `Big` (returns > cap).
**Out:**
- Real tools (022), approvals (021), MCP (060).

## Design notes
- Tool modules are pure and stateless; stateful runtimes (browser, shell) live under `Trinity.Tools.Supervisor` and are looked up by tools.
- Results are stored as `parts: %{tool_result: ...}` on the `tool` message; large results can be saved as artifacts under the data dir with a reference.

## Deliverables
- `lib/trinity/tools/{tool,result,context,registry,runner,schema}.ex`, `lib/trinity/tools.ex`, session ToolRunner swap, tests, docs.

## Acceptance criteria
1. [auto] Adding a tool module in `test/support` + one config line makes it appear in `Trinity.Tools.list/0` and in `to_llm_tools/0` with a valid JSON schema: with zero changes to core modules (diff shown).
2. [auto] FakeProvider emits two tool calls in one turn → both execute concurrently (Sleep 300 ms each; total < 500 ms) → two `tool` messages → final assistant message.
3. [auto] `Crash` tool → error result recorded; session continues; supervisor restart count unchanged.
4. [auto] `Sleep` beyond timeout → timeout error result within timeout + 100 ms.
5. [auto] `Big` result is truncated to the cap with a marker; original size in `meta`.
6. [auto] Invalid args (schema mismatch) → error result without calling `execute/2` (test with Mox on a tool).
7. [auto] `Trinity.Permissions.decide/3` is invoked exactly once per tool call (Mox expectation).
8. [auto] **A census test derives the effect catalog from the tree and asserts no `:catalog` tool is registered by any path other than the module attribute. Plant a second path; the census must flag it.**
9. [auto] Registering a dynamic tool named exactly like a core tool does not give it the core tool's tier (test).

## Proof required
- Diff for AC1, test outputs with timings.

## Manual verification queue
None. Every acceptance criterion in this slice is `[auto]` and is proven by a command or a test.
If that changes during the slice, the criterion is retagged and this section is filled at G1.

## Definition of Done
- [ ] gate green · [ ] AC1–9 proven · [ ] ROADMAP → done · [ ] commit + tag

## Commit & tag
`feat(s020): complete slice 020 (tool protocol and registry)` · tag `slice/020`

## Risks / open questions
- Provider-specific tool-call quirks (parallel tool calls support): capability flag from 011 `capabilities/1`.

## Platform alignment (appended 2026-09-05)
- **Effect classification is part of the behaviour:** `effect/0 :: :none | :artifact | :catalog`. `:none` = read
  (emits a query receipt: redacted params, result digest, as-of); `:artifact` = local writes (files, skills,
  memory); `:catalog` = external effects (send, spend, provider mutations).
- **Compile-time effect catalog (M4):** `Trinity.Effects.Catalog` is a module attribute resolved at compile time
  listing every `:catalog`-effect tool by name with its risk tier. Runtime-registered tools (MCP, skills) may be
  `:none` or `:artifact` only; a runtime registration claiming `:catalog` is refused and receipted. Unregistered
  names are denied and receipted; malformed args are denied, never repaired.
- **Risk tier is a function of the tool name only** (`Trinity.Permissions.tier/1`), unmapped → `:ask`. The
  namespace is closed to make that safe: dynamic tools are namespaced before the lookup (`mcp:<server>:<tool>`,
  `skill:<name>`) and core names are reserved. AC9 in the list above is the test for it.
- **Declared versus observed surface:** each turn records the declared tool surface (names + definition
  digests) and each run records observed calls; `Trinity.Tools.surface_diff/1` is a query, and a non-empty diff is
  a finding surfaced in the UI.
- **Tool-definition hash:** every tool call record carries `tool_definition_digest`.
- ADR-0009 (decision appended 2026-09-20): no Jido. `Trinity.Tools.Tool` is Trinity's own behaviour: a name, a JSON
  Schema for its parameters validated with `jsv` (already in the tree through req_llm), `execute/2`, and the effect
  and risk declarations; the rules above are unchanged.
- The census is AC8 in the list above.
