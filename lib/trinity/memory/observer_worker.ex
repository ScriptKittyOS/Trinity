# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.ObserverWorker do
  @moduledoc """
  The observer as a job on the `memory` queue (slice 050): `Trinity.Memory.Observer.observe/2`
  enqueues one per finished turn with the turn and the ids of its messages; this worker reloads
  those messages from the session's history (the rows, not a copy of their text in the job) and
  runs `Trinity.Memory.Observer.run/2` as the task supervisor did at 032. A model error is
  `{:error, _}` and Oban retries under `max_attempts` (3) with its backoff; `:off` is a
  discard, since nothing changes by waiting.
  """
  use Oban.Worker, queue: :memory, max_attempts: 3

  alias Trinity.Memory.Observer
  alias Trinity.Sessions

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"turn" => turn, "message_ids" => ids}}) do
    turn = %{
      session_id: turn["session_id"],
      persona_id: turn["persona_id"],
      model: turn["model"]
    }

    wanted = MapSet.new(ids)

    messages =
      turn.session_id
      |> Sessions.history()
      |> Enum.filter(&MapSet.member?(wanted, &1.id))
      |> Enum.map(&%{id: &1.id, role: &1.role, content: &1.content})

    case Observer.run(turn, messages) do
      {:ok, _entries} -> :ok
      :off -> {:cancel, :off}
      {:error, reason} -> {:error, reason}
    end
  end
end
