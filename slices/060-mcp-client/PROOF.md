# Proof for slice 060: MCP client (2026-07-28 preferred, 2025-11-25 compat)

Agent: Trinity · Coding Agent · Date: 2026-09-21 · Branch: slice/060-mcp-client · Final commit: (the commit carrying this file; named in the closing correction)

## Summary
Trinity's thin MCP client over beam_mcp 0.8.0's public functions (ADR-0007 decision 7): one supervised
`Trinity.MCP.Client` per `mcp_servers` row, a stdio transport (a child on a Port with an allow-listed
environment) and a Streamable HTTP transport (one POST per request with the revision's headers),
`server/discover` first and `initialize` at 2025-11-25 as the fallback, every listed tool registered as a
dynamic tool `mcp:<server>:<tool>` through one bridge module and a registry spec (no module per tool), every
result untrusted, and the multi-round-trip loop on the approval mechanism 021 built: a server's
`input_required` is an approval carrying its request, the owner's answer rides the decision, the retry
echoes the `requestState` byte-for-byte and the Session changes not at all. The `/mcp` page and the
input-request card on the permissions page. Deferred: Tasks (AC5, under 059's approved finding 4); the OAuth
client role is 062's (a static token is the seam). Five findings and five follow-ups in NOTES.md; the hard
part was not the wire but the environment a stdio child inherits and the sandbox pool a receipt needs
(NOTES findings 2 and the deviations).

## Gate
```
$ mix gate                                   (tree 49f40a4 with this file, NOTES.md and coverage.tsv uncommitted on top, this machine, OTP 28.5.0.5, Elixir 1.20.4, under a 32 GiB cgroup)
2443 mods/funs, found no issues.
... SCAN COMPLETE ...
No retired or security advisory packages found
No vulnerabilities found.
versions.verify: OK. 103 locked packages, none disagreeing with 53 pins
versions.gen: VERSIONS.md already matches Trinity.Versions and mix.lock
trinity.version_form: OK
trinity.names: OK over 615 tracked files
trinity.secrets.scan: OK over 615 files
trinity.reuse: OK. Every commentable tracked file carries an SPDX header
Result: 478 passed, 18 excluded
trinity.coverage: 060 80.32% vs 059 80.54%: OK
plan_check: PASS
exit=0
```
CI: named in the closing correction.

## Tests
```
$ mix test --cover                           (tree 49f40a4)
Result: 478 passed, 18 excluded
|     71.05% | Trinity.MCP.Client                     |
|     75.36% | Trinity.MCP.Bridge                     |
|     75.51% | Trinity.MCP.Client.Wire                |
|     65.15% | Trinity.MCP.Client.Transport.Stdio     |
|     50.00% | Trinity.MCP.Client.Transport.HTTP      |   (the 401 and the non-200 branches: no server under test answers them)
|     92.86% | Trinity.MCP.ServerConfig               |
|     80.32% | Total                                  |
```
`coverage.tsv` row: `060  80.32  49f40a4  2026-09-21` (from 80.54 at 059: two tenths, the transports' error branches)

Note: the gate above was run twice on 49f40a4: the first run failed rule 7 of plan_check on one board identifier in NOTES.md (a Tasks issue named by number); the identifier was replaced with words and the second run is the one pasted, every other step identical. The output lines are the second run's`.

The slice's tests (`mix test test/trinity/mcp test/trinity/tools/spec_registration_test.exs test/trinity_web/live/mcp_live_test.exs --trace`):
```
  * test the planted reference is a real reference: the file the proof compiles names BeamMCP outside Trinity.MCP
  * test the planted reference is a real reference: the file the proof compiles names BeamMCP outside Trinity.MCP [L#39]
  * test beam_mcp is in mix.lock at 0.8.0 and the VERSIONS row reads in mix.lock
  * test beam_mcp is in mix.lock at 0.8.0 and the VERSIONS row reads in mix.lock [L#15]
  * test the boundary compiler checks calls into beam_mcp everywhere, and Trinity.MCP is the boundary that lists it
  * test the boundary compiler checks calls into beam_mcp everywhere, and Trinity.MCP is the boundary that lists it [L#22]
  * test decoding and validation are the core's public functions; no decoder or validator of Trinity's own
  * test decoding and validation are the core's public functions; no decoder or validator of Trinity's own [L#68]
  * test the population is the driver's files, and it is not empty
  * test the population is the driver's files, and it is not empty [L#28]
  * test revision handling is the two openers; every method string is one the driver sends or a notification it reads
  * test revision handling is the two openers; every method string is one the driver sends or a notification it reads [L#40]
  * test AC3: the probe reports its diff size and the one census test it touches, and none of it is here
  * test AC3: the probe reports its diff size and the one census test it touches, and none of it is here [L#60]
  * test AC1: fifteen rows, numbered 1 to 15, each naming the pinned commit's paths with a line and a deriving command
  * test AC1: fifteen rows, numbered 1 to 15, each naming the pinned commit's paths with a line and a deriving command [L#30]
  * test AC2: the two conflicts are stated against the slice lines
  * test AC2: the two conflicts are stated against the slice lines [L#51]
  * test a variable outside the allow list and the refs is unset for the child; a ref is passed; PATH and HOME stay
  * test a variable outside the allow list and the refs is unset for the child; a ref is passed; PATH and HOME stay [L#18]
  * test a name outside the pattern, a transport without its command or url, a value beside the transport, a bad env ref, an unknown override are refused
  * test a name outside the pattern, a transport without its command or url, a value beside the transport, a bad env ref, an unknown override are refused [L#12]
  * test creating a disabled row starts no client; enabling starts one; deleting stops it; names are unique
  * test creating a disabled row starts no client; enabling starts one; deleting stops it; names are unique [L#65]
  * test a spec claiming :catalog is refused; an ill-formed spec is refused; a core tool may not carry one
  * test a spec claiming :catalog is refused; an ill-formed spec is refused; a core tool may not carry one [L#81]
  * test the entry's name, description, schema, risk, effect, timeout and digest are the spec's; two specs share one module
  * test the entry's name, description, schema, risk, effect, timeout and digest are the spec's; two specs share one module [L#37]
  * test the runner validates against the spec's schema and hands execute/2 the tool name in the context
  * test the runner validates against the spec's schema and hands execute/2 the tool name in the context [L#64]
  * test a call over stdio at each era answers; ping is only the legacy era's
  * test a call over stdio at each era answers; ping is only the legacy era's [L#67]
  * test AC1: stdio dual-era connects at 2026-07-28, stdio legacy at 2025-11-25, HTTP at 2026-07-28; every tool is registered under its namespace
  * test AC1: stdio dual-era connects at 2026-07-28, stdio legacy at 2025-11-25, HTTP at 2026-07-28; every tool is registered under its namespace [L#18]
  * test a server that lists no revision the driver speaks is refused, with the list in the error, and nothing is registered
  * test a server that lists no revision the driver speaks is refused, with the list in the error, and nothing is registered [L#95]
  * test AC6: the server dies: the tools are unregistered; it is restarted with backoff; the tools are registered again
  * test AC6: the server dies: the tools are unregistered; it is restarted with backoff; the tools are registered again [L#80]
  * test a call over HTTP mirrors the annotated argument into Mcp-Param, with the sentinel for a non-ASCII value; a failing tool is isError; an unknown one is refused
  * test a call over HTTP mirrors the annotated argument into Mcp-Param, with the sentinel for a non-ASCII value; a failing tool is isError; an unknown one is refused [L#50]
  * test a tool with an artifact override crosses the membrane as an effect
  * test a tool with an artifact override crosses the membrane as an effect [L#68]
  * test AC2: a call flows through Trinity.Effects.Runner with effect :none and yields a decision and a query receipt; the result is one untrusted part
  * test AC2: a call flows through Trinity.Effects.Runner with effect :none and yields a decision and a query receipt; the result is one untrusted part [L#35]
  * test AC3: a row claiming effect catalog for a tool is refused at load with a decision receipt on the server's scope, and the tool is not registered
  * test AC3: a row claiming effect catalog for a tool is refused at load with a decision receipt on the server's scope, and the tool is not registered [L#85]
  * test a failing tool is a result the model reads as the server's error, not a crash
  * test a failing tool is a result the model reads as the server's error, not a crash [L#56]
  * test AC4: surfaced as an approval carrying the server's request, answered, resumed with the state echoed, completed
  * test AC4: surfaced as an approval carrying the server's request, answered, resumed with the state echoed, completed [L#33]
  * test the server rejects a retry whose requestState is altered or omitted; the one echoed byte-for-byte completes
  * test the server rejects a retry whose requestState is altered or omitted; the one echoed byte-for-byte completes [L#85]
  * test an approval carrying a server's input request renders as a form; answering decides once with the typed answer
  * test an approval carrying a server's input request renders as a form; answering decides once with the typed answer [L#77]
  * test the page lists a server with its status, revision and tools; disable, enable and remove act on the row and the client
  * test the page lists a server with its status, revision and tools; disable, enable and remove act on the row and the client [L#19]
  * test declining a server's request denies the approval
  * test declining a server's request denies the approval [L#142]
  * test the form adds an http server, which connects; a bad row shows its errors
  * test the form adds an http server, which connects; a bad row shows its errors [L#47]
Finished in 3.5 seconds (0.08s async, 3.4s sync)
Result: 30 passed
```

## Acceptance criteria evidence

### AC1 [auto]: Both test servers connect; version chosen per server is logged and asserted (test)
Three servers under test, all beam_mcp's own transports over `Trinity.MCP.TestCatalog` (test/support/mcp):
stdio dual-era (a child VM running `test/support/mcp/stdio_server.exs`), stdio legacy-only (the same with
`legacy`, `supported_versions: ["2025-11-25"]`), and HTTP (`BeamMCP.Transport.HTTP` behind Bandit on a
loopback port). `client_test.exs` "AC1": each connects; `Client.info/1` reports `2026-07-28`, `2025-11-25`,
`2026-07-28`; the log lines `mcp s-modern: connected at 2026-07-28, 3 tools`, `mcp s-legacy: connected at
2025-11-25, 3 tools`, `mcp s-http: connected at 2026-07-28, 3 tools` are captured and asserted; the nine
tools are registered under `mcp:<server>:<tool>` with `kind: :dynamic, effect: :none, risk: :ask` and the
server's schema as the definition the model sees. A fourth server (the double with `future`) advertises a
revision nobody speaks and is refused with the list in `last_error`, nothing registered.

### AC2 [auto]: An MCP tool call flows through `Trinity.Effects` with `effect: :none` and yields a query receipt (test)
`bridge_test.exs` "AC2": `Trinity.Effects.Runner.run/2` on `mcp:b:add` under an allow rule answers the
server's sum as one untrusted part (`taint: :untrusted`, origin `tool:mcp:b:add`, source
`mcp://b/add`), and the session's chain holds `{"decision", "mcp:b:add"}` and `{"query", "mcp:b:add"}`
and nothing else. The neighbour test: an `artifact` override crosses the membrane (`effect admit` and
`effect done` receipts).

### AC3 [auto]: A server-config claiming `effect: :catalog` for an MCP tool is refused at load with a receipt (test)
`bridge_test.exs` "AC3", both halves: `Servers.create/1` with `tool_overrides: %{"echo" => %{"effect" =>
"catalog"}}` is refused by the changeset ("catalog is compile time and cannot be claimed"); a struct built
outside the changeset with the same claim, started through `Servers.start/1`, connects with `add` and
`boom` registered and `echo` absent, and the chain scope `mcp:c` holds one `decision` receipt, subject
`{"server" => "c", "tool" => "mcp:c:echo", "phase" => "load"}`, outcome `deny`, reason
`:catalog_is_compile_time` (read from the signed payload).

### AC4 [auto]: MRTR: the test server returns `input_required` with a `requestState`; the Session surfaces the request; answering resumes; the retried call carries the `requestState` back byte-for-byte and completes; a retry with the state altered or omitted is rejected by the server (test)
The server is Trinity's double for the wire (`test/support/mcp/mrtr_server.exs`; NOTES "Read before code":
the core refuses MRTR by design and the 061 wrapper is blocked on the seam). `mrtr_test.exs` "AC4" runs a
real Session with the fake provider calling `mcp:q:ask_name`: the gate's own approval first (the tier of a
namespaced name is `:ask`), then the server's question as a second approval whose `request` carries
`inputRequests.who` (method `elicitation/create`, message "What is your name?", `requestedSchema` requiring
`name`), the Session in `approval_wait`; `decide_request(id, :once, answer: %{"who" => %{"action" =>
"accept", "content" => %{"name" => "Ayla"}}})` resumes it; the tool row reads `Hi, Ayla` with `ok: true`;
the continuation is gone from the client and the approval row carries no `requestState`. The second test
takes the state from a direct call and shows the double refusing an altered state, an omitted state and a
state minted for other arguments (`-32602`), and completing on the exact bytes. The double's state is an
HMAC over the request it belongs to, as the revision asks servers to do.

