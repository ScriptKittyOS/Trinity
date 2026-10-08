# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.SpaceRow do
  @moduledoc """
  One row of `embedding_spaces` (slice 133): a space this store has held vectors in, its
  manifest (`Trinity.Memory.Space`), whether it is complete (every semantic memory embedded in
  it) or still being built by a re-tier, and whether it is the store's active space. At most one
  row is active; the database refuses a second (`embedding_spaces_one_active`).
  """
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "embedding_spaces" do
    field :manifest, :map
    field :dim, :integer
    field :quantization, :string
    field :state, :string, default: "complete"
    field :active, :boolean, default: false
    field :completed_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  @doc "The space this row records."
  @spec space(t()) :: Trinity.Memory.Space.t()
  def space(%__MODULE__{manifest: m}), do: Trinity.Memory.Space.from_manifest(m)
end
