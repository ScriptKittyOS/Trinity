# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.GatewayCallbackController do
  @moduledoc """
  `POST /gateways/callback/:adapter/:kind` (slice 072): a messaging platform calling Trinity back,
  for a button pressed, a dialog submitted or a slash command typed.

  It knows no platform. The body is handed to `Trinity.Gateways.callback/3`, which finds the
  configured adapter by name and lets it verify the request; an adapter that is not configured
  answers 404, as a path that does not exist would. Only the decoded body is passed on, not the
  path parameters, so a body cannot pretend to be a different adapter or kind.

  Not behind the browser pipeline: the caller is a server, with no session and no CSRF token, and
  the proof that a request is genuine is the adapter's own (a signed context, a command token).
  """
  use TrinityWeb, :controller

  @doc "Hands the callback to its adapter and answers what the adapter says."
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"adapter" => adapter, "kind" => kind}) do
    case Trinity.Gateways.callback(adapter, kind, conn.body_params) do
      {:ok, body} -> json(conn, body)
      {:error, :not_found} -> conn |> put_status(404) |> json(%{})
      {:error, :forbidden} -> conn |> put_status(403) |> json(%{})
      {:error, :bad_request} -> conn |> put_status(400) |> json(%{})
    end
  end
end
