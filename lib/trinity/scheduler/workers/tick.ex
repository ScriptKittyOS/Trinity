# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Scheduler.Workers.Tick do
  @moduledoc """
  The minute tick (slice 050): the one Oban Cron plugin entry the scheduler needs. Every minute
  it enqueues a `RunTask` for each task whose `next_run_at` has passed and advances the task;
  a tick that runs twice for the same minute enqueues nothing the second time (the run is unique
  on the task and the scheduled time). Cheap enough that a missed minute (the VM was down)
  catches up on the next: a task due while Trinity was off runs once when it returns, at the
  time it was due for.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 1, unique: [period: 30]

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    now =
      case Map.get(args, "now") do
        nil ->
          DateTime.utc_now()

        iso ->
          {:ok, at, _} = DateTime.from_iso8601(iso)
          at
      end

    runs = Trinity.Scheduler.enqueue_due(now)
    {:ok, %{enqueued: length(runs)}}
  end
end
