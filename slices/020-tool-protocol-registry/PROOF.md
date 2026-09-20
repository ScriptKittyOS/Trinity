# Proof for slice 020: Tool protocol + registry

Agent: Trinity · Coding Agent · Date: 2026-09-20 · Branch: slice/020-tool-protocol-registry · Final commit: (the commit carrying this file; named in the closing correction)

## Summary
Trinity's own tool behaviour (ADR-0009), a registry over ETS that loads core tools from config and admits
dynamic ones only under a namespaced name with no `:catalog` claim, jsv validation that refuses and never
repairs, a permissions stub whose tier is a code-owned map, the compile-time effect catalog with its census, and
a runner that executes every call of a turn at once with per-tool timeouts and turns crashes, timeouts and
unknown names into results the model reads. The Session records each answer with the tool's definition digest
and each turn's declared surface. Three of the G1 deviations were reversed by `boundary` (NOTES.md findings 1
to 3): the dependency direction is Sessions → Tools → Permissions, and nothing points back.

## Gate
```
$ mix gate                                   (this machine, OTP 28.5.0.5, Elixir 1.20.4, under a 32 GiB cgroup, tree 8a5b7ae)
753 mods/funs, found no issues.
... SCAN COMPLETE ...                        (sobelow --exit --skip: no finding)
No retired or security advisory packages found
No vulnerabilities found.
versions.verify: OK. 84 locked packages, none disagreeing with 49 pins
Result: 204 passed, 10 excluded
trinity.coverage: 013 64.41% vs 012 60.82%: OK
plan_check: PASS
exit=0
```
`mix credo --strict --all`: 753 mods/funs, found no issues.

## Tests
```
$ mix test --cover                           (tree 8a5b7ae)
Result: 204 passed, 10 excluded
|     95.16% | Trinity.Tools.Registry |
|     84.21% | Trinity.Tools.Runner   |
|     94.12% | Trinity.Tools          |
|     76.92% | Trinity.Tools.Schema   |
|    100.00% | Trinity.Tools.Result, Tool, Context, Supervisor; Trinity.Permissions (and Policy, Default); Trinity.Effects.Catalog |
|     67.18% | Total                  |
```
`coverage.tsv` row: `020  67.18  8a5b7ae  2026-09-20` (from 64.41 at 013).

The 27 tests of `test/trinity/tools`, with timings from `--trace`:
```
test AC1: a module plus one config line no core module references a test tool (the diff for AC1 is config and test/support only)  * test AC1: a module plus one config line no core module references a test tool (the diff for AC1 is config and test/support only) (6.0ms) [L#42]
test AC1: a module plus one config line the four test tools are listed, in the core toolset, with schemas that build and digests  * test AC1: a module plus one config line the four test tools are listed, in the core toolset, with schemas that build and digests (0.07ms) [L#20]
test AC1: a module plus one config line to_llm_tools/0 carries name, description and parameters for each  * test AC1: a module plus one config line to_llm_tools/0 carries name, description and parameters for each (0.00ms) [L#32]
test AC2: two calls in one turn run concurrently; two tool rows; a final assistant message  * test AC2: two calls in one turn run concurrently; two tool rows; a final assistant message (305.8ms) [L#55]
test AC3: a crashing tool is an error row; the session goes on; no supervisor restart  * test AC3: a crashing tool is an error row; the session goes on; no supervisor restart (9.5ms) [L#74]
test AC4: a tool past its timeout is a timeout row within timeout + 100 ms  * test AC4: a tool past its timeout is a timeout row within timeout + 100 ms (505.4ms) [L#108]
test AC5: a result over the cap is truncated in the row with the marker and the original size  * test AC5: a result over the cap is truncated in the row with the marker and the original size (33.1ms) [L#123]
test AC6: invalid arguments are refused before execute/2 is called  * test AC6: invalid arguments are refused before execute/2 is called (20.2ms) [L#134]
test AC7: Permissions.decide/3 is invoked exactly once per tool call  * test AC7: Permissions.decide/3 is invoked exactly once per tool call (3.6ms) [L#154]
test a denied call is an error row and execute/2 is not reached  * test a denied call is an error row and execute/2 is not reached (4.2ms) [L#166]
test dynamic tools AC9: a dynamic tool named exactly like a core tool is refused, and a namespaced one gets no tier  * test dynamic tools AC9: a dynamic tool named exactly like a core tool is refused, and a namespaced one gets no tier (0.1ms) [L#64]
test dynamic tools a core name cannot be unregistered, a module that is not a tool cannot be registered  * test dynamic tools a core name cannot be unregistered, a module that is not a tool cannot be registered (0.01ms) [L#77]
test dynamic tools a namespaced tool with no catalog claim is admitted, listed and removable  * test dynamic tools a namespaced tool with no catalog claim is admitted, listed and removable (0.09ms) [L#54]
test dynamic tools a runtime registration claiming :catalog is refused by name  * test dynamic tools a runtime registration claiming :catalog is refused by name (0.03ms) [L#72]
test every :catalog tool in the tree is in the attribute, and the attribute names only :catalog tools  * test every :catalog tool in the tree is in the attribute, and the attribute names only :catalog tools (0.08ms) [L#37]
test path 1, a runtime registration claiming :catalog, is refused and leaves no entry  * test path 1, a runtime registration claiming :catalog, is refused and leaves no entry (0.1ms) [L#54]
test path 2, a config line naming a :catalog tool absent from the attribute, refuses the registry's start  * test path 2, a config line naming a :catalog tool absent from the attribute, refuses the registry's start (0.8ms) [L#59]
test Result.cap/2 (AC5) cuts at the cap on a character boundary, marks it, keeps the original size  * test Result.cap/2 (AC5) cuts at the cap on a character boundary, marks it, keeps the original size (0.02ms) [L#12]
test Result.cap/2 (AC5) leaves a result under the cap alone and renders a map as JSON  * test Result.cap/2 (AC5) leaves a result under the cap alone and renders a map as JSON (2.2ms) [L#22]
test Schema.validate/2 (AC6's unit half) a missing required key and a wrong type are refused by name, and nothing is repaired  * test Schema.validate/2 (AC6's unit half) a missing required key and a wrong type are refused by name, and nothing is repaired (1.1ms) [L#42]
test Schema.validate/2 (AC6's unit half) a valid call passes untouched  * test Schema.validate/2 (AC6's unit half) a valid call passes untouched (4.3ms) [L#37]
test surface_diff/1 a call to an undeclared name is a finding; a declared one with the same digest is not  * test surface_diff/1 a call to an undeclared name is a finding; a declared one with the same digest is not (1.2ms) [L#71]
test surface_diff/1 a changed definition is a finding, and a turn with no surface is skipped  * test surface_diff/1 a changed definition is a finding, and a turn with no surface is skipped (0.00ms) [L#84]
test the declared surface is on the assistant row, and the fake's undeclared call is a surface_diff finding  * test the declared surface is on the assistant row, and the fake's undeclared call is a surface_diff finding (3.6ms) [L#176]
test the population is derived from the app's module list, not a hand list  * test the population is derived from the app's module list, not a hand list (31.1ms) [L#30]
test the runner implements the seam's two functions with its arities  * test the runner implements the seam's two functions with its arities (1.1ms) [L#51]
test the tier map in Permissions is code: every mapped name is a core tool, or the map is empty  * test the tier map in Permissions is code: every mapped name is a core tool, or the map is empty (0.8ms) [L#71]
```

