# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Repo.Migrations.CreateToolSurfaces do
  use Ecto.Migration

  # Slice 029 (docs/07 "Tool-surface drift"): the definition of each tool as it stood the first
  # time this machine saw it, or the last time the owner accepted a change to it. One row per
  # (server, tool), unique on the pair, because a tool name is only meaningful within the server
  # that listed it.
  #
  # `definition` holds the canonical form and not only the digest. A digest answers "did this
  # change"; the drift notice has to answer "what changed", and re-deriving fields from a hash is
  # not possible. It is the listed definition, which carries no arguments and no results: a name,
  # a description, an input schema and annotations.
  def change do
    create table(:tool_surfaces, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :server, :string, null: false
      add :tool, :string, null: false
      add :digest, :string, null: false
      add :definition, :map, null: false, default: %{}
      # When this machine first saw the tool at all, kept across accepted changes so that a tool
      # which has been present for months is distinguishable from one that appeared today.
      add :first_seen_at, :utc_datetime_usec, null: false
      # When the owner last accepted this definition. Null means the baseline was written on first
      # sight and has never been the subject of a decision.
      add :accepted_at, :utc_datetime_usec
      # The definition that drifted, held here until the owner decides about it. Null means no
      # drift is outstanding. It lives on the same row rather than in a table of its own because
      # there is at most one outstanding change per tool: a server that changes a definition twice
      # before anyone looks has simply changed it, and the owner should be shown where it stands
      # now rather than a history of a server's edits.
      add :pending_definition, :map
      add :pending_digest, :string
      add :pending_since, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tool_surfaces, [:server, :tool])
  end
end
