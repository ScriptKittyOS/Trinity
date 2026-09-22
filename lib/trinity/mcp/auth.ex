# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.Auth do
  @moduledoc """
  Who is calling Trinity's MCP server, and with what scopes (slice 062; ADR-0008 decision 4:
  identity is not authority). A profile implements this behaviour: `Local` (061's static bearer,
  the default), `External` (the production profile: a resource server against an external
  authorization server; Trinity issues nothing), `Embedded` (the personal profile: the same
  resource server plus a small authorization server on the owner's machine, refused where an
  external authority adapter is in force). `authorize/2` answers with a `Principal` and never
  with the token, so nothing past this boundary holds token material; the caller (the plug, the
  server) receipts the decision, since this boundary writes no receipt and reads no session:
  `deps: []` on the tree, which is what lets slice 123 extract it.
  """
  use Boundary,
    deps: [],
    exports: [
      Config,
      Principal,
      Token,
      Discovery,
      JWKS,
      Scopes,
      Local,
      External,
      Embedded,
      Embedded.Keys,
      Client,
      Client.Store
    ]

  alias Trinity.MCP.Auth.{Config, Principal}

  @doc "Authorizes a request under the profile: the principal, or why not (never the token)."
  @callback authorize(Plug.Conn.t(), Config.t()) :: {:ok, Principal.t()} | {:error, term()}

  @doc "The RFC 9728 Protected Resource Metadata this profile publishes, or nil when it publishes none."
  @callback resource_metadata(Config.t()) :: map() | nil

  @doc "The profile module for a configuration."
  @spec impl(Config.t()) :: module()
  def impl(%Config{profile: :local}), do: Trinity.MCP.Auth.Local
  def impl(%Config{profile: :production}), do: Trinity.MCP.Auth.External
  def impl(%Config{profile: :personal}), do: Trinity.MCP.Auth.Embedded

  @doc "Authorizes through the configuration's profile."
  @spec authorize(Plug.Conn.t(), Config.t()) :: {:ok, Principal.t()} | {:error, term()}
  def authorize(conn, %Config{} = config), do: impl(config).authorize(conn, config)

  @doc "The bearer from a request's `Authorization` header, or why not. The one reader of that header."
  @spec bearer(Plug.Conn.t()) ::
          {:ok, String.t()} | {:error, :no_bearer | :malformed_authorization}
  def bearer(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token] when byte_size(token) > 0 -> {:ok, token}
      [] -> {:error, :no_bearer}
      _ -> {:error, :malformed_authorization}
    end
  end
end
