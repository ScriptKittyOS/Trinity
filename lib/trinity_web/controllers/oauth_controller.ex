# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.OAuthController do
  @moduledoc """
  The authorization endpoints (slice 062), every one a thin call into `Trinity.MCP.AuthHost`:
  the RFC 9728 Protected Resource Metadata and, in the personal profile, the RFC 8414 metadata,
  the JWKS, the authorization endpoint with the owner's consent page, the token endpoint and the
  registration endpoint; and the client role's callback, where the owner lands after authorizing
  Trinity at another server's authorization server.
  """
  use TrinityWeb, :controller

  alias Trinity.MCP.AuthHost

  ## Metadata

  def protected_resource(conn, _params) do
    case AuthHost.resource_metadata() do
      nil -> send_resp(conn, 404, "")
      doc -> json(conn, doc)
    end
  end

  def authorization_server(conn, _params) do
    case AuthHost.as_metadata() do
      nil -> send_resp(conn, 404, "")
      doc -> json(conn, doc)
    end
  end

  def jwks(conn, _params) do
    case AuthHost.jwks() do
      nil -> send_resp(conn, 404, "")
      doc -> json(conn, doc)
    end
  end

  ## The personal profile's authorization server

  def authorize(conn, params) do
    if AuthHost.embedded?() do
      case AuthHost.authorize_begin(params) do
        {:ok, pending} ->
          render(conn, :consent, pending: pending)

        {:redirect_error, url} ->
          redirect(conn, external: url)

        {:error, reason} ->
          conn |> put_status(400) |> text("invalid request: #{AuthHost.describe(reason)}")
      end
    else
      send_resp(conn, 404, "")
    end
  end

  def consent(conn, %{"request_id" => id, "decision" => decision})
      when decision in ["approve", "deny"] do
    case AuthHost.authorize_decide(id, String.to_existing_atom(decision)) do
      {:ok, url} ->
        redirect(conn, external: url)

      {:error, reason} ->
        conn |> put_status(400) |> text("no such request: #{AuthHost.describe(reason)}")
    end
  end

  def token(conn, params) do
    if AuthHost.embedded?() do
      case AuthHost.token(params) do
        {:ok, token} -> conn |> put_resp_header("cache-control", "no-store") |> json(token)
        {:error, reason} -> conn |> put_status(400) |> json(%{"error" => oauth_error(reason)})
      end
    else
      send_resp(conn, 404, "")
    end
  end

  def register(conn, params) do
    if AuthHost.embedded?() do
      case AuthHost.register(params) do
        {:ok, client} -> conn |> put_status(201) |> json(client)
        {:error, :registration_disabled} -> send_resp(conn, 404, "")
        {:error, reason} -> conn |> put_status(400) |> json(%{"error" => oauth_error(reason)})
      end
    else
      send_resp(conn, 404, "")
    end
  end

  ## The client role's callback

  def callback(conn, params) do
    case AuthHost.client_finish(params) do
      {:ok, entry} ->
        conn
        |> put_flash(
          :info,
          gettext("Authorized at %{issuer}; the token is stored for %{resource}.",
            issuer: entry["issuer"],
            resource: entry["resource"]
          )
        )
        |> redirect(to: ~p"/mcp")

      {:error, reason} ->
        conn
        |> put_flash(
          :error,
          gettext("Authorization failed: %{reason}", reason: AuthHost.describe(reason))
        )
        |> redirect(to: ~p"/mcp")
    end
  end

  # The RFC 6749 error names for what the server refused.
  defp oauth_error(reason)
       when reason in [
              :invalid_grant,
              :invalid_client,
              :invalid_redirect_uri,
              :unsupported_grant_type,
              :invalid_target,
              :invalid_scope
            ],
       do: Atom.to_string(reason)

  defp oauth_error({:invalid_request, _}), do: "invalid_request"
  defp oauth_error(_), do: "invalid_request"
end
