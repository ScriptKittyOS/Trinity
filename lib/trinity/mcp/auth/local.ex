# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.Auth.Local do
  @moduledoc """
  The default profile (slice 061's static bearer, moved behind the behaviour at 062): the
  token from the configured environment variable, else the token file the host names
  (`Config.token_path`, generated once, mode 0600), compared in constant time before the body
  is read. The principal it admits is the local owner: no issuer, subject `owner`, every scope.
  Not an authorization server, and no JWT anywhere.
  """
  @behaviour Trinity.MCP.Auth

  alias Trinity.MCP.Auth
  alias Trinity.MCP.Auth.{Config, Principal, Scopes}

  @impl true
  def authorize(conn, %Config{} = config) do
    expected = token(config)

    with {:ok, given} <- Auth.bearer(conn) do
      if byte_size(given) == byte_size(expected) and :crypto.hash_equals(given, expected),
        do: {:ok, %Principal{sub: "owner", scope: Scopes.known(), profile: :local}},
        else: {:error, :wrong_bearer}
    end
  end

  @impl true
  def resource_metadata(_config), do: nil

  @doc "The token in force: the environment variable, else the file's."
  @spec token(Config.t()) :: String.t()
  def token(%Config{token_env: env, token_path: path}) do
    case env && System.get_env(env) do
      t when is_binary(t) and t != "" -> t
      _ -> File.read!(ensure_token!(path)) |> String.trim()
    end
  end

  @doc "Generates the token file when absent (mode 0600); returns its path."
  @spec ensure_token!(Path.t()) :: Path.t()
  def ensure_token!(path) when is_binary(path) do
    unless File.exists?(path) do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false) <> "\n")
      File.chmod!(path, 0o600)
    end

    path
  end
end