## Acceptance criteria evidence

### AC1: a tool module in test/support plus one config line appears in list/0 and to_llm_tools/0 with a valid schema; zero core changes (diff shown)
Live, on the closing tree: a fifth tool `Trinity.TestTools.Upper` written to `test/support/tools/upper.ex` and one
line added to `config :trinity, :tools` in config/test.exs, then reverted.
```
$ git status --short
 M config/test.exs
?? test/support/tools/upper.ex
$ git diff --stat -- lib/
(empty: no core module changed)
$ MIX_ENV=test mix run -e '...'
list: ["big", "crash", "echo", "sleep", "upper"]
llm tool: %{name: "upper", description: "Upcases the text.", parameters: %{"properties" => %{"text" => %{"type" => "string"}}, "required" => ["text"], "type" => "object"}}
run: {:ok, %Trinity.Tools.Result{content: "HELLO", ...}, %{"tool" => "upper", "tool_definition_digest" => "8853edfb…"}}
```
And in the suite: `AC1: a module plus one config line` (three tests): the four test tools listed, in the core
toolset, each schema building, each digest 64 hex; `to_llm_tools/0` carries name, description and parameters;
`git grep -l TestTools -- lib/` matches nothing.

### AC2: two tool calls in one turn execute concurrently (Sleep 300 ms each, total < 500 ms), two tool rows, a final message
`AC2: two calls in one turn run concurrently; two tool rows; a final assistant message`: the fake emits two calls to
`sleep` with 300 ms each; the turn from send to idle is measured under 500 ms; history is `["user", "assistant",
"tool", "tool", "assistant"]`; each tool row has its call id, `slept 300`, `parts.ok`, `parts.tool_result.content`
and the Sleep module's definition digest; the final message is the second script's text.

### AC3: Crash tool → error result recorded; session continues; supervisor restart count unchanged
`AC3: a crashing tool is an error row; the session goes on; no supervisor restart`: one call raises, one exits,
one echoes; three tool rows, the first two `ok: false` with "crashed" in the content, the third "still here";
`Trinity.Sessions.Supervisor` and `Trinity.Tools.Supervisor` keep their pids (DynamicSupervisor exposes no
restart counter, as 012 recorded; pid identity is the measurement); the session answers the next message.

