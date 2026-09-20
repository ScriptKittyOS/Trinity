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

## Lines 1 to 9, 2026-09-20: what was built, and what building it found

**Built.** As planned, with the corrections below. `Trinity.Tools` (the door: `list/1`, `lookup/1`,
`to_llm_tools/1`, `register/2`, `unregister/1`, `surface/1`, `surface_diff/1`), `Tools.Tool`, `Tools.Context`,
`Tools.Result`, `Tools.Schema`, `Tools.Registry`, `Tools.Runner`, `Tools.Supervisor`; `Trinity.Permissions` with
`Policy` and `Policy.Default`; `Trinity.Effects.Catalog`; the Session's `start_tools` through `run_all/2`, the
tool row's `tool_result` and `tool_definition_digest`, the declared surface on the request and the assistant row;
`Prompt.build/4`; seven test tools; two Mox mocks.

**Found while building, each recorded rather than smoothed.**

1. **`Permissions.tier/1` cannot read the registry.** The G1 deviation said it would; `boundary` refused: Tools
   depends on Permissions (the runner asks `decide/3`) and docs/01 has it that way, so Permissions reading
   `Tools.Registry` is a cycle. The tier map is a module attribute in Permissions, code-owned, empty at this
   slice (022 fills it beside its tools), and `tier/1` says `:ask` for every name today. Docs/07's wording was
   right and the deviation wrong; superseded here.
2. **`Trinity.Tools.surface_diff/1` takes the history, not a session id**, for the same reason: reading
   `Sessions.history/2` from Tools closes the cycle the other way. It is pure over a list of rows; a caller
   passes what `Sessions.history/2` returns.
3. **`Trinity.Tools.Runner` carries no `@behaviour Trinity.Sessions.ToolRunner`**: the attribute is a reference
   from Tools to Sessions. The seam keeps its callbacks; the runner implements the two functions and a test
   asserts their presence and that the seam names the runner as its default.
4. **The type checker folded an empty tier map to `:ask`** and made the warning an error ("will always return
   :ask"); the map is read through a function so it stays a map to the checker.
5. **Mox defines the optional callbacks too**, so a mocked tool exports `timeout/0` and the runner asks it;
   AC6's mock stubs it. Left as a property of the runner (a tool that exports `timeout/0` is asked), not
   worked around.
6. **A second Registry in the same VM needs its own table** for the config-path census plant; `table:` is an
   init option, the module name by default.
7. **A `:catalog` claim is checked after the name rules**, so the runtime plant (`mcp:planted:send_money`) is
   refused for the catalog and the config plant needs a core-shaped name (`send_money`,
   `CatalogClaimerCore`) to reach the same rule at the registry's start; two plants, both named by the census.
8. **A runner that raises inside the Session's tool Task is an error turn, not a tool row** (seen once while AC6's
   mock lacked its `timeout/0` stub): 012's `{:DOWN}` path took it. Correct, and now known.
9. **The fake provider's default script calls `get_weather`, which no registry has**, so every 012 tool-path
   turn is a `surface_diff` finding: the fixture for the undeclared case, and the 012 test now reads the runner's
   "no such tool" instead of the stub's `no_tools`.

```
$ mix test test/trinity/tools           → 27 passed
$ mix gate                              → exit 0; 204 passed, 10 excluded; plan_check: PASS
$ mix test --cover                      → 67.18% total (Registry 95.16%, Runner 84.21%, Tools 94.12%, Schema 76.92%)
$ mix credo --strict --all              → 753 mods/funs, found no issues
```

## Follow-ups
- 021 replaces `Policy.Default` with the layered policy and gives `:ask` its `approval_wait` path; at this slice
  an `:ask` decision is an error result (`approval_required`) the model reads.
- 022's core tools fill the tier map in `Trinity.Permissions` beside their modules; the census's "every mapped
  name is a core tool" holds then with content.
- `Tools.Result.artifacts` is declared and written by nothing; 022 decides the artifact file layout under the
  data directory.
- The fake provider's `get_weather` default script could name a registered tool once 022 has one; until then
  it is the undeclared-call fixture.
- `surface_diff/1` has no UI; 090 (activity) is the natural home for the finding.
