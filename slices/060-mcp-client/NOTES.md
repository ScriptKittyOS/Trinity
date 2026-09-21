# Slice 060: NOTES

## Read before code, 2026-09-21

Tree at `c96adbe` on `main` (059 approved). What this slice joins: 020's registry, which admits a
dynamic tool only under a namespace (`mcp:<server>:<tool>`) and never with `effect: :catalog`; 021's gate,
whose tier for a name outside the core map is `:ask`, and whose "allow once" is the newest decided approval
for the fingerprint, consumed by the call that runs; 012's Session, which holds a call answering
`{:error, {:approval_required, id}}` and re-runs it when the approval is decided; 024's membrane, where an
`effect: :none` tool runs directly with a query receipt and an `effect: :artifact` one crosses
`Trinity.Effects.execute/2`; 059's `Trinity.MCP` boundary (the one place that may reach `BeamMCP.*`), its
FINDINGS (row 1: HTTP is 2026-07-28 only, stdio is dual-era; row 9: the core refuses MRTR, entry 12; row 10:
Tasks is open in the core; row 12: the public functions a client may call are `BeamMCP.JSON.decode/1`,
`BeamMCP.Schema.validate/2`, `BeamMCP.Cursor.decode/2`).

The wire the driver builds, from the core's source at `cfa706b` (the server under test is that core):
2026-07-28 opens with `server/discover` (answered whatever the `_meta`; the result's `supportedVersions`
is the list); every later request carries `params._meta` with `io.modelcontextprotocol/protocolVersion` and
`io.modelcontextprotocol/clientCapabilities`; over HTTP one POST per request with `MCP-Protocol-Version`,
`Mcp-Method`, `Mcp-Name` (the tool, resource or prompt name) and `Mcp-Param-{Name}` for every argument the
listed `inputSchema` annotates `x-mcp-header`; no session, no `initialize`. 2025-11-25 opens with
`initialize` (`protocolVersion` in the params) and `notifications/initialized`, then `_meta` names the
revision; `ping` exists. MRTR on the wire: a result with `resultType: "input_required"`, `inputRequests`
and an opaque `requestState`; the continuation is the same request with `inputResponses` (a list keyed by
the request ids) and `requestState` echoed in `params`.

Two places where SLICE.md and the approved record of 059 disagree, decided here and open to the owner's
veto in this turn:

- **Tasks (AC5, and "Tasks extension" in the Goal and Scope) is out of this slice.** 059's NOTES finding 4,
  approved with the slice: the Tasks extension is neither built nor refused in the core; "060 builds no
  client for it and 061 does not advertise it; if a later slice needs it, the question goes to beam_mcp's
  board first". The same sentence went to that board on 2026-09-21. A client for an extension the server core
  does not speak would be tested against nothing but a double written to the same assumption. AC5 is
  retagged `[deferred]` in SLICE.md in this commit, with this note quoted; the ROADMAP row's title keeps
  "Tasks" until the owner says how to word it.
- **AC4's server is a Trinity test double, not a beam_mcp server.** The core answers every request
  completely (entry 12), so the "test server that returns `input_required`" cannot be built with it; the
  061 wrapper that will is blocked on the seam. `test/support/mcp/mrtr_server.exs` is a stdio script of
  Trinity's own that answers `tools/list` with one tool and `tools/call` with `input_required` and a
  `requestState` (an HMAC over the request it holds), completes on the continuation that echoes it
  byte-for-byte, and refuses one that alters or omits it. It is a double for the wire the 2026-07-28
  revision defines, not for beam_mcp.

The other two servers under test are the core: `test/support/mcp/stdio_server.exs` runs
`BeamMCP.Transport.Stdio.run/1` over a small catalog as a Port (`elixir -pa … -e …`, dual-era, and a second
launch with `supported_versions: ["2025-11-25"]` for the legacy path), and the HTTP server is
`BeamMCP.Transport.HTTP` behind Bandit on a random port in the test process.

## G1 plan, 2026-09-21

Branch `slice/060-mcp-client`; ROADMAP row 060 to `in_progress` in this commit. Each line names its test.

