# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.AuthController do
  @moduledoc """
  The login, its callback, the shared token's exchange, and the logout (slice 136).

    * `GET /auth/login`: under `:oidc`, the redirect to the issuer (authorization code, PKCE S256,
      `state`, `nonce`); under `:local_token`, the token form; under `:none`, home.
    * `GET /auth/callback`: the issuer's answer, checked by `oidcc_plug` (stored session, state,
      `iss`, the code exchanged with the verifier, the ID token's signature, issuer, audience and
      nonce), then roles from the ID token's claims (`TrinityWeb.Auth.Claims`). A login with no
      Trinity role, or whose roles cannot be read, is refused with a page that says why.
    * `POST /auth/token`: the shared token, compared in constant time, one guess per address per
      window (`429` inside it), exchanged for a session; the token is never logged (the parameter
      is `secret`, which `:filter_parameters` names) and never stored.
    * `POST /auth/logout`: the session ended on the server and the cookie dropped.
  """
  use TrinityWeb, :controller

  require Logger

  alias TrinityWeb.Auth
  alias TrinityWeb.Auth.{Claims, OIDC, Principal, Sessions}

  def login(conn, _params) do
    case Trinity.WebAuth.mode() do
      :oidc -> oidc_login(conn)
      :local_token -> render(conn, :token)
      :none -> redirect(conn, to: ~p"/")
    end
  end

  # PKCE with S256 or no login: oidcc falls back to `plain` when an issuer offers only that, and
  # `plain` sends the verifier itself as the challenge, which protects nothing against a party
  # that can read the authorization request.
  defp oidc_login(conn) do
    case OIDC.s256_offered?() do
      true ->
        Oidcc.Plug.Authorize.call(conn, OIDC.authorize_opts(conn))

      false ->
        Logger.error("web login: the issuer does not offer PKCE S256; refusing to start a login")
        denied(conn, 503, gettext("The identity provider does not offer PKCE with S256."))

      {:error, reason} ->
        Logger.error("web login: the issuer's configuration is unavailable: #{inspect(reason)}")
        denied(conn, 503, gettext("The identity provider cannot be reached."))
    end
  end

  def callback(conn, _params) do
    if Trinity.WebAuth.mode() == :oidc do
      conn = Oidcc.Plug.AuthorizationCallback.call(conn, OIDC.callback_opts(conn))
      finish(conn, conn.private[Oidcc.Plug.AuthorizationCallback])
    else
      send_resp(conn, 404, "")
    end
  end

  defp finish(conn, {:ok, {%Oidcc.Token{id: %Oidcc.Token.Id{claims: claims}}, _userinfo}}) do
    config = Trinity.WebAuth.config()

    case Claims.roles(claims, config[:client_id], config[:role_claim]) do
      {:ok, roles} ->
        principal = %Principal{
          sub: claims["sub"],
          iss: claims["iss"],
          mode: :oidc,
          roles: roles
        }

        conn |> Auth.log_in(principal) |> redirect(to: ~p"/")

      {:error, reason} ->
        Logger.warning(
          "web login refused for #{claims["sub"]} at #{claims["iss"]}: #{inspect(reason)}"
        )

        denied(conn, 403, Claims.describe(reason))
    end
  end

  # Only the kind of refusal is logged: some of oidcc's reasons carry the token's claims, which name
  # a person and are not the log's to keep.
  defp finish(conn, {:error, reason}) do
    Logger.warning("web login callback refused: #{describe(reason)}")
    denied(conn, 401, "The sign-in could not be completed (#{describe(reason)}). Start again.")
  end

  defp finish(conn, _other), do: denied(conn, 401, "The sign-in could not be completed.")

  defp describe({kind, _detail}) when is_atom(kind), do: Atom.to_string(kind)
  defp describe(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp describe(_), do: "refused"

  def token(conn, params) do
    with :local_token <- Trinity.WebAuth.mode(),
         :ok <- throttle(conn),
         true <- matches?(params["secret"]) do
      conn |> Auth.log_in(Principal.local_token()) |> redirect(to: ~p"/")
    else
      {:error, :rate_limited} ->
        conn |> put_resp_content_type("text/plain") |> send_resp(429, "too many attempts\n")

      false ->
        conn
        |> put_status(401)
        |> put_flash(:error, gettext("That token is not this Trinity's."))
        |> render(:token)

      _mode ->
        send_resp(conn, 404, "")
    end
  end

  def logout(conn, _params) do
    conn |> Auth.log_out() |> redirect(to: ~p"/auth/login")
  end

  def forbidden(conn, _params),
    do: denied(conn, 403, gettext("Your role does not include this page."))

  defp denied(conn, status, reason) do
    conn
    |> put_status(status)
    |> render(:denied, title: gettext("Not signed in"), reason: reason)
  end

  defp throttle(conn) do
    window = Keyword.get(Trinity.WebAuth.config(), :token_rate_window_ms, 2_000)
    Sessions.throttle({:local_token, conn.remote_ip}, window)
  end

  # Both sides hashed first, so the comparison is over equal lengths and its time says nothing
  # about the length of either; `Plug.Crypto.secure_compare/2` is constant time over those.
  defp matches?(guess) when is_binary(guess) do
    case Keyword.get(Trinity.WebAuth.config(), :token) do
      token when is_binary(token) ->
        Plug.Crypto.secure_compare(:crypto.hash(:sha256, guess), :crypto.hash(:sha256, token))

      _ ->
        false
    end
  end

  defp matches?(_), do: false
end
