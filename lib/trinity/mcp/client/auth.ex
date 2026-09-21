# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.Client.Auth do
  @moduledoc """
  Where the driver gets a bearer token for a protected server (slice 060). This is slice
  062's seam: at this slice a token is a static value in the environment variable
  `TRINITY_MCP_<NAME>_TOKEN` (the server's name upcased, `-` as `_`), read at connect and
  never stored; 062's client role replaces this module's body with the token it obtained
  and answers the `401` the transport reports. Nothing here performs an OAuth flow.
  """

  alias Trinity.MCP.ServerConfig

  @doc "The bearer for a server, or nil."
  @spec bearer(ServerConfig.t()) :: String.t() | nil
  def bearer(%ServerConfig{name: name}) do
    case System.get_env(variable(name)) do
      nil -> nil
      "" -> nil
      token -> token
    end
  end

  @doc "The environment variable a server's token is read from."
  @spec variable(String.t()) :: String.t()
  def variable(name),
    do: "TRINITY_MCP_" <> String.upcase(String.replace(name, "-", "_")) <> "_TOKEN"
end
