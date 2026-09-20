# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Repo.Migrations.CreatePermissions do
  @moduledoc """
  Slice 021. `tool_permissions` (rules and grants) and `approvals` (the audit of every request
  and its decision) per docs/05 and docs/07. A session's grants carry `scope` `session:<id>`
  and a fingerprint pattern; a rule carries `global` or `persona:<id>` and an argument glob.
  """
  use Ecto.Migration

  def change do
    create table(:tool_permissions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tool, :string, null: false
      add :pattern, :string, null: false, default: "*"
      add :decision, :string, null: false
      add :scope, :string, null: false, default: "global"
      add :expires_at, :utc_datetime_usec
      add :decided_by, :string
      timestamps(type: :utc_datetime_usec)
    end

    create index(:tool_permissions, [:tool, :scope])
    create index(:tool_permissions, [:scope])

    create table(:approvals, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :session_id, references(:sessions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :tool, :string, null: false
      add :args, :map, null: false, default: %{}
      add :risk, :string, null: false
      add :fingerprint, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :decision, :string
      add :decided_at, :utc_datetime_usec
      add :decided_by, :string
      add :consumed_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:approvals, [:session_id, :status])
    create index(:approvals, [:status, :expires_at])
    create index(:approvals, [:fingerprint])
  end
end
