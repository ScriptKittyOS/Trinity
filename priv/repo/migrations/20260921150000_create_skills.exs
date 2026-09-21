# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Repo.Migrations.CreateSkills do
  use Ecto.Migration

  # Slice 040: the skills index (docs/05). The filesystem is canonical; `mix
  # trinity.skills.reindex` rebuilds this table from it.
  def change do
    create table(:skills, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :version, :integer, null: false, default: 1
      add :source, :string, null: false
      add :scope, :string, null: false
      add :path, :string, null: false
      add :frontmatter, :map, null: false, default: %{}
      add :body_hash, :string, null: false
      add :status, :string, null: false, default: "active"
      add :scan_result, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:skills, [:name, :source])
    create index(:skills, [:status])
  end
end