1. Migration `mcp_servers` (docs/05): `name` (unique, the namespace segment, `[a-z0-9_-]{1,32}`),
   `transport` (`stdio | http`), `command`, `args` (list), `url`, `env_refs` (names of environment
   variables to pass through to a stdio child; never values), `enabled`, `effect_default` (`none |
   artifact`), `tool_overrides` (map: tool name to `%{"effect" => …, "risk" => …}`), `last_error`. Schema
   `Trinity.MCP.ServerConfig` (not `Trinity.MCP.Server`, which is 061's). Test: the changeset's refusals
   (a name outside the pattern, a transport without its command or url, an override claiming `catalog`).
2. `Trinity.Tools.Registry.register/2` takes a dynamic tool as a module plus `spec:` (name, description,
   schema, risk, effect, timeout) so one module (`Trinity.MCP.Bridge`) serves every MCP tool with no
   runtime module per tool (an atom per tool name a server chooses would be a leak a rotating catalog
   could drive); the entry carries `spec`, and `to_llm_tools/1`, the digest, the runner's validation and
   timeout read it when present; `Trinity.Tools.Context` gains `tool`, the entry's name, set beside
   `call_id`. Both callers of `execute/2` pass the context and stay the two the effects census allows.
   Tests: registry (a spec'd entry lists, digests and validates from the spec; a spec claiming `:catalog`
   is refused), runner (a spec'd call reaches `execute/2` with `ctx.tool` set).
3. `Trinity.MCP.Client` (one GenServer per configured server, under `Trinity.MCP.Supervisor`, a
   DynamicSupervisor started by `Trinity.Application`; `Trinity.MCP.Boot` starts one per enabled row with
   the gate's rescue for a missing table): connect, discover, list, register, serve calls, watch, reconnect.
   The transports are `Trinity.MCP.Client.Transport.Stdio` (a Port on the command, newline-delimited,
   `env_refs` resolved at start, stderr to the log) and `Trinity.MCP.Client.Transport.HTTP` (Req, one POST
   per request, the headers above, the bearer from `Trinity.MCP.Client.Auth` (062's seam: at this slice it
   reads a static token from an env ref or returns none; a `401` with `WWW-Authenticate` is a logged
   refusal and a `last_error`, no flow of its own). Version selection: `server/discover` first; the
   preferred revision if listed, else `initialize` at 2025-11-25 if listed, else refused with the list in
   `last_error`. Test AC1: the three servers under test connect and the chosen revision per server is
   asserted from the client's state and the log.
4. `Trinity.MCP.Client.Wire`: builds the outbound request object (id, method, params, `_meta`), and the
   HTTP headers from it and the tool's listed schema; decodes with `BeamMCP.JSON.decode/1`; validates
   arguments against the listed `inputSchema` with `BeamMCP.Schema.validate/2` before sending. Nothing else
   of the protocol. Test AC7: the census over `git ls-files lib/trinity/mcp/client` (the population
   command pasted in PROOF) finds the two method names for revision handling and no other, no
   `Jason.decode`, no `JSV`, no schema literal beyond the request envelope.
5. `Trinity.MCP.Bridge` (`@behaviour Trinity.Tools.Tool`): `execute/2` reads `ctx.tool`, finds the client
   by the server segment, calls, and maps the result's content parts to one `Trinity.Tools.Untrusted`
   result (text parts joined; an image or resource part rendered as a line naming its type and size),
   `meta` carrying the server, the tool and the revision. Registration per tool: name
   `mcp:<server>:<tool>`, effect from `effect_default` and the override (`catalog` refused at load with a
   `decision` receipt of outcome `deny` on the server's chain scope `mcp:<server>`, and the tool skipped),
   risk `:ask` unless an override says lower for that name (superseded below: no override lowers
   it). Tests AC2 (a call through
   `Trinity.Effects.Runner` with `effect: :none` yields a query receipt), AC3 (an override claiming
   `catalog` is refused at load with the receipt), and the mapping.
6. MRTR (AC4) on the approval mechanism 021 already has, so the Session changes not at all: on
   `input_required` the bridge stores the continuation (`requestState` verbatim, the `inputRequests`, the
   call id) in the client keyed by `{session_id, call_id}`, creates an approval with the same fingerprint
   as the running call and the input request in a new `request` column, and answers
   `{:error, {:approval_required, id}}`; the Session holds the call and re-runs it on the decision; the
   gate consumes the "once"; the bridge finds the continuation for the call id, reads the `answer` column
   the decision wrote, and sends the same request with `inputResponses` and the `requestState` bytes
   untouched. Migration: `approvals` gains `request` (map) and `answer` (map); `decide_request/3` takes
   `answer:`; the permissions page renders a form from `requestedSchema` (string, number, boolean, enum)
   when an approval carries a request. Test AC4 against the double: surfaced, answered, resumed, the
   echoed bytes equal; an altered or omitted state refused by the double.
7. Health and reconnect: the client monitors the Port or the HTTP failure count, unregisters its tools on
   loss, backs off (250 ms doubling to 30 s, both configurable) and re-registers on return; `ttlMs` from
   `tools/list` schedules a re-list (0 means on reconnect only); `notifications/tools/list_changed` over
   stdio triggers one. Test AC6 with a short backoff: killed child, tools gone, restarted, tools back.
8. `/mcp` LiveView: the servers with health, revision, tool count, last error; enable, disable, add
   (stdio or http), remove; tools listed with their effect and tier. Route, nav link, README page list.
9. Docs: docs/01 (the MCP client under the boundary), docs/05 (the two tables), docs/07 (the MRTR answer
   is an approval; MCP results are untrusted), docs/08 (the client row of the MCP standard), README.
10. Gate, coverage, PROOF; the ROADMAP row.

Manual verification queue: **AC8**, one real public 2026-07-28 server used end-to-end (GIF). A public
server that speaks the 2026-07-28 revision may not exist yet on the open internet (the revision is two
months old and the stateless HTTP transport is the part most servers have not adopted); if none is found,
the GIF is against a beam_mcp server the owner runs, and the criterion's word "public" is the owner's to
keep or retag.

Not built here: the OAuth client role (062), Tasks (see above), sampling, roots, logging, SSE,
`subscriptions/listen` for tool list changes (stdio's notification and `ttlMs` cover re-listing; a
subscription over stateless HTTP has nothing to hold it).

## Deviations while building, 2026-09-21

- **No `risk` in a row's `tool_overrides`.** The plan's line 5 said an override could lower a tool's tier.
  It cannot: `Trinity.Permissions.tier/1` maps the core names alone and answers `:ask` for every other
  (docs/07, "unmapped goes to ask"), and a dynamic entry's `risk` is never handed to the permission
  layer (021: only the registry in the application tree writes the core tiers, "a dynamic tool never
  reaches this line"). A `risk` on the row would have claimed something the gate never honours. The
  override carries `effect` alone; the tier of every MCP tool is `:ask`, and the owner lowers it the way
  every other tier is lowered, with a rule on the permissions page. Test: `spec_registration_test.exs`
  runs a spec'd call under a rule, and `server_config_test.exs` refuses an unknown override key.
- **The stdio child's environment is an allow list, not an add list.** A Port's `env:` adds to the
  inherited environment (022's lesson), so the child of an MCP row would have seen every variable this
  VM holds, provider keys first. Every inherited variable outside PATH, HOME, the locale and temp
  variables and the row's `env_refs` is unset by name for the child (`Transport.Stdio.kept_variables/0`),
  on every OS. Test: `stdio_env_test.exs`.
- **A stdio server's log must not go to stdout.** The Elixir VM's default log handler writes to standard
  output, which is the wire. The stdio server under test moves its handler to standard error; a child
  that logs to stdout is read as undecodable lines (warned, dropped) and its answers still correlate by
  id. Worth a line on beam_mcp's stdio page (follow-up, not raised yet).
- **`server/discover` carries the modern `_meta`.** The HTTP transport requires a version on every POST;
  the dual-era core answers `server/discover` whatever the `_meta` says; a legacy-only core answers
  `-32022` naming what it supports, which the driver reads as its cue to `initialize`.

## Findings at G3, 2026-09-21

1. **A public 2026-07-28 server exists, and AC8 ran against it.** The G1 plan doubted one would be found;
   `https://mcpplaygroundonline.com/mcp-stateless-server` speaks the revision (stateless, `server/discover`
   lists `["2026-07-28"]`, `ttlMs` 300000 on discover and 60000 on the list, `cacheScope` public) and ships
   three tools, two of them multi-round-trip (`mrtr_confirm` with no `requestState`, `mrtr_signed_state`
   with an HMAC-sealed one). `scripts/dev_chat_mcp_playground.sh` boots the chat against it with the fake
   provider scripted to call `mcp:playground:mrtr_signed_state`; the recording in `proof/` is the owner's
   manual queue done once here, and the criterion's word "public" holds as written.
2. **A receipt written from a tool task needs a pool nobody owns in the test environment.** The first run of
   that script timed out every call through the membrane: `Trinity.Repo.Receipts` keeps the sandbox pool in
   `config/test.exs`, and the decision receipt's `ensure_writer` waited on a checkout from a process outside
   any sandbox owner (stacktrace in the session log, `Trinity.Receipts.ensure_writer/1`). The direct paths
   (`Bridge.execute/2`, `Tools.Runner`) never touched it, which is why they were fast. The script now takes
   both repos off the sandbox pool, as `serve030.sh` did at 030; the earlier 021 script predates the receipts
   repo. Not a defect in the tree: a dev-script rule, recorded so the next screenshot script starts from it.
3. **The gate reads the spec's risk nowhere.** Recorded under "Deviations": no row lowers a tool's tier.
4. **The stdio child's stdout is the wire, and the Elixir VM logs to stdout by default.** The server under
   test moves its log handler to standard error; a host running `BeamMCP.Transport.Stdio` should do the
   same, and the package's page does not say so. Follow-up for beam_mcp's board, below.
5. **The one census that moved.** 059's boundary census pinned `lib/trinity/mcp.ex` as the only referrer of
   `BeamMCP.`; the wire module is the second, under the same boundary, and the census now holds both and
   that nothing outside `lib/trinity/mcp/` names the core.

## Follow-ups

- beam_mcp's board: a line on the stdio page that the host's log handler must not write to standard output
  (finding 4); and, when 0.9.0 ships, 061 pins it (the seam ask is already on that board, 2026-09-21).
- Tasks (AC5, deferred): a client for the extension when the core builds or refuses it (the Tasks issue on that board, after 1.0.0
  on beam_mcp's plan).
- `Trinity.MCP.Client.Auth` is 062's seam: the static `TRINITY_MCP_<NAME>_TOKEN` variable is the whole of it
  at this slice, and a `401` is a logged refusal.
- Slice 090: the client emits no telemetry of its own yet; the core's dispatch events are the server side's.
  A `[:trinity, :mcp, :call, :start | :stop]` pair around `Client.call/4` belongs in 090's catalogue.
- Windows: the stdio transport's environment allow list uses `{name, false}` on the Port, which every OS
  honours, but nothing here was run on Windows; the package workflow does not run the suite there.
