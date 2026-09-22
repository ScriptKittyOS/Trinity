# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Repo.Migrations.CreateTasks do
  use Ecto.Migration

  # Slice 050 (docs/05): scheduled agent tasks and their runs. A run is unique on the task and
  # the time it was scheduled for, so a tick that fires twice enqueues once.
  def change do
    create table(:tasks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :kind, :string, null: false, default: "cron"
      add :schedule, :string, null: false
      add :prompt, :text, null: false
      add :persona_id, references(:personas, type: :binary_id, on_delete: :nilify_all)
      add :skill_names, {:array, :string}, null: false, default: []
      add :deliver_to, :map, null: false, default: %{}
      add :enabled, :boolean, null: false, default: true
      add :timeout_ms, :integer, null: false, default: 600_000
      add :last_run_at, :utc_datetime_usec
      add :next_run_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create index(:tasks, [:enabled, :next_run_at])

    create table(:task_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :task_id, references(:tasks, type: :binary_id, on_delete: :delete_all), null: false
      add :scheduled_at, :utc_datetime_usec, null: false
      add :session_id, references(:sessions, type: :binary_id, on_delete: :nilify_all)
      add :status, :string, null: false, default: "queued"
      add :attempt, :integer, null: false, default: 0
      add :summary, :text
      add :error, :text
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :delivered_at, :utc_datetime_usec
      add :seen_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:task_runs, [:task_id, :scheduled_at])
    create index(:task_runs, [:status])
    create index(:task_runs, [:seen_at])

    # The curator's marks (never a delete).
    alter table(:memories) do
      add :stale_at, :utc_datetime_usec
      add :archived_at, :utc_datetime_usec
    end

    create index(:memories, [:archived_at])
  end
end
