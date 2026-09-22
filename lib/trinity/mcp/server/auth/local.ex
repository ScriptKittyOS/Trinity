# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.Server.Auth.Local do
  @moduledoc """
  The default `:authorize` hook of Trinity's MCP server (slice 061): a static bearer, compared
  in constant time, before the body is read. The token is `TRINITY_MCP_SERVER_TOKEN` when
  set; otherwise one generated at boot into `<data dir>/mcp-server-token` (mode 0600), which
  the owner copies into a client's configuration. The full OAuth 2.1 resource-server profile
  is slice 062's; this module is what stands until then, beside the loopback bind the
  headless profile defaults to.
  """
  import Plug.Conn, only: [get_req_header: 2]

  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @env "TRINITY_MCP_SERVER_TOKEN"
  @token_file "mcp-server-token"

  @doc "The hook: `:ok` with the right bearer, `{:error, reason}` otherwise (the reason goes to the log, never to the caller)."
  @spec authorize(Plug.Conn.t()) :: :ok | {:error, term()}
  def authorize(conn) do
    expected = token()

    case get_req_header(conn, "authorization") do
      ["Bearer " <> given] when byte_size(given) > 0 ->
        if byte_size(given) == byte_size(expected) and :crypto.hash_equals(given, expected),
          do: :ok,
          else: {:error, :wrong_bearer}

      [] ->
        {:error, :no_bearer}

      _ ->
        {:error, :malformed_authorization}
    end
  end

  @doc "The token in force: the environment variable, else the generated file's."
  # sobelow_skip reason: Traversal.FileModule: the path is the data directory's plus a constant
  # name (token_path/0), never a request's.
  @sobelow_skip ["Traversal.FileModule"]
  @spec token() :: String.t()
  def token do
    case System.get_env(@env) do
      t when is_binary(t) and t != "" -> t
      _ -> File.read!(ensure_token!()) |> String.trim()
    end
  end

  @doc "The token file's path."
  @spec token_path() :: Path.t()
  def token_path, do: Path.join(Trinity.Paths.ensure_data_dir(), @token_file)

  @doc "Generates the token file when absent (mode 0600); returns its path."
  # sobelow_skip reason: Traversal.FileModule: the path is the data directory's, never a request's.
  @sobelow_skip ["Traversal.FileModule"]
  @spec ensure_token!() :: Path.t()
  def ensure_token! do
    path = token_path()

    unless File.exists?(path) do
      File.write!(path, Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false) <> "\n")
      File.chmod!(path, 0o600)
    end

    path
  end

  @doc "The environment variable's name."
  @spec variable() :: String.t()
  def variable, do: @env
end
