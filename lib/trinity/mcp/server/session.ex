# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.Server.Session do
  @moduledoc """
  The session every MCP call is attributed to (slice 061): one row with `origin: "mcp"` and a
  persona of its own ("MCP server", no permission settings, so an external caller inherits
  none of the default persona's allowances: the default persona lets the assistant write its
  own memory without asking, and an MCP client is not the assistant), found or created on
  first use. The gate's scope, the approvals' session and
  the receipts' chain scope are all this row's, so a call made by an MCP client is audited
  where every other call is, under a session the permissions page shows as "MCP server".
  No `Trinity.Sessions.Session` process runs for it: the server is stateless, and the
  membrane needs a session id, not a process.
  """
  import Ecto.Query, only: [from: 2]

  alias Trinity.Repo
  alias Trinity.Sessions
  alias Trinity.Sessions.SessionRow

  @title "MCP server"
  @persona "MCP server"

  @doc "The row's id, creating the row when none exists."
  @spec id() :: String.t()
  def id, do: row().id

  @doc "The row."
  @spec row() :: SessionRow.t()
  def row do
    case Repo.one(
           from(s in SessionRow, where: s.origin == "mcp", order_by: s.inserted_at, limit: 1)
         ) do
      %SessionRow{} = row ->
        row

      nil ->
        case Sessions.create_session(%{persona_id: persona().id, origin: "mcp", title: @title}) do
          {:ok, row} -> row
          {:error, _} -> row()
        end
    end
  end

  @doc "The MCP persona: found by name, created with no settings when absent."
  @spec persona() :: struct()
  def persona do
    case Sessions.get_persona_by_name(@persona) do
      nil ->
        case Trinity.Personas.create(%{
               name: @persona,
               soul: "Trinity, serving MCP clients.",
               settings: %{}
             }) do
          {:ok, persona} -> persona
          {:error, _} -> Sessions.get_persona_by_name(@persona)
        end

      persona ->
        persona
    end
  end
end
