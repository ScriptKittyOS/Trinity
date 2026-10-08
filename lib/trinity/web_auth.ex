# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.WebAuth do
  @moduledoc """
  How the web pages know who is asking (slice 136): the mode in force and the rules that choose it.

  Three modes.

    * `:none`: no login. Allowed only when the endpoint binds the loopback, where the Host
      allow-list (`TrinityWeb.Plugs.HostAllowList`) and the websocket origin list stand in for
      identity: the desktop app, development and the suite. The principal is the machine's owner.
    * `:oidc`: an OpenID Connect login (authorization code with PKCE) against an external issuer,
      the one `:regulated` already requires for the MCP server unless another is named. Roles come
      from the ID token.
    * `:local_token`: one shared token, exchanged once for a session cookie. A LAN convenience
      outside `:regulated`: it identifies a token, not a person, and the pages say so.

  ## The default is chosen by the bind, and only on the loopback

  `TRINITY_WEB_AUTH` unset on a loopback bind is `:none`. Unset on any other bind is a refusal to
  boot in **every** profile: a page that can be reached from the network and answers anyone is the
  finding this module exists to close (F-132-1), and an operator who has not said which mode they
  want has not said they want none. Setting `TRINITY_WEB_AUTH=none` on a wider bind outside
  `:regulated` is allowed, logged as a warning and named on the boot receipt; `:regulated` refuses
  it (`Trinity.Profile.check_web_auth/3`).

  Every function here is pure except `config/0`, `mode/0` and `in_force/0`, which read the
  application environment and nothing else.
  """

  @type mode :: :none | :oidc | :local_token

  @modes [:none, :oidc, :local_token]
  @env "TRINITY_WEB_AUTH"

  @doc "The three modes."
  @spec modes() :: [mode()]
  def modes, do: @modes

  @doc "The name of the variable that selects the mode, so a refusal and a test agree on it."
  @spec env() :: String.t()
  def env, do: @env

  @doc """
  Parses a configured mode: an atom from config, a string from the environment, or nothing.

  Unset is `:unset`, not `:none`, because what unset means depends on the bind (`resolve/2`). An
  unknown value is an error rather than a fallback: a typo must not produce the open mode.
  """
  @spec parse_mode(atom() | String.t() | nil) :: {:ok, mode() | :unset} | {:error, term()}
  def parse_mode(nil), do: {:ok, :unset}
  def parse_mode(""), do: {:ok, :unset}
  def parse_mode(mode) when mode in @modes, do: {:ok, mode}
  def parse_mode("none"), do: {:ok, :none}
  def parse_mode("oidc"), do: {:ok, :oidc}
  def parse_mode("local_token"), do: {:ok, :local_token}
  def parse_mode(other), do: {:error, {:web_auth_unknown_mode, other, @env}}

  @doc """
  The mode in force for a configured value and the address the endpoint binds.

  Unset on a loopback bind is `:none`; unset on any other bind is
  `{:error, {:web_auth_unset_on_non_loopback_bind, address, "TRINITY_WEB_AUTH"}}`.
  """
  @spec resolve(atom() | String.t() | nil, :inet.ip_address()) :: {:ok, mode()} | {:error, term()}
  def resolve(configured, ip) do
    case parse_mode(configured) do
      {:ok, :unset} ->
        if loopback?(ip),
          do: {:ok, :none},
          else: {:error, {:web_auth_unset_on_non_loopback_bind, format_ip(ip), @env}}

      other ->
        other
    end
  end

  @doc """
  True for an address only this host can reach: `127.0.0.0/8`, `::1`, and `::ffff:127.0.0.0/104`.

  The unspecified addresses (`0.0.0.0`, `::`) are every interface and are not loopback.
  """
  @spec loopback?(term()) :: boolean()
  def loopback?({127, _, _, _}), do: true
  def loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  def loopback?({0, 0, 0, 0, 0, 0xFFFF, hi, _lo}), do: Bitwise.bsr(hi, 8) == 127
  def loopback?(_), do: false

  @doc "An address as text, for a refusal or a receipt."
  @spec format_ip(term()) :: String.t()
  def format_ip(ip) when is_tuple(ip) do
    case :inet.ntoa(ip) do
      {:error, _} -> inspect(ip)
      chars -> List.to_string(chars)
    end
  end

  def format_ip(other), do: inspect(other)

  @doc """
  What a `:local_token` token must be: at least 128 bits. A token is accepted as text of at least
  22 characters (22 base64url characters carry 132 bits), which is the shortest string that can
  hold 128 random bits in the encodings an operator is likely to use.
  """
  @spec check_token(String.t() | nil) :: :ok | {:error, term()}
  def check_token(token) when is_binary(token) and byte_size(token) >= 22, do: :ok
  def check_token(nil), do: {:error, {:web_auth_local_token_unset, "TRINITY_WEB_AUTH_TOKEN"}}

  def check_token(_short),
    do: {:error, {:web_auth_local_token_too_short, "TRINITY_WEB_AUTH_TOKEN"}}

  @doc """
  What `:oidc` needs before it can start: an issuer and a client id. Missing ones are named.
  """
  @spec check_oidc(keyword()) :: :ok | {:error, term()}
  def check_oidc(config) do
    missing =
      for {key, var} <- [
            issuer: "TRINITY_WEB_AUTH_ISSUER",
            client_id: "TRINITY_WEB_AUTH_CLIENT_ID"
          ],
          Keyword.get(config, key) in [nil, ""],
          do: var

    if missing == [], do: :ok, else: {:error, {:web_auth_oidc_unconfigured, missing}}
  end

  @doc "The `config :trinity, :web_auth` keyword list."
  @spec config() :: keyword()
  def config, do: Application.get_env(:trinity, :web_auth, [])

  @doc """
  The mode the running node resolved at boot (`Trinity.Application` writes it under
  `:mode_in_force`), else the configured one, else `:none`.

  Read on every request. The suite changes it with `Application.put_env/3` in tests that are not
  async; nothing in production changes it after boot.
  """
  @spec mode() :: mode()
  def mode do
    config = config()

    case Keyword.get(config, :mode_in_force) do
      mode when mode in @modes ->
        mode

      _ ->
        case parse_mode(Keyword.get(config, :mode)) do
          {:ok, mode} when mode in @modes -> mode
          _ -> :none
        end
    end
  end

  @doc "What the boot receipt records about the web pages: the mode and the bind."
  @spec in_force() :: map()
  def in_force do
    config = config()

    %{
      "mode" => Atom.to_string(mode()),
      "bind" => Keyword.get(config, :bind_in_force, "unknown"),
      "loopback" => Keyword.get(config, :loopback_in_force, false)
    }
  end
end
