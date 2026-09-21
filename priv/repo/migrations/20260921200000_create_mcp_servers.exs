# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Repo.Migrations.CreateMcpServers do
  use Ecto.Migration

  # Slice 060: the configured MCP servers (docs/05). One row per server the client connects
  # to; `env_refs` names environment variables passed through to a stdio child and never
  # holds a value; `tool_overrides` is a map of tool name to its effect and risk.
  def change do
    create table(:mcp_servers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :transport, :string, null: false
      add :command, :string
      add :args, {:array, :string}, null: false, default: []
      add :url, :string
      add :env_refs, {:array, :string}, null: false, default: []
      add :enabled, :boolean, null: false, default: true
      add :effect_default, :string, null: false, default: "none"
      add :tool_overrides, :map, null: false, default: %{}
      add :last_error, :text
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:mcp_servers, [:name])
  end
end
