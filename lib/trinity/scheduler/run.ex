# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Scheduler.Run do
  @moduledoc """
  One row of `task_runs` (slice 050, docs/05): one scheduled execution of a task, unique on the
  task and the time it was scheduled for. `status` goes `queued`, `running`, then `ok` or, through
  `retrying`, `failed`; `session_id` is the `cron` session the turn ran in; `summary` the assistant's
  answer (its head); `delivered_at` when the delivery ran and `seen_at` when the owner saw it on the
  tasks page.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Trinity.UUID, autogenerate: true}
  @foreign_key_type Trinity.UUID
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  @statuses ~w(queued running retrying ok failed)

  schema "task_runs" do
    field :scheduled_at, :utc_datetime_usec
    field :status, :string, default: "queued"
    field :attempt, :integer, default: 0
    field :summary, :string
    field :error, :string
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :delivered_at, :utc_datetime_usec
    field :seen_at, :utc_datetime_usec
    belongs_to :task, Trinity.Scheduler.Task
    belongs_to :session, Trinity.Sessions.SessionRow
    timestamps()
  end

  @doc "The statuses."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :task_id,
      :scheduled_at,
      :session_id,
      :status,
      :attempt,
      :summary,
      :error,
      :started_at,
      :finished_at,
      :delivered_at,
      :seen_at
    ])
    |> validate_required([:task_id, :scheduled_at, :status])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:task_id, :scheduled_at])
    |> foreign_key_constraint(:task_id)
  end
end
