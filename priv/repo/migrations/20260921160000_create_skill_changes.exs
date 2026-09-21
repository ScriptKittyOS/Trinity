# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Repo.Migrations.CreateSkillChanges do
  use Ecto.Migration

  # Slice 041: staged skill changes (docs/05). The staged files live under the data
  # directory's pending/skills; this row is their diff, rationale, scanner findings and the
  # approval that promoted them.
  def change do
    create table(:skill_changes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :skill_name, :string, null: false
      add :action, :string, null: false
      add :source, :string, null: false, default: "user"
      add :change_dir, :string, null: false
      add :diff, :text, null: false, default: ""
      add :rationale, :text, null: false, default: ""
      add :destructive, :boolean, null: false, default: false
      add :digest, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :severity, :string, null: false, default: "none"
      add :findings, :map, null: false, default: %{}
      add :proposed_by, :binary_id
      add :approval_id, :binary_id
      add :decided_by, :string
      add :decided_at, :utc_datetime_usec
      add :comment, :text
      add :receipt_hash, :string
      add :applied_version, :integer
      timestamps(type: :utc_datetime_usec)
    end

    create index(:skill_changes, [:status])
    create index(:skill_changes, [:skill_name])
  end
end
