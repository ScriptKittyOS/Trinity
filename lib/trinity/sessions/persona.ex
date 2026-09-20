# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Sessions.Persona do
  @moduledoc """
  The minimal persona row (slice 010): `name`, `soul`, `model`, `settings`. Slice 030 gives it
  its behaviour; here it exists so a session has an owner to reference.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Trinity.UUID, autogenerate: true}
  @foreign_key_type Trinity.UUID
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "personas" do
    field :name, :string
    field :soul, :string
    field :model, :string
    field :settings, :map, default: %{}
    has_many :sessions, Trinity.Sessions.SessionRow
    timestamps()
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(persona, attrs) do
    persona
    |> cast(attrs, [:name, :soul, :model, :settings])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 100)
    |> unique_constraint(:name)
  end
end
