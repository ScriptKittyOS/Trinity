# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.Auth.Gate do
  @moduledoc """
  No principal, no route (slice 136, AC2). In the endpoint, after the session and before the
  router.

  A request with a principal continues with it in `conn.assigns.web_principal`. A request without
  one is answered here, before routing: a `GET` or `HEAD` that asks for HTML is redirected to
  `/auth/login`, anything else is `401`. Answering before routing is deliberate: a `POST` to a path
  that has only a `GET` route would otherwise be a `404` naming no route, which tells an
  unauthenticated caller which paths exist and is not what AC2 asks for.

  **What passes without a principal**, and why each:

    * `/auth/*`: the login itself.
    * `/.well-known/*`, `POST /oauth/token`, `POST /oauth/register`: the MCP authorization
      surfaces (slice 062), which a client or another server reads without a browser and which
      authenticate by their own protocol.

  `POST /mcp` never reaches this plug: `Trinity.MCP.Server.Plug` answers it earlier with its own
  bearer check. Static assets are served earlier still.
  """
  @behaviour Plug

  import Plug.Conn

  alias TrinityWeb.Auth

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn = fetch_session(conn)

    case Auth.principal(get_session(conn)) do
      {:ok, principal} ->
        assign(conn, :web_principal, principal)

      {:error, reason} ->
        if exempt?(conn), do: conn, else: refuse(conn, reason)
    end
  end

  @doc "True for the paths that pass without a principal (see the moduledoc)."
  @spec exempt?(Plug.Conn.t()) :: boolean()
  def exempt?(%Plug.Conn{path_info: ["auth" | _]}), do: true
  def exempt?(%Plug.Conn{path_info: [".well-known" | _]}), do: true
  def exempt?(%Plug.Conn{method: "POST", path_info: ["oauth", "token"]}), do: true
  def exempt?(%Plug.Conn{method: "POST", path_info: ["oauth", "register"]}), do: true
  def exempt?(_conn), do: false

  defp refuse(conn, _reason) do
    if conn.method in ["GET", "HEAD"] and wants_html?(conn) do
      conn
      |> put_resp_header("location", "/auth/login")
      |> put_resp_content_type("text/plain")
      |> send_resp(302, "")
      |> halt()
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(401, "authentication required\n")
      |> halt()
    end
  end

  defp wants_html?(conn) do
    case get_req_header(conn, "accept") do
      [] -> true
      [accept | _] -> accept =~ "text/html" or accept =~ "*/*"
    end
  end
end
