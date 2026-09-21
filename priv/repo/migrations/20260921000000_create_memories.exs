# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Repo.Migrations.CreateMemories do
  @moduledoc """
  Slice 030. `memories` (docs/05: the always-on tiers now, the semantic tier at 032), the
  `memory_changes` log every write appends to, and `memory_proposals`, a consolidation the
  budget could not apply on its own and holds for review.
  """
  use Ecto.Migration

  def change do
    create table(:memories, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :persona_id, references(:personas, type: :binary_id, on_delete: :delete_all),
        null: false

      add :tier, :string, null: false
      add :scope, :string, null: false
      add :key, :string
      add :body, :text, null: false
      add :source_message_id, references(:messages, type: :binary_id, on_delete: :nilify_all)
      add :confidence, :float
      add :last_used_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:memories, [:tier, :scope, :key])
    create index(:memories, [:persona_id, :tier])
    create index(:memories, [:scope])

    create table(:memory_changes, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :persona_id, references(:personas, type: :binary_id, on_delete: :delete_all),
        null: false

      add :action, :string, null: false
      add :tier, :string, null: false
      add :scope, :string, null: false
      add :key, :string
      add :before, :text
      add :after, :text
      add :by, :string, null: false
      add :session_id, :binary_id
      add :proposal_id, :binary_id
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:memory_changes, [:persona_id, :inserted_at])
    create index(:memory_changes, [:proposal_id])

    create table(:memory_proposals, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :persona_id, references(:personas, type: :binary_id, on_delete: :delete_all),
        null: false

      add :entries, :map, null: false, default: %{}
      add :bytes_before, :integer, null: false
      add :bytes_after, :integer, null: false
      add :budget, :integer, null: false
      add :status, :string, null: false, default: "pending"
      add :decided_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create index(:memory_proposals, [:persona_id, :status])
  end
end
