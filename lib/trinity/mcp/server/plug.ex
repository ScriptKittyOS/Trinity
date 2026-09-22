# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.Server.Plug do
  @moduledoc """
  The `/mcp` endpoint (slice 061): beam_mcp's Streamable HTTP transport with Trinity's options,
  mounted in the endpoint ahead of `Plug.Parsers` (the transport reads the raw body itself)
  and answering `POST /mcp` alone; every other request passes through to the router (the
  `/mcp` page keeps GET). The options: the wrapper as
  `:server`, `Trinity.MCP.Server.Catalog`, the profile's authorization (`Trinity.MCP.AuthHost`, slice 062) before the transport and its own hook reading what it left, the
  loopback origins (a request with no `Origin`, which every CLI client sends, is served; a
  browser page on another origin is refused), and `tools_ttl_ms` and `tools_cache_scope` from
  `config :trinity, :mcp_server`. This module exists so the router, in the web boundary, never
  names the core.
  """
  @behaviour Plug

  alias Trinity.MCP.AuthHost
  alias Trinity.MCP.Server.Catalog

  # Slice 062: the request's principal, set by this plug for the wrapper to read. The
  # transport dispatches in the request's own process, so the process dictionary is the
  # channel between the plug (which sees the connection) and the wrapper (which sees the
  # message); it is set after authorization and cleared with the process.
  @principal_key :trinity_mcp_principal

  @impl true
  def init(_opts) do
    config = Application.get_env(:trinity, :mcp_server, [])

    BeamMCP.Transport.HTTP.init(
      server: Trinity.MCP.Server,
      catalog: Catalog,
      dispatch: nil,
      # Slice 062: the profile's authorization runs in `call/2` before the transport, which
      # then finds the principal it left; the transport's own hook is that second look. A
      # remote capture and never an anonymous function: `Plug.Builder` calls `init/1` at
      # compile time in `:prod` and escapes what it returns into the endpoint, and a closure
      # cannot be escaped (`fix(s062)`: the release build was broken and the gate, which runs
      # in `:test` where `init/1` is called at runtime, could not see it).
      authorize: &__MODULE__.authorized/1,
      allowed_origins: Keyword.get(config, :allowed_origins, loopback_origins()),
      server_name: Keyword.get(config, :server_name, "trinity"),
      tools_ttl_ms: Keyword.get(config, :tools_ttl_ms, 60_000),
      tools_cache_scope: Keyword.get(config, :tools_cache_scope, "private")
    )
  end

  @impl true
  def call(%Plug.Conn{method: "POST", path_info: ["mcp"]} = conn, opts) do
    case AuthHost.authorize(conn) do
      {:ok, principal} ->
        Process.put(@principal_key, principal)
        conn |> BeamMCP.Transport.HTTP.call(opts) |> Plug.Conn.halt()

      {:error, _reason} ->
        # The reason went to the receipt and the log; the caller gets the challenge and
        # nothing decoded (the body is unread).
        conn
        |> Plug.Conn.put_resp_header("www-authenticate", AuthHost.challenge(AuthHost.config()))
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          401,
          ~s({"jsonrpc":"2.0","id":null,"error":{"code":-32001,"message":"Unauthorized"}})
        )
        |> Plug.Conn.halt()
    end
  end

  def call(conn, _opts), do: conn

  @doc """
  The transport's `:authorize` hook: the second look at what `call/2` decided. `call/2`
  authorizes the request and leaves the principal in this process before the transport runs, so
  a request that reaches the transport without one never passed the profile's check.
  """
  @spec authorized(Plug.Conn.t()) :: :ok | {:error, :unauthorized}
  def authorized(_conn) do
    if Process.get(@principal_key), do: :ok, else: {:error, :unauthorized}
  end

  @doc "The principal the plug left for the wrapper, in this process."
  @spec principal() :: Trinity.MCP.Auth.Principal.t() | nil
  def principal, do: Process.get(@principal_key)

  @doc "The origins a browser on this machine may present."
  @spec loopback_origins() :: [String.t()]
  def loopback_origins do
    for host <- ["localhost", "127.0.0.1", "[::1]"],
        scheme <- ["http", "https"],
        do: "#{scheme}://#{host}"
  end
end
