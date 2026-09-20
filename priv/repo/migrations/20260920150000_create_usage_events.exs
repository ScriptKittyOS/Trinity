# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Repo.Migrations.CreateUsageEvents do
  @moduledoc "Slice 011. One row per completed LLM call; the cost ledger of slice 090 reads it."
  use Ecto.Migration

  def change do
    create table(:usage_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :model_id, :string, null: false
      add :provider, :string, null: false
      add :kind, :string, null: false
      add :input_tokens, :integer, null: false, default: 0
      add :output_tokens, :integer, null: false, default: 0
      add :cached_tokens, :integer, null: false, default: 0
      add :reasoning_tokens, :integer, null: false, default: 0
      add :cost_usd, :float, null: false, default: 0.0
      add :session_id, references(:sessions, type: :binary_id, on_delete: :nilify_all)
      add :provider_meta, :map, null: false, default: %{}
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:usage_events, [:session_id])
    create index(:usage_events, [:inserted_at])
    create index(:usage_events, [:model_id, :inserted_at])
  end
end
