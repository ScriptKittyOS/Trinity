# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Repo.Migrations.CreatePersonas do
  @moduledoc """
  Slice 010. The minimal persona row docs/05 names: name, soul, model, settings. Slice 030 fills
  it in. Ids are UUIDv7 strings minted by `Trinity.UUID` (`:binary_id` on both adapters).
  """
  use Ecto.Migration

  def change do
    create table(:personas, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :soul, :text
      add :model, :string
      add :settings, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:personas, [:name])
  end
end
