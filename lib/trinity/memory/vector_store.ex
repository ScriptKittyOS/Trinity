# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.VectorStore do
  @moduledoc """
  How semantic memories' vectors are searched (slice 032; slice 133 for spaces). The scope filter
  is a required argument of `search/3` (M6): a search never sees a scope the caller did not
  name. Slice 133: the filter also names **one space**, and a search ranks only that space's
  vectors (`memory_embeddings` rows keyed `(memory_id, space_id)`). Vectors are written by
  `Trinity.Memory.Spaces.put_vector/5`, the one writer for both adapters.

  **A store refuses rather than ranks.** Before a search ranks anything it counts the space's
  rows whose recorded width or byte length disagrees with the space; any such row is
  `{:error, {:mixed_space, n}}` and nothing is returned. A row with the right width but another
  model's numbers cannot be told from the row itself; the `(memory_id, space_id)` key and the
  single writer are what keep those out.

  The store in force is the adapter's: `Brute` on SQLite (rows loaded and scored in Elixir: an
  int8 space always by `Trinity.Memory.Scorer`, a float32 space by EXLA's product where that NIF
  loads), `Pgvector` on Postgres (each space's own partial HNSW index).
  """

  @type hit :: %{
          id: String.t(),
          score: float(),
          entry: Trinity.Memory.Entry.t(),
          space_id: String.t()
        }
  @type filter :: %{
          persona_id: String.t(),
          scopes: [String.t()],
          space: Trinity.Memory.SpaceRow.t()
        }

  @doc "The `k` nearest rows by cosine within the filter's persona, scopes and space, best first."
  @callback search(query :: [float()], k :: pos_integer(), filter()) ::
              {:ok, [hit()]} | {:error, term()}

  @doc "How many vectors the filter holds."
  @callback count(filter()) :: non_neg_integer()

  @adapter Application.compile_env(:trinity, :db_adapter, Ecto.Adapters.SQLite3)

  @doc "The store for this build's adapter."
  @spec impl() :: module()
  if @adapter == Ecto.Adapters.Postgres do
    def impl, do: Trinity.Memory.VectorStores.Pgvector
  else
    def impl, do: Trinity.Memory.VectorStores.Brute
  end

  @doc "Delegates to the store in force."
  @spec search([float()], pos_integer(), filter()) :: {:ok, [hit()]} | {:error, term()}
  def search(query, k, filter), do: impl().search(query, k, filter)

  @doc "Delegates to the store in force."
  @spec count(filter()) :: non_neg_integer()
  def count(filter), do: impl().count(filter)

  @doc """
  How many of a space's rows disagree with it (a width other than the space's, or a byte
  length its encoding cannot have). Both stores ask this before ranking.
  """
  @spec misfits(Trinity.Memory.SpaceRow.t()) :: non_neg_integer()
  def misfits(%Trinity.Memory.SpaceRow{id: id, dim: dim, quantization: q}) do
    import Ecto.Query
    bytes = Trinity.Memory.Space.vector_bytes(q, dim)

    Trinity.Repo.aggregate(
      from(v in Trinity.Memory.Vector,
        where: v.space_id == ^id and (v.dim != ^dim or fragment("length(?)", v.vector) != ^bytes)
      ),
      :count
    )
  end
end
