# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Sessions.Supervisor do
  @moduledoc """
  One `Trinity.Sessions.Session` per conversation, `:one_for_one`, ten restarts a minute per
  the architecture. A session that exits normally (idle stop) is not restarted; one that is
  killed is, and rehydrates from the database. Slice 012.
  """
  use DynamicSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts),
    do: DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 10, max_seconds: 60)

  @doc "Starts a session process, or returns the running one."
  @spec start_session(String.t()) :: {:ok, pid()} | {:error, term()}
  def start_session(session_id) do
    spec = %{
      id: {Trinity.Sessions.Session, session_id},
      start: {Trinity.Sessions.Session, :start_link, [session_id]},
      restart: :transient,
      shutdown: 5_000
    }

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end
end
