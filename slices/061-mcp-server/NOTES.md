# Slice 061: NOTES

## Read before code, 2026-09-22

Tree at `a130e95` on `main` (060 approved), then beam_mcp pinned at `~> 0.9` in this branch's first commit:
0.9.0 on hex.pm 2026-09-22, tag `v0.9.0` at `10e4252`, the lock's package checksum `2bf9615c…` the one the
release record on beam_mcp's board names; the 060 client suite passes on it unchanged (`mix test
test/trinity/mcp` → 23 passed), which is the "no break" claim measured from the consumer's side.

What 0.9.0 gives this slice, from its CHANGELOG and `docs/public-api.txt` at `10e4252`: the `:server`
option on `BeamMCP.Transport.HTTP.init/1` and `BeamMCP.Transport.Stdio.run/1`, default `BeamMCP.Server`,
validated at init structurally (`new/1` and `handle_message/2` exported; stdio asks `shutdown?/1` too);
`BeamMCP.Server` as a behaviour (`c:new/1`, `c:handle_message/2`, `c:shutdown?/1` optional), the answer to
the question 059's board note left open; `:server` popped before the rest of the options reach the wrapper's
`new/1`; will-not-implement entry 12 unchanged (the core still answers every request completely).

What this slice joins: 060's client (AC1's first half is our own driver connecting to our own server), 024's
membrane (`Trinity.Effects.Runner.run/2` with a context: decision receipt, then a query receipt or the
membrane), 021's approvals (the gate holds an `:ask` call as a pending row the owner decides on the
permissions page; "allow once" is consumed by the call that runs), 020's registry (the exported tools are core
entries; `:catalog` never leaves the compile-time list), the data directory's keys (`Trinity.Receipts.KeyCustody`
keeps its key files under `<data dir>/keys/`, the place the envelope key goes too), and the
`Trinity.DataDir.Lock`'s `headless` mode, which already reads `TRINITY_MODE`.

Two facts the SLICE's 2026-09-20 blocker list carries that are now settled, so they do not shape the plan:
`resultType` is stamped on every 2026-07-28 result at 0.8.0 (059 FINDINGS row 8; the line saying "only
`tools/call`" is superseded), and the seam is shipped, so the ADR's fallback (a fork of the dispatch
function) is not taken.

Three places where SLICE.md and the core as shipped disagree, decided here and open to the owner's veto in
this turn:

- **A 2025-11-25 client does not connect over the `/mcp` route, by the transport's design.** 059 FINDINGS
  row 1: `BeamMCP.Transport.HTTP` serves 2026-07-28 alone and refuses any other version at the header
  (`-32022`), and the README says why (HTTP is the carrier that stamps every request modern; `initialize`
  is refused at the transport). The core underneath is dual-era, and so is the wrapper this slice builds
  above it: AC1's second half is proven against the wrapper on the wire the stdio transport carries
  (`initialize`, then `_meta` naming 2025-11-25), and a stdio entry point (`mix trinity.mcp.stdio`, the
  same wrapper under `BeamMCP.Transport.Stdio.run/1`) is the route a 2025-11-25 client has. The goal line's
  "from the same route" is not met over HTTP and cannot be without a change in beam_mcp that its README
  refuses; recorded, not raised.
- **Tasks is out**, as at 060: 059's approved finding 4 ("061 does not advertise it"). The goal's "Tasks
  for long tools" and the scope line are not built; `server/discover` advertises no extension.
- **MRTR for approvals answers `input_required` to a 2026-07-28 client; a 2025-11-25 client gets a tool
  error instead.** MRTR is the modern revision's pattern; the legacy revision has no `input_required`, so a
  legacy call that needs approval is answered `isError` with the approval's id and the instruction to retry
  after deciding, and the retry after the decision runs (the gate's "once" is consumed by it).

The envelope (`requestState`), as the SLICE asks: minted and validated by Trinity, opaque to the client,
sealed with AES-256-GCM (FIPS-approved; the receipt scheme's FIPS leg runs this suite) under a key in
`<data dir>/keys/mcp-state.key` (32 bytes, generated once, mode 0600, shared by every instance of the same
data directory, which is what AC7's "different instance of the same release" needs). The plaintext binds
the approval id, the session, the call id, the tool, a digest of the arguments, a nonce and an expiry. Replay
defence is the SLICE's: a partition-local nonce cache keyed by expiry window (an ETS table, pruned by
window), and the membrane's idempotency key (`session_id` + `call_id`, refused as `duplicate_effect` on a
second run) as the cross-partition backstop; the property is at-most-once per partition plus idempotent
effects, stated as such, with reds for a replay inside the window, a replay across partitions, an expired
envelope and one tampered byte.

## G1 plan, 2026-09-22

Branch `slice/061-mcp-server`; ROADMAP row 061 to `in_progress` in the pin commit. Each line names its test.

1. `Trinity.MCP.Server.Exports`: the exported tools from `config :trinity, :mcp_server, tools:` (default the
   read-only set `recall`, `session_search`, `skills_list`, `skill_view`, `skill_file`; `memory` and the other
   `:artifact` tools opt-in by name), validated at boot against the registry: a name that is not a core
   entry or whose effect is `:catalog` is refused with a reason and not exported. Test AC5 (a config naming
   `shell` is refused; the catalog never lists it).
2. `Trinity.MCP.Server.Catalog` (`@behaviour BeamMCP.Catalog`): one `ToolSpec` per exported entry, name,
   description and `input_schema` from the registry, `mode: :read_only` for `:none` and `:proposal` for
   `:artifact`, **sorted by name** (059 finding 3: the core keeps the catalog's order); no resources, no
   prompts; the connectome surface not exported (the SLICE's default, off). Test AC2 (two `tools/list`
   answers are identical, ordered, and carry `ttlMs` and `cacheScope` from the host's options).
3. `Trinity.MCP.Server` (`@behaviour BeamMCP.Server`): `new/1` wraps the core's state; `handle_message/2`
   intercepts `tools/call` (arguments validated by `BeamMCP.Schema.validate/2` against the listed schema,
   then `Trinity.Effects.Runner.run/2` in the MCP context; the result mapped to content, `isError`,
   `structuredContent`, and at 2026-07-28 `resultType` and the server's `_meta`) and delegates every other
   message to the core; `shutdown?/1` is the core's. The era of a request is read as the core reads it: the
   `_meta` version, or the legacy state an `initialize` set. Tests AC1 (our 060 client connects at
   2026-07-28 over the route and lists the exported tools; a 2025-11-25 wire against the wrapper connects
   with `initialize` and calls a tool) and AC3.
4. The MCP context: one session row per server with `origin: "mcp"` (found or created by
   `Trinity.MCP.Server.Session`, the default persona, title "MCP server"), the effects run with
   `Trinity.Tools.Context` carrying `origin: "mcp"` (a new field, written into the decision and query
   receipts' subject by `Trinity.Effects.Runner`), and the incoming `_meta` trace context (`traceparent`,
   when present) copied into the receipts' meta for 090. Test AC3 (`recall` over MCP yields a query receipt
   whose subject carries `"origin" => "mcp"`).
5. `Trinity.MCP.Server.Envelope` (seal, open, the key file) and `Trinity.MCP.Server.Replay` (the nonce
   cache). On `{:error, {:approval_required, id}}` a 2026-07-28 call answers `input_required` with one
   elicitation request (the approval named, the permissions page named, a `requestedSchema` with one
   boolean so a generic client can retry) and the sealed envelope; a retry opens the envelope, refuses an
   expired, tampered, replayed or mismatched one (`-32602`, the reason named, nothing of the plaintext
   echoed), runs under the envelope's call id, and answers `input_required` again with a fresh envelope
   while the approval is pending, the result once it is allowed, an `isError` denial once it is denied.
   Tests AC4 (approve in the UI, the retry succeeds; deny, the retry gets a denial and a receipt) and AC7
   (two Plug instances of the wrapper with different server names share the data directory; an exchange
   begun on one completes on the other with the state alone; altered, missing, expired and replayed states
   are refused).
6. `Trinity.MCP.Server.Auth.Local` (`:authorize`): the bearer from `TRINITY_MCP_SERVER_TOKEN`, or a token
   generated at boot into `<data dir>/mcp-server-token` (mode 0600) when the variable is unset; a request
   without the right bearer is refused before the body is read. `Trinity.MCP.Server.Plug` wraps
   `BeamMCP.Transport.HTTP` with the options (the wrapper as `:server`, the catalog, `authorize`,
   `allowed_origins` the loopback origins, `tools_ttl_ms` and `tools_cache_scope` from config); the router
   mounts it at `POST /mcp` in a pipeline of its own (the `/mcp` page keeps GET). Tests: a wrong or absent
   bearer is 403 with nothing decoded; the right one reaches `server/discover`.
7. `mix trinity.mcp.stdio`: the wrapper under the core's stdio transport for a client that speaks stdio (a
   2025-11-25 client's route; Claude Code's common configuration), with the data-directory lock's rule
   stated: it is a second Trinity and needs the data directory to itself, so it runs when the desktop or
   the headless server does not.
8. Headless: a `headless` release in `mix.exs` (assemble only, no Burrito), `TRINITY_MODE=headless` in
   `config/runtime.exs` (the endpoint binds `TRINITY_BIND`, loopback by default, on `PORT`, 4000 by
   default; the server flag on), `ci/headless/Containerfile` (a builder stage on the Elixir image, a slim
   runtime stage), a systemd unit example in `docs/mcp-server.md`. Test AC6: the image built and run here
   with docker, no display, `server/discover` answered through the bearer; the log pasted.
9. Docs: `docs/mcp-server.md` (connecting Claude Code, Codex, goose and VS Code; the token; headless),
   docs/01 (the server under the boundary), docs/05 (the token file, the key file), docs/07 (the MRTR
   approval: what the envelope binds, what replay defence holds), docs/08 (the server row), README (the
   Connects bullet gains the server side; the pages list).
10. Gate, coverage, PROOF; the ROADMAP row.

Manual verification queue: **AC8**, Claude Code connected and calling `recall` (screenshot). The steps for
the owner are in `docs/mcp-server.md`; PROOF.md carries our own 060 client doing the same call as the
automatic half.

Not built here: Tasks (above), MCP Apps (the SLICE's follow-up), internet exposure, the OAuth resource
server (062; `Auth.Local` is a static bearer on a loopback bind), sampling or roots requests from the
server (never: the server asks the owner, not the client's model), the connectome surface.
