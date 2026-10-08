# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.Vector do
  @moduledoc """
  One row of `memory_embeddings` (slice 133): a memory's vector in one space, keyed
  `(memory_id, space_id)`. `vector` is the bytes in the space's encoding (float32 little-endian,
  or int8 for an int8 space: `Trinity.Memory.Space.encode_vector/2`) and `dim` its width. On
  Postgres the same vector is also in the untyped `embedding_vector` column, which this schema
  does not map: only `Trinity.Memory.VectorStores.Pgvector` reads and writes it.
  """
  use Ecto.Schema

  @primary_key false
  @foreign_key_type Trinity.UUID

  @type t :: %__MODULE__{}

  schema "memory_embeddings" do
    field :memory_id, Trinity.UUID, primary_key: true
    field :space_id, :string, primary_key: true
    field :dim, :integer
    field :vector, :binary
    field :inserted_at, :utc_datetime_usec
  end
end
