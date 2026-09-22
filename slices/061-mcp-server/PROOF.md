# Proof for slice 061: MCP server (stateless 2026-07-28, compat for 2025-11-25)

Agent: Trinity · Coding Agent · Date: 2026-09-22 · Branch: slice/061-mcp-server · Final commit: (the commit carrying this file; named in the closing correction)

## Summary
Trinity as an MCP server above beam_mcp 0.9.0's core, through the `:server` seam that release shipped:
`Trinity.MCP.Server` implements `BeamMCP.Server`, answers `tools/call` through the permission gate and the
membrane in an `origin: "mcp"` session with a persona of its own, and delegates every other message to
the core. The exported tools are a configured, sorted list (the read-only set by default; `:catalog`
refused). A held call answers `input_required` with a `requestState` sealed by AES-256-GCM under a key in the
data directory, so the exchange completes on any instance of the same data directory; the replay defence
is a partition-local nonce table plus the gate's consumed "once" and the membrane's idempotency key. A
static bearer before the body (`Auth.Local`, 062's seam), the plug in the endpoint ahead of the parsers, a
stdio entry point (dual-era; the HTTP route serves 2026-07-28 alone by the core's design), the `headless`
release with its bind and port and a container recipe built and run here. Deferred: Tasks (059 finding 4);
the OAuth roles (062). One defect in 030 found and fixed (the default SOUL path). Five findings and five
deviations in NOTES.md.

## Gate
```
$ mix gate                                   (GATE_TREE, this machine, OTP 28.5.0.5, Elixir 1.20.4, under a 32 GiB cgroup)
GATE_OUTPUT
```
CI: named in the closing correction.

## Tests
```
$ mix test --cover                           (COVER_TREE)
COVER_OUTPUT
```
`coverage.tsv` row: `COVER_ROW`.

The slice's tests (`mix test test/trinity/mcp/server_test.exs test/trinity/mcp/server_mrtr_test.exs --trace`):
```
SLICE_TESTS
```

## Acceptance criteria evidence

### AC1 [auto]: Our 060 client connects at 2026-07-28 and lists exported tools; a 2025-11-25 test client connects to the same wrapper over the stdio wire (amended at G1)
`server_test.exs` "AC1", first test: a `mcp_servers` row named `self` pointing at this VM's own endpoint
(`http://127.0.0.1:<port>/mcp`, the bearer in the client's `TRINITY_MCP_SELF_TOKEN` and the server's
`TRINITY_MCP_SERVER_TOKEN`) connects at `2026-07-28` and registers `mcp:self:recall`, `mcp:self:session_search`,
`mcp:self:skills_list`, `mcp:self:skill_view`, `mcp:self:skill_file` and `mcp:self:memory` (the test exports
`memory` too), with the server's schema as each definition. Second test: the 2025-11-25 wire against the
wrapper (`initialize` with `protocolVersion: "2025-11-25"`, `notifications/initialized`, `tools/list` and
`tools/call skills_list` without `_meta`) answers all three, the answers carrying no `resultType`. The same
wire through the stdio transport was measured by hand (NOTES finding 3):
```
$ printf '<initialize 2025-11-25>\n<tools/list>\n<tools/call skills_list>\n' | mix trinity.mcp.stdio 2>stdio.err
{"id":1,"jsonrpc":"2.0","result":{"capabilities":{…},"protocolVersion":"2025-11-25","serverInfo":{"name":"trinity","version":"0.9.0"}}}
{"id":2,"jsonrpc":"2.0","result":{"cacheScope":"private","tools":[{"annotations":{…},"description":"Recalls what is relevant …
{"id":3,"jsonrpc":"2.0","result":{"content":[{"text":"## Skills\ndevelopment:\n- elixir-project-conventions: …
```
Over HTTP the core's transport refuses any version but 2026-07-28 at the header (059 FINDINGS row 1); the
deviation is in NOTES.md "Read before code" and SLICE.md's AC1 line.

### AC2 [auto]: `tools/list` is deterministic and carries `ttlMs`/`cacheScope`; two calls return identical order
`server_test.exs` "AC2": two `tools/list` answers against the wrapper are identical; the names are sorted
(`memory`, `recall`, `session_search`, `skill_file`, `skill_view`, `skills_list`); `ttlMs` and `cacheScope`
are present (`0` and `private` on the bare wrapper; `60000` and `private` through the plug, whose options
carry the configured values, as the AC6 log shows); `resultType` is `complete`; `recall` is
`readOnlyHint: true` and `memory` `destructiveHint: true` from the catalog's modes.

### AC3 [auto]: `recall` via MCP yields a query receipt with `origin: "mcp"`
`server_test.exs` "AC3": through the route and our client, `recall` under an allow rule answers `complete`,
and the MCP session's chain holds `{"decision", "recall", "mcp"}` and `{"query", "recall", "mcp"}` (kind,
subject tool, subject origin). The neighbour test: a `traceparent` in the request's `_meta` is in the
receipts' `meta.trace`.

### AC4 [auto]: An `:artifact` tool via MCP → `input_required` → approval in UI → retry succeeds; deny → retry gets a denial result and a receipt (tests + screenshot)
`server_test.exs` "AC4": `memory` (exported for the test) answers `input_required` with one elicitation
request naming the approval and the permissions page and a `v1.` state; the approval row is on the MCP
session; a retry before the decision is held again under a fresh state; after `decide_request(id, :once)`
the retry with the current state answers `complete` ("Kept always_on colour") and the chain holds `effect
admit` and `effect done`; a second call denied on the page makes the retry an `isError` "denied…" and a
decision receipt of outcome `deny`. The screenshots: `proof/ac4-mcp-approval-pending.png` (the card on
`/permissions`, "An MCP client asks Trinity to run memory", the arguments, the four buttons) and
`proof/ac4-mcp-approval-decided.png` (the row "allowed · once"), taken with `scripts/dev_mcp_server_approval.sh`
and a headless browser.

### AC5 [auto]: A tool claiming `:catalog` is not exportable (config validation test)
`server_test.exs` "AC5": `Exports.resolve(["shell"])` is `{[], [{"shell", :catalog_is_not_exportable}]}`; an
unknown name is `:unknown_tool`; with `tools: ["shell", "recall"]` configured, `Catalog.capabilities/0` lists
`recall` alone. `Trinity.MCP.Boot` logs each refusal at boot.

### AC6 [auto]: Headless release boots in a container with no display and serves `server/discover` (log)
`ci/headless/Containerfile`, built from this tree with `docker build` (the release assembled on
`hexpm/elixir:1.20.4-erlang-28.5.0.5-debian-bookworm-20260824-slim`, run on `debian:bookworm-20260824-slim`,
644 MB), run with `docker run -d -p 127.0.0.1:4061:4000 -v trinity-ac6-data:/data -e
TRINITY_MCP_SERVER_TOKEN=… -e SECRET_KEY_BASE=…`. `proof/ac6-headless-container.log` is the run: `GET /` 200;
`server/discover` through the bearer answers `supportedVersions: ["2026-07-28"]`, `resultType: complete`;
the same POST without the bearer is 403 (`refused by host authorize/1: :no_bearer` in the log); `tools/list`
names the five defaults with `ttlMs 60000`, `cacheScope private`; the container's log reads `Running
TrinityWeb.Endpoint with Bandit 1.12.5 at 0.0.0.0:4000`, `mcp server: exporting 5 tools at /mcp`; inside,
`uid=10001(trinity)`, `DISPLAY=unset`, `/data/trinity/keys/mcp-state.key` at mode 0600. The first run of the
image found the 030 defect (`GET /` 500, NOTES finding 1); the log in `proof/` is the rerun on the fixed image.

### AC7 [auto]: An MRTR exchange begun against one server instance completes against a different instance of the same release, carrying only the `requestState`; a retry with it altered or missing is refused
`server_mrtr_test.exs`, two Plug instances (`server_name` `instance-a` and `instance-b`) through the core's
HTTP transport with `Plug.Test`, sharing the data directory and the database. First test: begun on A
(`input_required`, `_meta.serverInfo.name: instance-a`), decided by the owner, completed on B with the state
alone (`instance-b`), one `effect done` receipt; the same state on A after a fresh replay table asks the owner
again and nothing runs twice (NOTES finding 4). Second test: a replay inside the partition is `requestState
already used`; one altered byte `requestState tampered`; a wrong version `requestState malformed`; an
envelope sealed for zero seconds `requestState expired`; a state carried to other arguments `requestState
does not belong to this call`; a call with no state is a first call, held on a new approval, with no effect
receipt at all. "Missing" is refused in the sense that matters: nothing runs without a decided approval.

### AC8 [manual]: Claude Code connected and calling `recall` (screenshot)
The owner's queue. The steps are in `docs/mcp-server.md` ("Connecting a client over HTTP"): run Trinity
(`mix phx.server`, or the headless release), read `<data dir>/mcp-server-token`, then
`claude mcp add --transport http trinity http://127.0.0.1:<port>/mcp --header "Authorization: Bearer <token>"`
and ask Claude Code to recall something; the call appears on `/s/<mcp session>/receipts` with `origin: mcp`.
The automatic half is AC1 and AC3 above: our own client connecting to the same route and calling `recall`.

## Manual verification for the reviewer
AC8 above; and `proof/ac4-mcp-approval-pending.png` if the card's wording is worth a look.

## Deviations from SLICE.md
NOTES.md: three stated before code (the 2025-11-25 client over stdio, not the HTTP route; Tasks out; a
legacy client's approval as a tool error) and five found building (the plug in the endpoint; the MCP
persona; a pending retry held without the gate; the card's actor; the stdio log handler).

## Versions touched
`VERSIONS.md` updated: yes, by `mix versions.gen`: the `beam_mcp` row from `~> 0.8` to `~> 0.9` (0.9.0, hex
checksum `2bf9615c…`, the one beam_mcp's release record names). No other dependency changed.

## Git
```
$ git log --oneline main..HEAD
(named in the closing correction, after the final commit)
```
