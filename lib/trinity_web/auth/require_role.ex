# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.Auth.RequireRole do
  @moduledoc """
  The role a route needs (slice 136), in the router's pipelines: `plug TrinityWeb.Auth.RequireRole,
  :view` on every page, `:administer` on the privileged routes (the export, the dashboards, the
  authorization surfaces' owner pages).

  No principal is `401` (the gate in the endpoint already refused it, so reaching here without one
  means the plug is mounted somewhere the gate exempts, and failing closed is the answer). A
  principal without the role is `403`. A route that needs more than `view` is a privileged route:
  its use and its refusal are both receipted with the principal and the role
  (`TrinityWeb.Auth.privileged_receipt/4`), and a use that cannot be receipted is refused.
  """
  @behaviour Plug

  import Plug.Conn

  alias TrinityWeb.Auth
  alias TrinityWeb.Auth.Principal

  @impl Plug
  def init(role) when role in [:view, :approve, :administer], do: role

  @impl Plug
  def call(conn, role) do
    case conn.assigns[:web_principal] do
      %Principal{} = principal -> check(conn, principal, role)
      _ -> conn |> send_resp(401, "authentication required\n") |> halt()
    end
  end

  defp check(conn, principal, :view) do
    if Principal.has_role?(principal, :view),
      do: conn,
      else: forbid(conn, :view)
  end

  defp check(conn, principal, role) do
    conn = fetch_query_params(conn)

    detail = %{
      "phase" => "privileged_route",
      "method" => conn.method,
      "path" => conn.request_path,
      # The export's one parameter that changes what leaves the machine; nothing else of the
      # query is recorded.
      "keys" => conn.query_params["keys"] in ["1", "true"]
    }

    if Principal.has_role?(principal, role) do
      case Auth.privileged_receipt(principal, role, "allow", detail) do
        :ok -> conn
        {:error, _} -> conn |> send_resp(503, "not receipted, so not done\n") |> halt()
      end
    else
      _ = Auth.privileged_receipt(principal, role, "deny", detail)
      forbid(conn, role)
    end
  end

  defp forbid(conn, role) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(403, "forbidden: this needs the #{role} role\n")
    |> halt()
  end
end
