# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Skills.Row do
  @moduledoc """
  One row of `skills` (slice 040, docs/05): the index of a skill the registry found, unique
  by name and source. The filesystem is canonical; this row carries what a page or a query
  needs without reading it (the frontmatter, the body's digest, the manifest in
  `scan_result`), `version` (bumped when the body's digest changes) and `status` (`active` or
  `disabled`, the owner's, kept across rescans).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Trinity.UUID, autogenerate: true}

  @type t :: %__MODULE__{}

  @statuses ~w(active disabled)

  schema "skills" do
    field :name, :string
    field :version, :integer, default: 1
    field :source, :string
    field :scope, :string
    field :path, :string
    field :frontmatter, :map, default: %{}
    field :body_hash, :string
    field :status, :string, default: "active"
    field :scan_result, :map, default: %{}
    timestamps(type: :utc_datetime_usec)
  end

  @doc "The statuses."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc false
  def changeset(row, attrs) do
    row
    |> cast(attrs, [
      :name,
      :version,
      :source,
      :scope,
      :path,
      :frontmatter,
      :body_hash,
      :status,
      :scan_result
    ])
    |> validate_required([:name, :source, :scope, :path, :body_hash, :status])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:name, :source])
  end
end
