# Trinity as an MCP server

Trinity serves the Model Context Protocol at the 2026-07-28 revision on `POST /mcp`, and at
both 2026-07-28 and 2025-11-25 over stdio. A client that connects sees the tools you chose to
export (the read-only set by default), calls them through the same permission gate and the same
membrane as the assistant's own calls, and gets an audited answer: every call leaves a receipt on
the "MCP server" session's chain with `origin: "mcp"`. A tool that needs your approval does not run
until you give it, on the permissions page; the client is told to retry once you have.

## What is exported

`config :trinity, :mcp_server, tools: [...]` names the tools; the default set is `recall`,
`session_search`, `skills_list`, `skill_view` and `skill_file`, all reads. An `:artifact` tool
(`memory`, `skill_manage`, `learn`, the filesystem writes) is exported when you name it, and every
call to it asks you first. A tool whose effect is `:catalog` (the shell) cannot be exported: the
configuration is refused at boot with a logged reason, and the tool never appears in
`tools/list`. The list is sorted, and it carries `ttlMs` (60 s by default) and `cacheScope`
(`private`).

Two files the server keeps in the data directory: `mcp-server-token`, the bearer clients present
(generated once, mode 0600; `TRINITY_MCP_SERVER_TOKEN` overrides it), and `keys/mcp-state.key`, the
key that seals the state a held call carries between round trips (docs/07, "MCP server").

## Connecting a client over HTTP

The URL is `http://127.0.0.1:<port>/mcp` (the port the app prints at start, `4000` in the headless
profile) and the bearer is the token above:

```
$ cat ~/.local/share/trinity/mcp-server-token        # Linux; the data directory differs per OS
```

**Claude Code** (its `mcp add` command, or `.mcp.json` in a project):

```
claude mcp add --transport http trinity http://127.0.0.1:4000/mcp \
  --header "Authorization: Bearer <token>"
```

```json
{
  "mcpServers": {
    "trinity": {
      "type": "http",
      "url": "http://127.0.0.1:4000/mcp",
      "headers": { "Authorization": "Bearer <token>" }
    }
  }
}
```

**VS Code** (`.vscode/mcp.json`, or the user-level `mcp.json`):

```json
{
  "servers": {
    "trinity": {
      "type": "http",
      "url": "http://127.0.0.1:4000/mcp",
      "headers": { "Authorization": "Bearer <token>" }
    }
  }
}
```

**Codex** (`~/.codex/config.toml`, or `.codex/config.toml` in a trusted project):

```toml
[mcp_servers.trinity]
url = "http://127.0.0.1:4000/mcp"
bearer_token_env_var = "TRINITY_MCP_SERVER_TOKEN"
```

**goose**: `goose configure`, then Add Extension, Remote Extension (Streaming HTTP), the URL above,
and the `Authorization` header when it asks for headers.

The shapes above are each client's as its documentation showed them on 2026-09-22; the file
locations differ per operating system, and the clients change. What does not change on Trinity's
side is the URL, the `Authorization: Bearer` header and the revision.

## Connecting a client over stdio

For a client that launches its servers as child processes, and for a 2025-11-25 client (the HTTP
transport serves 2026-07-28 alone, by the core's design):

```
claude mcp add --transport stdio trinity -- mix trinity.mcp.stdio
```

run from the Trinity source tree (compile first: a `mix compile` line on standard output would be
an undecodable message to the client), or `bin/headless eval 'Trinity.MCP.Server.Stdio.serve()'`
from the headless release. This is a whole Trinity, and a data directory admits one at a time: run
it when the desktop or the headless server does not, or give it its own data directory with
`XDG_DATA_HOME` (Linux). The VM's log goes to standard error; standard output is the wire.

## Approvals over the wire

When a client calls a tool that needs your approval, the answer is not the result but an
`input_required` result (the 2026-07-28 multi-round-trip pattern): one elicitation request naming
the approval and this page, and an opaque `requestState`. You decide on `/permissions`, where the
request appears under the "MCP server" session like any other; the client retries the same call
with the same `requestState`, and the retry runs (once, under the decision you made) or reports the
denial. A retry before you have decided is held again, with a fresh state; a retry with the state
altered, expired (15 minutes by default, `state_ttl_s`), replayed or taken from another call is
refused, and the reason names only which of those it was. A 2025-11-25 client, whose revision has
no `input_required`, is told the same in a tool error and retries the same way.

The state is what makes the headless profile stateless: it carries everything a retry needs, sealed
under the data directory's key, so a call held by one instance completes on any other instance of
the same data directory (docs/07 says what it binds and what the replay defence holds).

## The headless profile

`mix release headless` assembles the tree as an ordinary OTP release: no desktop shell, no
self-extracting binary. `TRINITY_MODE=headless` makes it a server: it binds `TRINITY_BIND` (the
loopback by default; a LAN address is your decision, made by setting it) on `PORT` (4000 by default)
and serves the web pages and `/mcp`. The bearer is required on `/mcp` whatever the bind; the web
pages carry no authentication yet, which is why the default bind is the loopback and why a LAN bind
belongs behind a reverse proxy that authenticates.

A container: `ci/headless/Containerfile` builds the release on the Elixir image whose toolchain is
the tree's and runs it on a slim Debian, the data directory on the `/data` volume:

```
docker build -f ci/headless/Containerfile -t trinity-headless:local .
docker run --rm -p 4000:4000 -v trinity-data:/data \
  -e TRINITY_MCP_SERVER_TOKEN=<token> trinity-headless:local
```

A systemd unit for the release on a host:

```ini
[Unit]
Description=Trinity (headless)
After=network-online.target

[Service]
User=trinity
Environment=TRINITY_MODE=headless
Environment=PORT=4000
Environment=SECRET_KEY_BASE=<64 random bytes, base64>
Environment=TRINITY_MCP_SERVER_TOKEN=<token>
EnvironmentFile=-/etc/trinity/env
ExecStart=/opt/trinity/bin/headless start
ExecStop=/opt/trinity/bin/headless stop
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

`SECRET_KEY_BASE` is worth setting on a server: the fallback is generated per boot and signed
cookies do not survive a restart without it (config/runtime.exs says why that is the default).
