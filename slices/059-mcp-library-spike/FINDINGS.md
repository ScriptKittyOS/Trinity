# Slice 059: beam_mcp 0.8.0 against the 2026-07-28 checklist

Measured 2026-09-21 on a clone of `https://github.com/ScriptKittyOS/beam_mcp` at `v0.8.0`, whose commit is
`cfa706b` (`git rev-parse --short 'v0.8.0^{commit}'` → `cfa706b`, the sha ADR-0007 decision 5 names); hex.pm
lists 0.8.0 released 2026-09-19 under Apache-2.0 (`curl -s https://hex.pm/api/packages/beam_mcp`). Every path
and line below is at that commit; the column "derived by" is the command whose output the row restates. The
column "status" is one of: **ships** (the core does it), **carries** (the core puts it on the wire or in a
hook and Trinity does not read it yet), **refuses** (an entry of `docs/will-not-implement.md`, with its
number and the test that enforces it), **open** (neither built nor refused by name).

Two facts about the tree, first, so the rows can be short. The core is 25 files under `lib/`
(`find lib -name '*.ex' | wc -l` → 25); the public surface is `docs/public-api.txt` (142 lines, one per
function, callback or type). The whole suite at the pinned commit on the pinned toolchain (`.tool-versions`:
Erlang 28.1.1, Elixir 1.18.4-otp-28) is `mix test` → `11 properties, 705 tests, 0 failures`.

