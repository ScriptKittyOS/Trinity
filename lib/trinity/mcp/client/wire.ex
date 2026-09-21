# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.Client.Wire do
  @moduledoc """
  The outbound request object, and nothing else of the protocol (slice 060, the thin-driver
  rule, ADR-0007 decision 7). This module builds the JSON-RPC request the driver sends at
  either revision, the HTTP headers the 2026-07-28 transport requires beside it, and calls
  the core's public functions to decode what comes back (`BeamMCP.JSON.decode/1`) and to
  validate arguments against the schema a server listed (`BeamMCP.Schema.validate/2`).
  Revision handling is the two openers, `server/discover` and `initialize`, and the
  `_meta` every later request carries; there is no negotiation, envelope vocabulary or
  schema validator of Trinity's own here, and the census (AC7) holds that.
  """

  @modern "2026-07-28"
  @legacy "2025-11-25"
  @version_key "io.modelcontextprotocol/protocolVersion"
  @capabilities_key "io.modelcontextprotocol/clientCapabilities"

  @type revision :: String.t()
  @type request :: %{required(String.t()) => term()}

  @doc "The revision the driver prefers, and the one it falls back to."
  @spec modern() :: revision()
  def modern, do: @modern
  @spec legacy() :: revision()
  def legacy, do: @legacy

  # What the driver can fulfil of a multi-round-trip result: a form elicitation, answered by
  # the owner through an approval (docs/07). Sampling and roots are not declared, so a
  # server may not ask for them (the revision's MRTR page: only requests the client declared).
  @client_capabilities %{"elicitation" => %{"form" => %{}}}

  @doc "The client's `_meta` at a revision: the version, and at 2026-07-28 the client capabilities beside it."
  @spec meta(revision()) :: map()
  def meta(@modern), do: %{@version_key => @modern, @capabilities_key => @client_capabilities}
  def meta(@legacy), do: %{@version_key => @legacy}

  @doc """
  The 2026-07-28 opener. It carries the modern `_meta`, because the HTTP transport requires
  a version on every POST; a dual-era server answers it whatever the `_meta` says, and a
  legacy-only one refuses it (`-32601`, or `-32022` naming what it supports), which is the
  driver's cue to `initialize`.
  """
  @spec discover(term()) :: request()
  def discover(id), do: at(id, "server/discover", %{}, @modern)

  @doc "The 2025-11-25 opener, naming the revision and the client."
  @spec initialize(term(), map()) :: request()
  def initialize(id, client_info) do
    request(id, "initialize", %{
      "protocolVersion" => @legacy,
      "capabilities" => %{},
      "clientInfo" => client_info
    })
  end

  @doc "The notification that follows a 2025-11-25 `initialize`."
  @spec initialized() :: request()
  def initialized, do: %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}

  @doc "A request at a revision: the method, the params, and the `_meta` the revision requires."
  @spec at(term(), String.t(), map(), revision()) :: request()
  def at(id, method, params, revision) when is_map(params) do
    request(id, method, Map.put(params, "_meta", meta(revision)))
  end

  @doc "A `tools/list` at a revision, with the cursor when there is one."
  @spec tools_list(term(), revision(), String.t() | nil) :: request()
  def tools_list(id, revision, cursor \\ nil) do
    params = if cursor, do: %{"cursor" => cursor}, else: %{}
    at(id, "tools/list", params, revision)
  end

  @doc """
  A `tools/call`. With `continuation:` (`responses`, the `inputResponses` map keyed as the
  server's `inputRequests` were, and `state`, the server's `requestState` carried as the
  term it arrived as and never rebuilt; `nil` when the server sent none) the request is the
  multi-round-trip retry of an earlier call, under its own new id.
  """
  @spec tools_call(term(), String.t(), map(), revision(), keyword()) :: request()
  def tools_call(id, name, arguments, revision, opts \\ []) do
    params = %{"name" => name, "arguments" => arguments}

    params =
      case Keyword.get(opts, :continuation) do
        nil ->
          params

        %{responses: responses, state: nil} ->
          Map.put(params, "inputResponses", responses)

        %{responses: responses, state: state} ->
          params
          |> Map.put("inputResponses", responses)
          |> Map.put("requestState", state)
      end

    at(id, "tools/call", params, revision)
  end

  @doc "The `ping` the legacy revision keeps."
  @spec ping(term()) :: request()
  def ping(id), do: at(id, "ping", %{}, @legacy)

  defp request(id, method, params),
    do: %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

  @doc """
  The headers a 2026-07-28 request carries over HTTP beside the body: the protocol version,
  `Mcp-Method`, `Mcp-Name` for the methods that name a tool, resource or prompt, and
  `Mcp-Param-{Name}` for every argument the listed schema annotates `x-mcp-header`
  (`schemas` maps a tool name to its listed `inputSchema`). A value outside the printable
  ASCII range, or one with an edge space, travels in the `=?base64?…?=` sentinel the
  transport decodes.
  """
  @spec headers(request(), %{optional(String.t()) => map()}) :: [{String.t(), String.t()}]
  def headers(%{"method" => method} = request, schemas) do
    [{"mcp-protocol-version", @modern}, {"mcp-method", method}] ++
      name_header(request) ++ param_headers(request, schemas)
  end

  defp name_header(%{"method" => "tools/call", "params" => %{"name" => name}}),
    do: [{"mcp-name", header_value(name)}]

  defp name_header(%{"method" => "prompts/get", "params" => %{"name" => name}}),
    do: [{"mcp-name", header_value(name)}]

  defp name_header(%{"method" => "resources/read", "params" => %{"uri" => uri}}),
    do: [{"mcp-name", header_value(uri)}]

  defp name_header(_), do: []

  defp param_headers(%{"method" => "tools/call", "params" => %{"name" => name} = params}, schemas) do
    arguments = Map.get(params, "arguments", %{})

    schemas
    |> Map.get(name, %{})
    |> annotations([])
    |> Enum.flat_map(fn {header, path} ->
      case get_in(arguments, path) do
        nil -> []
        value -> [{"mcp-param-" <> String.downcase(header), header_value(value)}]
      end
    end)
  end

  defp param_headers(_request, _schemas), do: []

  # The annotation walk the transport does on the server side, mirrored: through `properties`
  # only, never through items, oneOf, anyOf, allOf, not, if/then/else or $ref.
  defp annotations(%{"properties" => properties}, path) when is_map(properties) do
    Enum.flat_map(properties, fn {key, sub} ->
      here =
        case is_map(sub) and sub["x-mcp-header"] do
          header when is_binary(header) and header != "" -> [{header, path ++ [key]}]
          _ -> []
        end

      here ++ annotations(sub, path ++ [key])
    end)
  end

  defp annotations(_schema, _path), do: []

  defp header_value(true), do: "true"
  defp header_value(false), do: "false"
  defp header_value(n) when is_integer(n), do: Integer.to_string(n)
  defp header_value(n) when is_float(n), do: Float.to_string(n)

  defp header_value(s) when is_binary(s) do
    if Regex.match?(~r/\A[\x21-\x7e]([\x20-\x7e]*[\x21-\x7e])?\z/, s),
      do: s,
      else: "=?base64?" <> Base.encode64(s) <> "?="
  end

  defp header_value(other), do: header_value(Jason.encode!(other))

  @doc "Decodes a server's bytes through the core's decoder (depth-bounded, duplicate keys refused)."
  @spec decode(binary()) :: {:ok, term()} | {:error, term()}
  def decode(bytes) when is_binary(bytes), do: BeamMCP.JSON.decode(bytes)

  @doc "Validates a call's arguments against the schema the server listed, through the core's validator."
  @spec validate_arguments(map(), map()) :: :ok | {:error, String.t()}
  def validate_arguments(arguments, schema), do: BeamMCP.Schema.validate(arguments, schema)

  @doc "Encodes the outbound request as one line of JSON."
  @spec encode(request()) :: binary()
  def encode(request), do: Jason.encode!(request)
end