### AC5 [deferred]: Tasks
Retagged at G1 (SLICE.md, NOTES.md "Read before code"): 059's approved finding 4 says this slice builds no
client for an extension the core neither builds nor refuses; the question goes to beam_mcp's board first
(the Tasks issue on its plan, after 1.0.0). Nothing of Tasks is in the tree.

### AC6 [auto]: Server dies → tools unregistered → reconnect → re-registered (test with short backoff)
`client_test.exs` "AC6": the stdio child's OS pid from `Client.info/1` is killed with `kill -9`; the client
reports `down` and `mcp:r:echo` is gone from the registry; with the suite's backoff (50 ms doubling to 400
ms, `config/test.exs`) it reconnects, a new child pid is reported, `attempts` is back to 0 and `mcp:r:echo`
is registered again.

### AC7 [auto]: The thin-driver rule: a census over `lib/trinity/mcp/client/` (test, with the population command pasted)
```
$ git ls-files lib/trinity/mcp/client lib/trinity/mcp/client.ex
lib/trinity/mcp/client.ex
lib/trinity/mcp/client/auth.ex
lib/trinity/mcp/client/transport.ex
lib/trinity/mcp/client/transport/http.ex
lib/trinity/mcp/client/transport/stdio.ex
lib/trinity/mcp/client/wire.ex
```
`thin_driver_census_test.exs` holds that population to: every `"a/b"` string is a method the driver sends
(`server/discover`, `initialize`, `notifications/initialized`, `tools/list`, `tools/call`, `ping`,
`prompts/get`, `resources/read`) or the one notification it reads, plus the HTTP media type; the two
revision literals are in `wire.ex` and quoted nowhere else; decoding is `BeamMCP.JSON.decode/1` and
validation `BeamMCP.Schema.validate/2`, both in `wire.ex`, which is the only file naming the core; no
`Jason.decode`, no `JSV`, no `Trinity.Tools.Schema`, no schema literal. Beside it, 059's boundary census now
holds the two referrers of `BeamMCP.` under `lib/` (`mcp.ex`, `mcp/client/wire.ex`) and nothing outside
`lib/trinity/mcp/`.

