# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Repo.Migrations.CreateSessions do
  @moduledoc "Slice 010. The sessions table per docs/05; `parent_id` is the lineage slice 023 uses."
  use Ecto.Migration

  def change do
    create table(:sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :string
      add :persona_id, references(:personas, type: :binary_id, on_delete: :restrict), null: false
      add :parent_id, references(:sessions, type: :binary_id, on_delete: :nilify_all)
      add :origin, :string, null: false, default: "desktop"
      add :origin_ref, :map, null: false, default: %{}
      add :status, :string, null: false, default: "active"
      add :model, :string
      add :token_usage, :map, null: false, default: %{}
      add :last_activity_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create index(:sessions, [:persona_id])
    create index(:sessions, [:parent_id])
    create index(:sessions, [:status, :last_activity_at])
  end
end