### AC4: Sleep beyond timeout → timeout error result within timeout + 100 ms
`AC4: a tool past its timeout is a timeout row within timeout + 100 ms`: Sleep's `timeout/0` is 500 ms, the call
asks for 5,000; from `tool_wait` to the next `thinking` measured at most 600 ms; the row reads
`error: the tool timed out` with `tool_result.error` the same.

### AC5: Big result truncated to the cap with a marker; original size in meta
Unit: `Result.cap/2 (AC5) cuts at the cap on a character boundary, marks it, keeps the original size` (100 two-byte
characters at a 51-byte cap: 25 characters kept, the marker appended, `original_bytes` 200, valid UTF-8). Through
the Session: `AC5: a result over the cap is truncated in the row with the marker and the original size` (Big returns
twice the cap; the row's `tool_result.truncated` is true, `meta.original_bytes` is twice the cap, the content ends
with the marker and is under the cap plus the marker).

### AC6: invalid args → error result without calling execute/2 (Mox)
`AC6: invalid arguments are refused before execute/2 is called`: a Mox tool registered as `mcp:mock:strict` with
`expect(:execute, 0, ...)`; a call with `text: 42` and an extra key; the row is `ok: false` with "invalid
arguments" naming `text`; Mox verifies on exit that `execute/2` was never called. Unit: `Schema.validate/2` refuses
a missing required key, a wrong type, an extra property and a non-object by name, and passes a valid call untouched.

### AC7: Permissions.decide/3 invoked exactly once per tool call (Mox)
`AC7: Permissions.decide/3 is invoked exactly once per tool call`: the policy in force is `PolicyMock` with
`expect(:decide, 2, ...)` matching the session id, `echo` and a `text` argument; two calls, two rows, Mox verifies
the count on exit. `a denied call is an error row and execute/2 is not reached`: a `:deny` answer is the row
`error: :denied`.

### AC8: census: the effect catalog is derived from the tree; no :catalog tool by any path but the attribute; a planted second path is flagged
`Trinity.Tools.CatalogCensusTest`, population from `:application.get_key(:trinity, :modules)` filtered by
`Tool.implemented_by?/1` (derived; the test asserts Echo and the plants are in it and a Mox mock is not). Every
`:catalog` claimer in the tree is compared with `Trinity.Effects.Catalog.names/0`: the two plants
(`mcp:planted:send_money`, `send_money`) are outside it and named; the attribute is empty at this slice and every
entry it will hold must be a `:catalog` tool. Path 1, a runtime `register/2` of the plant: refused
`{:error, :catalog_is_compile_time}`, no entry. Path 2, a config line naming the core-shaped plant: the registry's
start raises `ArgumentError` naming `catalog_tool_not_in_catalog` and `send_money`. The tier map: every mapped
name is a core tool (vacuous at this slice) and no config key names a tier.

### AC9: registering a dynamic tool named exactly like a core tool does not give it the core tool's tier
`AC9: a dynamic tool named exactly like a core tool is refused, and a namespaced one gets no tier`: `Impostor`
(name `echo`) is refused `{:name_not_namespaced, "echo"}` and `echo` still resolves to `Echo`; `DynamicEcho`
(`mcp:fake:echo`) is admitted and `Permissions.tier/1` answers `:ask` for it. At this slice the map is empty and
`echo` itself is `:ask`, asserted so the test says what the map holds.

### Platform alignment: the declared surface and the definition digest
`the declared surface is on the assistant row, and the fake's undeclared call is a surface_diff finding`: the
assistant row's `provider_meta.tool_surface` equals `Tools.surface/0` (the four names with digests);
`surface_diff/1` over the history names `get_weather` at seq 2 as `:undeclared`. Unit: a changed definition is
`:definition_changed`; a turn with no surface is skipped. Every tool row carries `tool_definition_digest` (AC2).

## Manual verification for the reviewer
None. Every criterion is `[auto]`.

## Deviations from SLICE.md
See NOTES.md: `run_all/2` beside `run/2`; `format_result/1` optional; artifacts declared and unwritten; and the
three G1 deviations reversed by `boundary` (findings 1 to 3): the tier map is a code-owned attribute in
Permissions, `surface_diff/1` takes the history, the runner names no behaviour.

## Versions touched
`VERSIONS.md` updated: yes, `jsv ~> 0.23` (already locked at 0.23.0 through req_llm) is a direct dependency with
its row. `mix.lock` unchanged. `versions.verify`: 84 locked packages, 49 pins.

## Git
```
$ git log --oneline main..HEAD
8a5b7ae feat(s020): the tool protocol, the registry, the concurrent runner, the catalog rule
6b4474c chore(s020): jsv ~> 0.23 becomes a direct dependency
7214526 docs(s020): G1 plan, and the slice opens
```

## Closing correction, 2026-09-20
Supersedes the "Final commit" field in the header: the commit carrying this file is `d332171`
(`feat(s020): complete slice 020 (tool protocol and registry)`); the `git log` block above lists the commits
before it. The pull request, its merge commit (signed in its body, docs/03) and the tag come after review.
