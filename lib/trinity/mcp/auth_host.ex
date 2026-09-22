# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.AuthHost do
  @moduledoc """
  The tree's side of the authorization boundary (slice 062): builds `Trinity.MCP.Auth.Config`
  from `config :trinity, :mcp_auth` and the paths and facts only the tree knows (the data
  directory, the keys directory, whether the local authority is in force), starts the personal
  profile's authorization server when that profile is chosen (and refuses to boot it under an
  external authority adapter, by raising with the reason), authorizes a request and receipts
  every refusal on the MCP session's scope, and runs the client role's flow for the `/mcp` page.
  The boundary itself reads no path, writes no receipt and touches no session; this module does.
  """

  require Logger

  alias Trinity.MCP.Auth
  alias Trinity.MCP.Auth.{Config, Principal}
  alias Trinity.Receipts

  @key {__MODULE__, :config}

  @doc "The configuration in force, built once per VM (reset with `reload/0`)."
  @spec config() :: Config.t()
  def config do
    case :persistent_term.get(@key, nil) do
      %Config{} = c -> c
      nil -> reload()
    end
  end

  @doc "Rebuilds the configuration from the application environment."
  @spec reload() :: Config.t()
  def reload do
    env = Application.get_env(:trinity, :mcp_auth, [])
    data_dir = Trinity.Paths.ensure_data_dir()
    profile = Keyword.get(env, :profile, :local)

    opts =
      env
      |> Keyword.put(:profile, profile)
      |> Keyword.put_new(:token_path, Path.join(data_dir, "mcp-server-token"))
      |> Keyword.put_new(:key_dir, Trinity.Receipts.KeyCustody.keys_dir())
      |> Keyword.put_new(:store_dir, Path.join([data_dir, "secrets", "oauth"]))
      |> Keyword.put(:local_authority?, Trinity.Authority.impl() == Trinity.Authority.Local)

    config = Config.new!(opts)
    :persistent_term.put(@key, config)
    config
  end

  @doc "Starts what the profile needs at boot: the personal profile's authorization server."
  @spec boot() :: :ok
  def boot do
    case config() do
      %Config{profile: :personal} = c ->
        case Auth.Embedded.start_link(c) do
          {:ok, _pid} ->
            Logger.info("mcp auth: personal profile, issuer #{Auth.Embedded.issuer(c)}")
            :ok

          {:error, {:already_started, _}} ->
            :ok

          {:error, :external_authority_in_force} ->
            raise "mcp auth: the personal profile has no embedded issuer under an external authority adapter (#{Trinity.Authority.selected_name()}); choose the production profile"
        end

      %Config{profile: profile} ->
        Logger.info("mcp auth: #{profile} profile")
        :ok
    end
  end

  @doc "Authorizes a request under the profile; a refusal is receipted with what could be read of the caller."
  @spec authorize(Plug.Conn.t()) :: {:ok, Principal.t()} | {:error, term()}
  def authorize(conn) do
    config = config()

    case Auth.authorize(conn, config) do
      {:ok, principal} ->
        {:ok, principal}

      {:error, reason} ->
        refusal_receipt(conn, config, reason)
        {:error, reason}
    end
  end

  @doc "The `WWW-Authenticate` value a refusal answers with, per profile."
  @spec challenge(Config.t()) :: String.t()
  def challenge(%Config{profile: :local}), do: "Bearer"

  def challenge(%Config{resource: resource}),
    do: ~s(Bearer resource_metadata="#{prm_url(resource)}")

  @doc "The Protected Resource Metadata URL for a resource identifier (RFC 9728, path-aware)."
  @spec prm_url(String.t()) :: String.t()
  def prm_url(resource) do
    uri = URI.parse(resource)
    path = String.trim_trailing(uri.path || "", "/")
    origin = %{uri | path: nil, query: nil, fragment: nil} |> URI.to_string()
    origin <> "/.well-known/oauth-protected-resource" <> path
  end

  @doc "The resource metadata the profile publishes, or nil (the local profile publishes none)."
  @spec resource_metadata() :: map() | nil
  def resource_metadata do
    c = config()
    Auth.impl(c).resource_metadata(c)
  end

  # What a refusal says about who was refused: the unverified `iss` and `sub` of a JWT-shaped
  # bearer, flagged as unverified (they are the caller's claim, not a fact), the reason, and the
  # peer address. The bearer itself is never in the receipt.
  defp refusal_receipt(conn, config, reason) do
    claimed =
      with {:ok, token} <- Auth.bearer(conn),
           {:ok, claims} <- unverified_claims(token) do
        %{"claimed_iss" => claims["iss"], "claimed_sub" => claims["sub"], "unverified" => true}
      else
        _ -> %{}
      end

    scope = Receipts.session_scope(Trinity.MCP.Server.Session.id())

    Receipts.append(scope, %{
      kind: "decision",
      subject:
        Map.merge(claimed, %{
          "phase" => "auth",
          "profile" => Atom.to_string(config.profile),
          "peer" => peer(conn),
          "origin" => "mcp"
        }),
      decision: %{"outcome" => "deny", "basis" => "auth", "reason" => describe(reason)},
      subject_ref: "mcp-auth:" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false),
      meta: %{}
    })
  rescue
    e -> Logger.warning("mcp auth: refusal not receipted: #{Exception.message(e)}")
  end

  defp unverified_claims(token) do
    with [_h, p, _s] <- String.split(token, "."),
         {:ok, json} <- Base.url_decode64(p, padding: false),
         {:ok, %{} = claims} <- Jason.decode(json) do
      {:ok, claims}
    else
      _ -> :error
    end
  end

  defp peer(%Plug.Conn{remote_ip: ip}) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()
  defp peer(_), do: nil

  @doc "A refusal's reason as a receipt reads it: a word or two, never a token."
  @spec describe(term()) :: String.t()
  def describe(reason) when is_atom(reason), do: Atom.to_string(reason)

  def describe({tag, detail}) when is_atom(tag) and (is_binary(detail) or is_atom(detail)),
    do: "#{tag}: #{detail}"

  def describe({tag, _}) when is_atom(tag), do: Atom.to_string(tag)
  def describe(other), do: inspect(other)

  ## The client role, for the page

  @doc "Begins the client flow for a challenge URL: the URL the owner opens. `redirect_uri:` is the host's callback (the web layer knows its own URL)."
  @spec client_begin(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def client_begin(prm_url, opts) do
    with {:ok, discovered} <- Auth.Client.discover(prm_url, opts),
         {:ok, %{url: url}} <- Auth.Client.begin(discovered, config(), opts) do
      {:ok, url}
    end
  end

  @doc "Finishes the client flow from the callback's params."
  @spec client_finish(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def client_finish(params, opts \\ []), do: Auth.Client.finish(params, config(), opts)

  @doc "A stored bearer for a server URL (the resource), when the client role obtained one."
  @spec client_bearer(String.t()) :: String.t() | nil
  def client_bearer(resource), do: Auth.Client.bearer(config(), resource)

  ## The endpoints the web layer serves (the personal profile's authorization server)

  @doc "The RFC 8414 metadata, when the profile has an authorization server of its own."
  @spec as_metadata() :: map() | nil
  def as_metadata do
    case config() do
      %Config{profile: :personal} = c -> Auth.Embedded.metadata(c)
      _ -> nil
    end
  end

  @doc "The JWKS, when the profile has keys of its own."
  @spec jwks() :: map() | nil
  def jwks do
    case config() do
      %Config{profile: :personal} = c -> Auth.Embedded.jwks(c)
      _ -> nil
    end
  end

  @doc "True when the personal profile's authorization server is serving."
  @spec embedded?() :: boolean()
  def embedded?, do: config().profile == :personal and is_pid(Process.whereis(Auth.Embedded))

  @doc "An authorization request begun (the consent page's data), or why not."
  @spec authorize_begin(map()) :: {:ok, map()} | {:error, term()} | {:redirect_error, String.t()}
  def authorize_begin(params), do: Auth.Embedded.begin(params)

  @doc "The owner's decision on a pending request: the redirect for the client."
  @spec authorize_decide(String.t(), :approve | :deny) :: {:ok, String.t()} | {:error, term()}
  def authorize_decide(request_id, decision),
    do: Auth.Embedded.decide(request_id, decision, "owner")

  @doc "The token endpoint."
  @spec token(map()) :: {:ok, map()} | {:error, term()}
  def token(params), do: Auth.Embedded.token(params)

  @doc "The registration endpoint (DCR), when enabled."
  @spec register(map()) :: {:ok, map()} | {:error, term()}
  def register(metadata), do: Auth.Embedded.register(metadata)

  @doc "Rotates the personal profile's signing key."
  @spec rotate_key!() :: String.t()
  def rotate_key! do
    %Config{key_dir: dir} = config()
    Auth.Embedded.Keys.rotate!(dir).kid
  end
end