### AC8 [manual]: One real public 2026-07-28 server used end-to-end (GIF)
Done once here against `https://mcpplaygroundonline.com/mcp-stateless-server` (NOTES finding 1), with
`scripts/dev_chat_mcp_playground.sh` (the chat on its own database, the fake provider scripted to call
`mcp:playground:mrtr_signed_state` with `target: "slice 060"`) and a headless browser:
`proof/ac8-mrtr-playground.gif` and the four frames `proof/ac8-1-mcp-page.png` (the server ready at
2026-07-28 with its three tools), `proof/ac8-2-ask.png` (the gate's approval), `proof/ac8-3-server-asks.png`
(the server's question, "Re-issue this call, echoing requestState verbatim", as the card's form) and
`proof/ac8-4-done.png` (the retry accepted, the label back). The server's own answer to a direct probe:
```
$ curl -s -X POST https://mcpplaygroundonline.com/mcp-stateless-server -H 'content-type: application/json' -H 'mcp-protocol-version: 2026-07-28' -H 'mcp-method: server/discover' -d '{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}'
{"result":{"supportedVersions":["2026-07-28"],"capabilities":{"tools":{"listChanged":true}},"resultType":"complete","ttlMs":300000,"cacheScope":"public",…},"jsonrpc":"2.0","id":1}
```
The owner's queue: rerun the script (`PORT=` is printed), open `/mcp` and a new conversation, send any
message, allow once, tick `proceed`, answer; or read the GIF.

## Manual verification for the reviewer
AC8 above. Everything else is a test.

## Deviations from SLICE.md
NOTES.md: two stated before code (Tasks deferred; AC4's server a double), four found building (no `risk`
override, the child's environment allow list, the stdio log handler, `server/discover` with the modern
`_meta`).

## Versions touched
`VERSIONS.md` updated: no. No new dependency: Req (022), Bandit (Phoenix), beam_mcp (059).
`mix versions.verify`: named in the gate output above.

## Git
```
$ git log --oneline main..HEAD
(named in the closing correction, after the final commit)
```
