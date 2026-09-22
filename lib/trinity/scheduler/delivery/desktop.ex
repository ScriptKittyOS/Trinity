# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Scheduler.Delivery.Desktop do
  @moduledoc """
  The desktop delivery (slice 050): the run is marked delivered and broadcast on the `tasks`
  topic; the tasks page lists it among the runs not yet seen, and the bar shows their count.
  """
  @behaviour Trinity.Scheduler.Delivery

  alias Trinity.Scheduler

  @impl true
  def deliver(run, _task) do
    with {:ok, run} <- Scheduler.update_run(run, %{delivered_at: DateTime.utc_now()}) do
      Scheduler.broadcast(run)
      {:ok, run}
    end
  end
end
