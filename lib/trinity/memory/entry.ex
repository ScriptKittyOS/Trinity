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
    # Slice 032: the vector, the model that produced it (never mixed: docs/05 § semantic) and
    # its width. `nil` until the observer embeds the row.
    field :embedding, :binary
    field :embedding_model, :string
    field :embedding_dim, :integer
    # Slice 050: the curator's marks. Stale is untouched for a while and still recalled;
    # archived leaves recall and stays in the row (nothing is deleted by the curator).
    field :stale_at, :utc_datetime_usec
    field :archived_at, :utc_datetime_usec
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
      :last_used_at,
      :embedding,
      :embedding_model,
      :embedding_dim
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

  @doc """
  The changeset of a semantic memory (slice 032): the same fields, the tier fixed to
  `semantic`, and `confidence` between 0 and 1. The always-on changeset refuses the tier so
  the `memory` tool and the consolidator cannot write into it; pinning one (`Semantic.pin/2`)
  goes through `changeset/2` with the always-on tier.
  """
  @spec semantic_changeset(t(), map()) :: Ecto.Changeset.t()
  def semantic_changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :persona_id,
      :scope,
      :key,
      :body,
      :source_message_id,
      :confidence,
      :last_used_at,
      :embedding,
      :embedding_model,
      :embedding_dim
    ])
    |> put_change(:tier, "semantic")
    |> validate_required([:persona_id, :scope, :key, :body])
    |> validate_format(:key, ~r/^[a-z0-9][a-z0-9_.-]{0,63}$/,
      message: "a short stable key: lowercase, digits, _ . -"
    )
    |> validate_length(:body, min: 1, max: 4_000)
    |> validate_format(:scope, ~r/^(global|persona:[^\s]+|project:[^\s]+|session:[^\s]+)$/)
    |> validate_number(:confidence, greater_than_or_equal_to: 0, less_than_or_equal_to: 1)
    |> unique_constraint([:tier, :scope, :key])
  end

  @doc "Bytes an entry costs the budget: its key and body."
  @spec bytes(t()) :: non_neg_integer()
  def bytes(%__MODULE__{key: k, body: b}), do: byte_size(k) + byte_size(b)
end
