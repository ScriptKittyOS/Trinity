# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.Server.Plug do
  @moduledoc """
  The `/mcp` endpoint (slice 061): beam_mcp's Streamable HTTP transport with Trinity's options,
  mounted in the endpoint ahead of `Plug.Parsers` (the transport reads the raw body itself)
  and answering `POST /mcp` alone; every other request passes through to the router (the
  `/mcp` page keeps GET). The options: the wrapper as
  `:server`, `Trinity.MCP.Server.Catalog`, `Trinity.MCP.Server.Auth.Local` as `:authorize`, the
  loopback origins (a request with no `Origin`, which every CLI client sends, is served; a
  browser page on another origin is refused), and `tools_ttl_ms` and `tools_cache_scope` from
  `config :trinity, :mcp_server`. This module exists so the router, in the web boundary, never
  names the core.
  """
  @behaviour Plug

  alias Trinity.MCP.Server.{Auth, Catalog}

  @impl true
  def init(_opts) do
    config = Application.get_env(:trinity, :mcp_server, [])

    BeamMCP.Transport.HTTP.init(
      server: Trinity.MCP.Server,
      catalog: Catalog,
      dispatch: nil,
      authorize: &Auth.Local.authorize/1,
      allowed_origins: Keyword.get(config, :allowed_origins, loopback_origins()),
      server_name: Keyword.get(config, :server_name, "trinity"),
      tools_ttl_ms: Keyword.get(config, :tools_ttl_ms, 60_000),
      tools_cache_scope: Keyword.get(config, :tools_cache_scope, "private")
    )
  end

  @impl true
  def call(%Plug.Conn{method: "POST", path_info: ["mcp"]} = conn, opts),
    do: conn |> BeamMCP.Transport.HTTP.call(opts) |> Plug.Conn.halt()

  def call(conn, _opts), do: conn

  @doc "The origins a browser on this machine may present."
  @spec loopback_origins() :: [String.t()]
  def loopback_origins do
    for host <- ["localhost", "127.0.0.1", "[::1]"],
        scheme <- ["http", "https"],
        do: "#{scheme}://#{host}"
  end
end