| # | Checklist item | Status | What the core does, with path and line | Derived by |
|---|---|---|---|---|
| 1 | Revision negotiation: `server/discover` for 2026-07-28, `initialize` for 2025-11-25, from one route | **ships**, dual-era on stdio; HTTP is 2026-07-28 only | `lib/beam_mcp/server.ex:238` matches `server/discover` before the revision switch and answers the full `DiscoverResult` (`supportedVersions` at :242); `:251` matches `initialize` (legacy opener); `params._meta` decides the era for every other request (README "What it speaks", `README.md:448-499`). Over HTTP `initialize`, `notifications/initialized` and `ping` are refused `404 -32601` (`lib/beam_mcp/transport/http.ex:196` `@removed_in_modern`) and `supportedVersions` is `["2026-07-28"]`. `2024-11-05` is refused with `-32022`. | `grep -n '"server/discover"\|"initialize"' lib/beam_mcp/server.ex`; `grep -n removed_in_modern lib/beam_mcp/transport/http.ex`; `sed -n 448,499p README.md` |
| 2 | Stateless Streamable HTTP as a Plug; `Mcp-Method` and `Mcp-Name` headers; no session identifier | **ships** | `lib/beam_mcp/transport/http.ex:164` `@behaviour Plug`, one POST endpoint, `MCP-Protocol-Version` required (README `:404-447`); `Mcp-Method` checked at `:1066-1068`, `Mcp-Name` at `:1076-1080`, `Mcp-Param-{Name}` enforced from `x-mcp-header`; every header checked in all its values. No session: `docs/will-not-implement.md` entry 7, `test/beam_mcp/boundary/no_session_test.exs`. The Plug exists only when `plug` is present (`:38-40`); `plug` and `bandit` are optional dependencies. | `grep -n '@behaviour Plug\|"mcp-method"\|"mcp-name"' lib/beam_mcp/transport/http.ex`; `sed -n 404,447p README.md` |
| 3 | stdio transport | **ships** | `lib/beam_mcp/transport/stdio.ex:44` `run/1` blocks the caller on newline-delimited JSON-RPC, options are `Server.new/1`'s (`:27`), dual-era (row 1); `:60` stops on `shutdown?/1`. | `grep -n 'def run\|Server\.' lib/beam_mcp/transport/stdio.ex` |
| 4 | tools: `tools/list`, `tools/call`, deterministic order, schema validation | **ships**, with one edge | `lib/beam_mcp/server.ex:361` `tools/list` (paginated through `BeamMCP.Cursor`, `lib/beam_mcp/cursor.ex:82` `page/5`), `:463` `tools/call`; arguments validated by `BeamMCP.Schema.validate/2` (`lib/beam_mcp/schema.ex:33`) at `server.ex:618` and `:848`, an invalid call answered `"invalid arguments: …"` (`:620`) and never dispatched. **Order:** resources are sorted by `uri` (`lib/beam_mcp/catalog.ex:159`), templates by `uri_template` (`:170`), prompts by `name` (`:229`); **tools keep the catalog's own order** (`catalog.ex:150` `def tools(catalog), do: catalog.capabilities().tools`), so determinism of `tools/list` is the host's: Trinity's catalog (061) sorts before it hands the list over. | `grep -n 'sort' lib/beam_mcp/catalog.ex`; `grep -n 'Schema.validate' lib/beam_mcp/server.ex` |
| 5 | resources: `resources/list`, `resources/read`, templates, subscriptions | **ships** list, read and templates; **refuses** subscriptions by capability, not by entry | `lib/beam_mcp/server.ex:379` `resources/list`, `:423` `resources/templates/list`, `:441` `resources/read` (only a uri the catalog listed or a template matches: `docs/will-not-implement.md` entry 11); capabilities at `:83-85` advertise `"resources" => %{"listChanged" => false, "subscribe" => false}`: no subscriptions and no notifications, "the server sends no notifications" (`:80-81`). The conformance row's five skipped checks are these (README `:500-539`). Not on the will-not-implement page: a subscription would be a capability the schema defines, so the README answers it, not entry 6. | `sed -n 76,86p lib/beam_mcp/server.ex`; `grep -n '"resources/' lib/beam_mcp/server.ex` |
| 6 | prompts: `prompts/list`, `prompts/get` | **ships** | `lib/beam_mcp/server.ex:390` `prompts/list`, `:406` `prompts/get` with `params`, `:417` without (refused); the catalog's `get_prompt/2` is called only after the prompt is listed and the arguments validated (`docs/will-not-implement.md` entry 11); `BeamMCP.PromptSpec.argument_schema/1` derives the schema (`docs/public-api.txt`). | `grep -n '"prompts/' lib/beam_mcp/server.ex` |
| 7 | `ttlMs` and `cacheScope` on every cacheable result | **carries**: the values are the host's | `lib/beam_mcp/server.ex:170-172` (the two are "neither the package's to invent"): `tools/list` writes `state.tools_ttl_ms` and `state.tools_cache_scope` (`:371-372`), lists write theirs (`:516`, `:565-566`), options `tools_ttl_ms` (a non-negative integer) and `tools_cache_scope` (a string) validated in `Server.new/1` (`:127-128`); `server/discover` writes `ttlMs` 0 and `cacheScope` `"private"` (`:244-245`). Trinity's 061 sets the two options; nothing in Trinity reads them today. | `grep -n 'ttlMs\|cacheScope\|tools_ttl_ms' lib/beam_mcp/server.ex` |
| 8 | `resultType` on every result, including `server/discover` | **ships**, `"complete"` only | `lib/beam_mcp/server.ex:965-981`: every 2026-07-28 result gets `"resultType" => "complete"` and `_meta.serverInfo` at one site; `server/discover`'s result carries `resultType` (`:233-245`); legacy results carry neither (`:319`). The one value is pinned by `test/beam_mcp/boundary/no_mrtr_test.exs` "the only resultType written under lib/ is complete, at one site". | `grep -n resultType lib/beam_mcp/server.ex` |
| 9 | MRTR: `input_required`, `requestState`, `inputResponses` | **refuses**: entry 12 | `docs/will-not-implement.md` entry 12: the core answers every request completely or refuses it; `lib/beam_mcp/server.ex:34-36` (the moduledoc says so); `inputResponses` and `requestState` are read nowhere, a request carrying them is served as if it carried neither (`test/beam_mcp/mrtr_wire_test.exs` "on the core, at both eras, the answer with the continuation parameters is the bare answer"; enforced by `test/beam_mcp/boundary/no_mrtr_test.exs`). See conflict A below. | `grep -n 'inputResponses\|requestState\|InputRequired' lib/beam_mcp/server.ex docs/will-not-implement.md` |
| 10 | Tasks extension | **open**: neither built nor refused | No line under `lib/` names `tasks` (`grep -rn '"tasks"\|Tasks' lib/` → nothing); the capability key is known to the census only as a key the 2025-11-25 schema defines and 2026-07-28 drops for `extensions` (`test/beam_mcp/boundary/no_invented_capability_test.exs:11,19-20,37`); `extensions` is an open object nothing is read under (`docs/will-not-implement.md` entry 6). Not on the will-not-implement page, so a Tasks extension is a request the core's owner has not answered; Trinity's 060 treats it as absent on the server side and does not build a client for it. | `grep -rn '"tasks"\|Tasks' lib/ README.md`; `sed -n 9,40p test/beam_mcp/boundary/no_invented_capability_test.exs` |
| 11 | OAuth resource server hooks: what `:authorize` and `:authorize_body` give a host and what they do not | **carries** the hooks; **refuses** OAuth itself: entry 8 | `lib/beam_mcp/transport/http.ex:52`: `:authorize` is `(Plug.Conn.t() -> :ok \| {:error, term()})`, required, no default, called before the body is read (the reason goes to the log, never to the caller); `:61-69`: `:authorize_body` is `(Plug.Conn.t(), binary() -> :ok \| {:error, term()})`, optional, after the body; `:allowed_origins` required (`:55-58`). The `authorization` header is not read under `lib/` and reaches the hook untouched (`docs/will-not-implement.md` entry 8; `test/beam_mcp/boundary/no_oauth_no_client_test.exs` "no OAuth under lib/"); the transport performs no cryptography (entries 2 and 3). What a host gets: the conn (headers, the bearer among them) and the body; what it does not get: token parsing, PRM discovery, a token endpoint, anything on the response. See conflict B. | `sed -n 44,130p lib/beam_mcp/transport/http.ex` |
| 12 | Client role | **refuses**: entry 9 | `docs/will-not-implement.md` entry 9: no client module, no outbound connection, `initialize` only ever received; enforced by `test/beam_mcp/boundary/no_oauth_no_client_test.exs` "no client under lib/…" and `package_reach_test.exs` "the modules the package calls are exactly the listed ones" (no `gen_tcp`, `ssl`, `httpc`, `inets`, `Port`, `File`, no HTTP client). The public decoders a client may call from outside: `BeamMCP.JSON.decode/1`, `max_depth/0`, `type_of/1`; `BeamMCP.Schema.validate/2`; `BeamMCP.Cursor.decode/2` (`docs/public-api.txt`). See conflict B. | `grep -n '^BeamMCP.JSON\|^BeamMCP.Schema\|^BeamMCP.Cursor' docs/public-api.txt` |
| 13 | `connectome://` resources and the `:observe` tool | **ships**, opt-in by the host | `lib/beam_mcp/connectome/surface.ex:6`: three read-only resources (`connectome://declared`, `connectome://observed`, `connectome://diff`, `:32-34`) and one tool with `command_class: :observe` (`:19`), which a host puts in its catalog or does not; the observed graph carries edge identity only, never a payload byte (`docs/will-not-implement.md` entry 5). Whether Trinity exports them is a 061 G1 decision, default off (SLICE.md). | `grep -n 'connectome://\|:observe' lib/beam_mcp/connectome/surface.ex` |
| 14 | Telemetry events the core emits around dispatch, by name and metadata shape | **ships** | One site, `lib/beam_mcp/server.ex:859-899`: `[:beam_mcp, :dispatch, :start]` with measurements `%{system_time, monotonic_time}` and metadata `%{server_name, tool, telemetry_span_context}`; `[:beam_mcp, :dispatch, :stop]` with `%{duration, monotonic_time}` and the metadata plus `outcome`; `[:beam_mcp, :dispatch, :exception]` with `%{duration, monotonic_time}` and the metadata plus `kind`, `reason` (the host's, verbatim) and `stacktrace` (frames with arities, never argument lists, `BeamMCP.Stacktrace.arities/1`). No arguments, results or headers in any event (`lib/beam_mcp/connectome/observed.ex:13,47`; entry 5). `Trinity.MCP.core_events/0` lists the three for slice 090's catalogue. | `sed -n 859,899p lib/beam_mcp/server.ex` |
| 15 | The signer seam: `BeamMCP.Signer`, `Canonical.signature/3`, and whether a verifier of exported bytes can read the algorithm without the signer module | **ships**; the algorithm is in the bytes | `lib/beam_mcp/signer.ex:31`: one callback, `sign(canonical_bytes :: binary(), opts :: keyword()) :: {:ok, binary()} \| {:error, term()}`; `lib/beam_mcp/signer/none.ex` the no-op; `lib/beam_mcp/connectome/canonical.ex:311` `signature/3` encodes the graph with `:algorithm` from opts (`:sha256` default, `:sha384`, `:sha512`: `:52-55`), hands the bytes and the whole opts to the signer, and returns `%{algorithm, signature, signer}`; the canonical bytes themselves name the digest algorithm (`canonical.ex:27-40` "The algorithm is in the bytes": `schema_version`, `algorithm`, `nodes`, …), so a verifier holding the exported bytes reads the *digest* algorithm without the signer. The *signature* algorithm (Ed25519 in `beam_mcp_signer`) is the signer's and is not in the bytes: a verifier needs the signer's public key and knows the primitive from the `signer` module name in the map. The core holds no key and calls no signing primitive (entries 2 and 3). | `sed -n 20,35p lib/beam_mcp/signer.ex`; `sed -n 300,335p lib/beam_mcp/connectome/canonical.ex`; `sed -n 27,60p lib/beam_mcp/connectome/canonical.ex` |

## The two conflicts, against the slice lines they collide with

**A. Entry 12 (no MRTR) against 061's `input_required` criteria.** `docs/will-not-implement.md` entry 12
refuses the multi-round-trip request in the core: the one `resultType` is `"complete"`, and `inputResponses`
and `requestState` are never read (row 9). Slice 061's SLICE.md asks for an MRTR approval loop on the server
("MRTR approvals", the acceptance criteria that answer `tools/call` with `input_required` and finish on the
second request). The two do not meet in the core. ADR-0007 decision 6 already places the loop above the core,
in a sibling wrapper that decodes nothing, with the `requestState` envelope minted and validated by Trinity,
and names the seam that wrapper needs: a `:server` module option on `BeamMCP.Transport.HTTP`. The probe below
measures that seam. The conflict stands as stated in the ADR; 061 builds against it.

**B. Entries 9 (no client) and 8 (no OAuth) against 060 and 062.** Entry 9 (row 12) refuses a client in the
core; 060's SLICE.md builds "Trinity's thin driver" and decision 7 says it "builds the outbound JSON-RPC request
and nothing else of the protocol; decoding and validation call beam_mcp's public functions". The public
functions a client can call are `BeamMCP.JSON.decode/1`, `BeamMCP.Schema.validate/2` and `BeamMCP.Cursor.decode/2`
(row 12); `BeamMCP.Server.handle_message/2` is server-side and the driver must not lean on it. Entry 8 (row 11)
refuses OAuth in the core and gives the host two hooks; 062's resource server, embedded authorization server and
client role are Trinity's (decision 8), and the resource-server half attaches through `:authorize` (the bearer
is in the conn's headers, unread by the core) and `:authorize_body` where the body is part of the decision. The
conflict is the layering the ADR chose; it is stated here so 060 and 062 do not discover it as a gap.

## The seam probe

On a throwaway branch `probe/server-option` of the local clone at `cfa706b`, never pushed, deleted at the end
(`git branch -D probe/server-option` → `Deleted branch probe/server-option (was cfa706b)`): a `:server` module
option on `BeamMCP.Transport.HTTP`, default `BeamMCP.Server`. The whole diff, `git diff` →
`1 file changed, 3 insertions(+), 2 deletions(-)` (five changed lines; the diff is in PROOF.md):

- `@plug_opts` gains `:server` (`lib/beam_mcp/transport/http.ex:201`), so it is the Plug's option and not
  passed on to `Server.new/1`;
- `init/1`'s map gains `server: Keyword.get(opts, :server, Server)` (`:304`);
- `do_dispatch/3` calls `opts.server.handle_message(opts.server.new(opts.server_opts), message)` in place of
  `Server.handle_message(Server.new(opts.server_opts), message)` (`:1597`).

The census tests it touches, `mix test test/beam_mcp/boundary test/beam_mcp/transport` at the pinned commit
before (`180 tests, 0 failures`) and on the probe (`180 tests, 1 failure`), and the whole suite on the probe
(`11 properties, 705 tests, 1 failure`): exactly one, `test/beam_mcp/boundary/no_catalog_test.exs:102` "the
catalog is called through three callees: capabilities/0 at five sites, read_resource/1 at one, get_prompt/2 at
one", which pins every call through a runtime module with parentheses and would gain two entries,
`{{BeamMCP.Transport.HTTP, :do_dispatch, 3}, :handle_message, 2}` and `{…, :new, 1}`. No other census moves:
not the reach census (no new module is called: the default is the same `BeamMCP.Server`), not the no-session,
no-MRTR or no-OAuth censuses, not the public-API census (the option is not a function). The seam is therefore
five lines and one pinned list widened by two named entries, with the entry's own prose already allowing for
"a call through a runtime module with parentheses" as the shape it pins. That is beam_mcp's to add (ADR-0007
decision 6); this slice records the size and asks for nothing from here.

## What changes for 060 to 062

Nothing in the rows above changes the shape of 060 to 062 as ADR-0007 decisions 5 to 8 record them, so no
amendment is proposed. Two facts are new and go into their G1 plans: `tools/list`'s order is the host's (row
4: Trinity's catalog sorts), and the Tasks extension is open in the core (row 10: 060's driver does not build a
client for it, 061 does not advertise it).
