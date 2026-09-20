# Slice 020: NOTES

## G1 plan, 2026-09-20

Tree at `4f7e73e` on `main` (013 approved, M1 Talks reached); branch `slice/020-tool-protocol-registry`; ROADMAP
row 020 set to `in_progress` in this commit. ADR-0009 applies: `Trinity.Tools.Tool` is Trinity's own behaviour
and `jsv` (0.23.0, already locked through req_llm; it becomes a direct dependency with a VERSIONS row, since a
module of ours calls it) validates the schemas. Each line names its test; the order is the build order.

1. `Trinity.Tools.Tool` behaviour: `name/0`, `description/0`, `schema/0` (a JSON Schema map), `risk/0`
   (`:read | :write | :exec | :network | :destructive`), `effect/0` (`:none | :artifact | :catalog`),
   `execute/2` taking the args and a `%Trinity.Tools.Context{session_id, cwd, persona, caller}`, optional
   `timeout/0` and `format_result/1`. `%Trinity.Tools.Result{content, artifacts, truncated?, meta}` with
   `cap/2`: content over `config :trinity, :tools, result_cap_bytes` (default 65,536) is cut at the cap with a
   marker and `meta.original_bytes`. Test: a result over the cap (AC5's unit half).
2. `Trinity.Tools.Schema.validate/2` with jsv: `{:ok, args}` or `{:error, reasons}` the model can read; nothing
   is filled in or coerced (docs/07: malformed arguments are denied, never repaired). Test: a missing required
   key and a wrong type are refused by name; a valid call passes untouched.
3. `Trinity.Tools.Registry` (GenServer over an ETS table, in `Trinity.Tools.Supervisor` with a
   `Task.Supervisor`): loads `config :trinity, :tools` (`modules:` and `toolsets:` as `%{core: [names]}`),
   `register/1` for dynamic tools (the name must be namespaced `mcp:<server>:<tool>` or `skill:<name>`, a core
   name is reserved, and `effect/0` may be `:none` or `:artifact` only: a `:catalog` claim is refused with
   `{:error, :catalog_is_compile_time}`), `unregister/1`, `list/1` (by toolset), `lookup/1`,
   `to_llm_tools/1` (the request's tool shape), `definition_digest/1` (SHA-256 over name, description and
   schema). Tests: AC1 (a module in test/support plus one config line appears in `list/0` and `to_llm_tools/0`
   with a valid schema; `git diff --stat` of `lib/` is empty), AC9 (a dynamic tool named `echo` is refused, and
   `mcp:x:echo` gets `:ask`, not echo's tier).
4. `Trinity.Permissions` (stub, 021 makes it real): `tier/1` from the name alone (a core registry name gives
   its declared risk; anything else is `:ask`), the `Trinity.Permissions.Policy` behaviour with `decide/3`,
   the default policy returning `:allow`, the implementation from config so a Mox mock can stand in. Test:
   AC7 (decide/3 called exactly once per call).
5. `Trinity.Effects.Catalog`: a module attribute listing every `:catalog` tool by name with its tier (empty at
   this slice), `names/0`, and the census (AC8): a test walks every module in the tree implementing
   `Trinity.Tools.Tool`, asserts each `:catalog` one is in the attribute and that no registration path other
   than the attribute admits one; a planted second path (a runtime `register/1` of a test tool claiming
   `:catalog`, and a config line naming one) is flagged by name.
6. `Trinity.Tools.Runner`, the real `Trinity.Sessions.ToolRunner`: `run_all/2` runs the turn's calls through
   `Task.Supervisor.async_stream_nolink` under `Trinity.Tools.TaskSupervisor`, all at once, each with its
   tool's timeout (default 30 s, config); per call: lookup, validate, `Permissions.decide/3`, `execute/2`, cap;
   a crash is `{:error, {:crash, reason}}` and a timeout `{:error, :timeout}`; the Session's `start_tools` calls
   `run_all/2` (one line in 012's module, the same shape as before) and each `tool` row carries
   `parts.tool_result` (content, meta, truncated) and `parts.tool_definition_digest`. Tests: AC2 (two Sleep 300
   ms calls, total under 500 ms, two tool rows, a final message), AC3 (Crash: an error row, the session goes
   on, the Sessions supervisor's pid and child unchanged), AC4 (Sleep past its timeout: the error within
   timeout + 100 ms), AC5 through the Session (Big truncated in the row), AC6 (a Mox tool whose `execute/2` is
   never called on a schema mismatch).
7. The declared surface: `Prompt.build/3` takes the session's tools (names, descriptions, schemas) into the
   request, and the assistant row's `provider_meta.tool_surface` carries names and digests;
   `Trinity.Tools.surface_diff/1` lists calls whose name or digest was not declared on their turn. Test: a call
   to an undeclared name is a finding; an ordinary turn is not.
8. Test tools in `test/support/tools/`: `Echo`, `Sleep`, `Crash`, `Big`, plus `CatalogClaimer` for the census
   plant; `config :trinity, :tools` in config/test.exs; the fake provider's default script already ends in a
   tool call (`get_weather`, undeclared: it becomes the surface_diff fixture).
9. docs/01 (Tools context and tree as built), docs/03 (adding a tool: a module and a config line), docs/05
   (the tool row's parts), VERSIONS (`jsv` row).
10. Gate, coverage row, PROOF.md, ROADMAP to `done`, pull request (merged with a signed body, docs/03), tag.

Manual verification queue: none. Every criterion is `[auto]`.

Deviations from SLICE.md, stated before building: the runner exposes `run_all/2` beside `run/2`, because the
concurrency AC2 asks for is a property of the turn, not of one call, and the Session runs the turn; `format_result/1`
is optional and defaults to the content as text; artifacts under the data directory (the design note) are
declared on the struct but written by no tool at this slice (022's filesystem tools are the first with a reason
to). `Trinity.Permissions.tier/1` reads the core registry's declared risk rather than a hand map, so a core tool
added by config carries its own tier and a dynamic name never does.
