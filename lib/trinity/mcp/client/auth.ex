# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.Client.Auth do
  @moduledoc """
  Where the driver gets a bearer token for a protected server (slice 060; slice 062 fills the
  seam): the token the client role obtained for the server's URL (`Trinity.MCP.Auth.Client`,
  through the host), else a static value in the environment variable `TRINITY_MCP_<NAME>_TOKEN`
  (the server's name upcased, `-` as `_`), read at connect and never stored. Nothing here
  performs an OAuth flow: a `401` with a challenge is recorded on the client for the `/mcp`
  page, where the owner starts the flow.
  """

  alias Trinity.MCP.ServerConfig

  @doc "The bearer for a server, or nil: the token the client role obtained for its URL (slice 062), else the environment variable's."
  @spec bearer(ServerConfig.t()) :: String.t() | nil
  def bearer(%ServerConfig{name: name, url: url}) do
    case url && Trinity.MCP.AuthHost.client_bearer(url) do
      token when is_binary(token) ->
        token

      _ ->
        case System.get_env(variable(name)) do
          nil -> nil
          "" -> nil
          token -> token
        end
    end
  end

  @doc "The environment variable a server's token is read from."
  @spec variable(String.t()) :: String.t()
  def variable(name),
    do: "TRINITY_MCP_" <> String.upcase(String.replace(name, "-", "_")) <> "_TOKEN"
end
