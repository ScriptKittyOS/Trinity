# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.Auth.OIDC do
  @moduledoc """
  The web pages' OpenID Connect login (slice 136), on `oidcc` and `oidcc_plug`.

  `oidcc` (EEF Security WG, OpenID Certified) does the protocol; this module only configures it.
  What the configuration guarantees, each asserted by a test against an in-process issuer:

    * **PKCE S256 on every request** (`require_pkce: true`; the login refuses an issuer that does
      not offer S256 rather than falling back to `plain`), with `state` and `nonce`;
    * **a callback with no stored authorization session is refused** (`oidcc_plug` 0.5's
      `:missing_authorize_session`; 0.4 and earlier skipped the checks there, CVE-2026-66884);
    * **`iss` checked** on the ID token always, and on the authorization response whenever the
      issuer advertises RFC 9207;
    * **the ID token is signed** (oidcc 3.9 refuses an encrypted but unsigned one, CVE-2026-75759),
      and roles come from its claims alone: no userinfo call, so the token that was verified is
      the token that was read.

  The plugs' options are built per request from the application environment and the plugs are
  called from `TrinityWeb.AuthController`, not mounted with `plug`, so nothing is evaluated at
  compile time under a release (slice 062 NOTES, F5).
  """

  @provider __MODULE__.Provider

  @doc "The registered name of the issuer's configuration worker."
  @spec provider() :: atom()
  def provider, do: @provider

  @doc """
  The issuer's configuration worker, which fetches the discovery document and the JWKS and keeps
  them fresh. Only under `:oidc`.
  """
  @spec children() :: [Supervisor.child_spec()]
  def children do
    if Trinity.WebAuth.mode() == :oidc, do: [worker_spec(Trinity.WebAuth.config())], else: []
  end

  @doc "The worker's child spec for a configuration (the suite starts it against its issuer)."
  @spec worker_spec(keyword()) :: Supervisor.child_spec()
  def worker_spec(config) do
    Oidcc.ProviderConfiguration.Worker.child_spec(%{
      issuer: Keyword.fetch!(config, :issuer),
      name: @provider,
      # An issuer that cannot be reached is retried with backoff rather than stopping the worker,
      # whose restarts would otherwise exhaust the application supervisor and take the node down
      # with it. The login says the issuer is unreachable in the meantime.
      backoff_type: :random_exponential,
      backoff_min: 1_000,
      backoff_max: 30_000,
      provider_configuration_opts: %{
        quirks: %{allow_unsafe_http: Keyword.get(config, :allow_unsafe_http, false) == true}
      }
    })
  end

  @doc """
  Whether the issuer's discovery document offers PKCE with S256; `{:error, reason}` when its
  configuration cannot be read.
  """
  @spec s256_offered?() :: boolean() | {:error, term()}
  def s256_offered? do
    case Oidcc.ProviderConfiguration.Worker.get_provider_configuration(@provider) do
      %Oidcc.ProviderConfiguration{code_challenge_methods_supported: methods} ->
        is_list(methods) and "S256" in methods

      other ->
        {:error, other}
    end
  rescue
    # oidcc raises converting a configuration it has not loaded yet (the issuer unreachable).
    e in ArgumentError -> {:error, {:not_loaded, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @doc "`Oidcc.Plug.Authorize`'s options."
  @spec authorize_opts(Plug.Conn.t()) :: keyword()
  def authorize_opts(conn) do
    config = Trinity.WebAuth.config()

    Oidcc.Plug.Authorize.init(
      provider: @provider,
      client_id: Keyword.fetch!(config, :client_id),
      client_secret: client_secret(config),
      redirect_uri: redirect_uri(conn, config),
      scopes: ["openid"],
      require_pkce: true
    )
  end

  @doc "`Oidcc.Plug.AuthorizationCallback`'s options."
  @spec callback_opts(Plug.Conn.t()) :: keyword()
  def callback_opts(conn) do
    config = Trinity.WebAuth.config()

    Oidcc.Plug.AuthorizationCallback.init(
      provider: @provider,
      client_id: Keyword.fetch!(config, :client_id),
      client_secret: client_secret(config),
      redirect_uri: redirect_uri(conn, config),
      retrieve_userinfo: false
    )
  end

  defp client_secret(config) do
    case Keyword.get(config, :client_secret) do
      secret when is_binary(secret) and secret != "" -> secret
      _ -> :unauthenticated
    end
  end

  defp redirect_uri(_conn, config) do
    case Keyword.get(config, :redirect_uri) do
      uri when is_binary(uri) and uri != "" ->
        uri

      _ ->
        TrinityWeb.Endpoint.url()
        |> URI.parse()
        |> Map.merge(%{path: "/auth/callback", query: nil})
        |> URI.to_string()
    end
  end
end
