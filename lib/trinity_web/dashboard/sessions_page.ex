# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.Dashboard.SessionsPage do
  @moduledoc """
  A LiveDashboard page listing the session processes that are alive, with their `gen_statem` state
  (slice 090, AC3).

  LiveDashboard already lists every process in the VM. What it cannot say is which of them is a
  Trinity session and what state that session's machine is in, which is the question someone asks
  when a turn appears stuck: waiting on a model, waiting on an approval, or idle and the page did
  not notice.

  It reads the registry and asks each process, so it shows the running system rather than the
  database's opinion of it. A session row reads `active` long after its process has gone; slice 080
  found that the hard way, in a panel that promised "which are running" and delivered "which are
  not archived".
  """

  use Phoenix.LiveDashboard.PageBuilder

  alias Trinity.Sessions

  @impl true
  def menu_link(_, _), do: {:ok, "Trinity sessions"}

  @impl true
  def render(assigns) do
    ~H"""
    <.live_table
      id="trinity-sessions"
      dom_id="trinity-sessions"
      page={@page}
      title="Trinity sessions"
      row_fetcher={&fetch_rows/2}
      rows_name="sessions"
    >
      <:col field={:id} header="Session" />
      <:col field={:state} header="State" />
      <:col field={:title} header="Title" />
      <:col field={:origin} header="Origin" />
      <:col field={:pid} header="Process" />
      <:col field={:memory} header="Memory (KB)" sortable={:desc} />
    </.live_table>
    """
  end

  @doc false
  def fetch_rows(params, _node) do
    rows = rows()
    {sort_rows(rows, params), length(rows)}
  end

  defp rows do
    for session <- Sessions.list_sessions(limit: 200),
        pid = Sessions.whereis(session.id),
        is_pid(pid) do
      %{
        id: short(session.id),
        state: state_of(session.id),
        title: session.title || "(untitled)",
        origin: session.origin,
        pid: inspect(pid),
        memory: memory_kb(pid)
      }
    end
  end

  # Asked of the process, never read from the row: a row's status is the session's lifecycle and
  # says nothing about whether its machine is doing anything.
  defp state_of(session_id) do
    case Sessions.state(session_id) do
      %{state: state} -> to_string(state)
      _ -> "-"
    end
  catch
    :exit, _ -> "-"
  end

  defp memory_kb(pid) do
    case Process.info(pid, :memory) do
      {:memory, bytes} -> div(bytes, 1024)
      _ -> 0
    end
  end

  defp short(id), do: String.slice(id, -8, 8)

  defp sort_rows(rows, %{sort_by: by, sort_dir: dir}) when is_atom(by),
    do: Enum.sort_by(rows, &Map.get(&1, by), dir)

  defp sort_rows(rows, _params), do: rows
end
