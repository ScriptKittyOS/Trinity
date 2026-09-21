# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.Entry do
  @moduledoc """
  One row of `memories` (slice 030, docs/05): a tier (`profile`, `always_on`; `semantic` at
  032), a scope (`global`, `persona:<id>`, `project:<path>`, `session:<id>`), a short stable
  key unique within tier and scope, and a body.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Trinity.UUID, autogenerate: true}
  @foreign_key_type Trinity.UUID

  @type t :: %__MODULE__{}

  @tiers ~w(profile always_on semantic)
  @always_on_tiers ~w(profile always_on)

  schema "memories" do
    field :persona_id, Trinity.UUID
    field :tier, :string
    field :scope, :string
    field :key, :string
    field :body, :string
    field :source_message_id, Trinity.UUID
    field :confidence, :float
    field :last_used_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  @doc "The tiers."
  @spec tiers() :: [String.t()]
  def tiers, do: @tiers

  @doc "The two tiers the snapshot renders and the budget counts."
  @spec always_on_tiers() :: [String.t()]
  def always_on_tiers, do: @always_on_tiers

  @doc false
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :persona_id,
      :tier,
      :scope,
      :key,
      :body,
      :source_message_id,
      :confidence,
      :last_used_at
    ])
    |> validate_required([:persona_id, :tier, :scope, :key, :body])
    |> validate_inclusion(:tier, @always_on_tiers)
    |> validate_format(:key, ~r/^[a-z0-9][a-z0-9_.-]{0,63}$/,
      message: "a short stable key: lowercase, digits, _ . -"
    )
    |> validate_length(:body, min: 1, max: 4_000)
    |> validate_format(:scope, ~r/^(global|persona:[^\s]+|project:[^\s]+|session:[^\s]+)$/)
    |> unique_constraint([:tier, :scope, :key])
  end

  @doc "Bytes an entry costs the budget: its key and body."
  @spec bytes(t()) :: non_neg_integer()
  def bytes(%__MODULE__{key: k, body: b}), do: byte_size(k) + byte_size(b)
end
