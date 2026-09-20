# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Repo.Migrations.CreateMessages do
  @moduledoc """
  Slice 010. Append-only messages with a gapless `seq` per session. The unique index on
  `(session_id, seq)` is the property the stress test proves; `append_message/2` assigns
  `seq` inside one transaction and this index refuses a duplicate on either adapter.
  """
  use Ecto.Migration

  def change do
    create table(:messages, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :session_id, references(:sessions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :seq, :integer, null: false
      add :role, :string, null: false
      add :content, :text, null: false
      add :parts, :map, null: false, default: %{}
      add :tool_call_id, :string
      add :usage, :map
      add :provider_meta, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:messages, [:session_id, :seq])
  end
end
