# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Tools.Taint do
  @moduledoc """
  Which sessions have read a file from a path tagged sensitive (slice 135, the network half of S1).

  A path is tagged sensitive when it lies outside the roots: the read had to be approved, so it is
  the read the owner marked as out of the ordinary (slice 135 NOTES, D2). Once a session has made
  one, `web_fetch` asks for every fetch in that session, because whether a request "carries" bytes
  read earlier cannot be decided against any encoding of them.

  **The taint is not the gate for the read.** The read was already allowed or asked as before; this
  only raises what a later egress needs, and it rides on receipts as an attribute. A public table
  under `Trinity.Tools.Supervisor`, one row per session and path, at most 100 paths per session;
  nothing here survives a restart, and a restarted session has no taint (the owner's approval of the
  earlier read is still on its chain).
  """
  use GenServer

  @table :trinity_tools_taint
  @max_paths 100

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :bag, read_concurrency: true])
    {:ok, nil}
  end

  @doc "Records a read the guard judged outside the roots (`decision: :ask`) for the session; ignores any other."
  @spec note_read(map(), String.t() | nil) :: :ok
  def note_read(%{decision: :ask, canonical: path}, session_id)
      when is_binary(session_id) and is_binary(path) do
    if table?() and length(sensitive_paths(session_id)) < @max_paths do
      :ets.insert(@table, {session_id, path})
    end

    :ok
  end

  def note_read(_verdict, _session_id), do: :ok

  @doc "The sensitive paths the session has read, in no particular order."
  @spec sensitive_paths(String.t() | nil) :: [String.t()]
  def sensitive_paths(session_id) when is_binary(session_id) do
    if table?(),
      do: @table |> :ets.lookup(session_id) |> Enum.map(&elem(&1, 1)) |> Enum.uniq(),
      else: []
  end

  def sensitive_paths(_), do: []

  @doc "True when the session has read a path tagged sensitive."
  @spec sensitive?(String.t() | nil) :: boolean()
  def sensitive?(session_id), do: sensitive_paths(session_id) != []

  @doc "Forgets a session's taint."
  @spec clear(String.t()) :: :ok
  def clear(session_id) do
    if table?(), do: :ets.delete(@table, session_id)
    :ok
  end

  defp table?, do: :ets.whereis(@table) != :undefined
end
