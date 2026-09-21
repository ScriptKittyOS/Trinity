# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.VectorStores.Pgvector do
  @moduledoc """
  The Postgres vector store (slice 032): the same rows, with the vector also in
  `memories.embedding_vector` (pgvector, `vector(384)`), searched by cosine distance
  (`<=>`) under the HNSW index over the semantic tier, with pgvector 0.8's iterative scan so a
  filtered query never comes back short. Keeps `embedding`, `embedding_model`
  and `embedding_dim` in step with the SQLite store so an export reads the same columns on
  both. Only vectors of 384 dimensions fit the column; another embedder's go to the bytes
  column alone and are searched brute force here too.
  """
  @behaviour Trinity.Memory.VectorStore

  import Ecto.Query

  alias Trinity.Memory.{Embedder, Entry}
  alias Trinity.Repo

  @column_dim 384

  @impl true
  def upsert(id, vector, model) when is_list(vector) do
    bytes = Embedder.to_binary(vector)

    {n, _} =
      Repo.update_all(from(e in Entry, where: e.id == ^id),
        set: [embedding: bytes, embedding_model: model, embedding_dim: length(vector)]
      )

    if n == 1 and length(vector) == @column_dim do
      Repo.query!("UPDATE memories SET embedding_vector = $1 WHERE id = $2", [
        Pgvector.new(vector),
        Ecto.UUID.dump!(id)
      ])
    end

    if n == 1, do: :ok, else: {:error, :no_such_entry}
  end

  @impl true
  def search(query, k, %{persona_id: persona_id, scopes: scopes, model: model})
      when is_list(query) do
    if length(query) == @column_dim do
      vec = Pgvector.new(query)

      from(e in Entry,
        where:
          e.persona_id == ^persona_id and e.tier == "semantic" and e.scope in ^scopes and
            e.embedding_model == ^model and not is_nil(e.embedding),
        order_by: fragment("embedding_vector <=> ?", ^vec),
        limit: ^k,
        select: {e, fragment("1 - (embedding_vector <=> ?)", ^vec)}
      )
      |> all_iterative()
      |> Enum.map(fn {e, score} -> %{id: e.id, score: score * 1.0, entry: e} end)
    else
      Trinity.Memory.VectorStores.Brute.search(query, k, %{
        persona_id: persona_id,
        scopes: scopes,
        model: model
      })
    end
  end

  # An HNSW scan hands back its `ef_search` (40) nearest index entries and the WHERE clause
  # is applied after; a persona's few rows can all fall outside those candidates when the
  # index holds many other entries (other personas' rows, and dead tuples from rolled-back
  # inserts, which is how the postgres job saw two of three rows: run 35604770525). pgvector
  # 0.8's iterative scan keeps walking the index until the LIMIT is met; `SET LOCAL` scopes
  # it to this transaction (a savepoint inside the sandbox's).
  defp all_iterative(query) do
    {:ok, rows} =
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL hnsw.iterative_scan = strict_order")
        Repo.all(query)
      end)

    rows
  end

  @impl true
  def delete(id) do
    Repo.update_all(from(e in Entry, where: e.id == ^id),
      set: [embedding: nil, embedding_model: nil, embedding_dim: nil]
    )

    Repo.query!("UPDATE memories SET embedding_vector = NULL WHERE id = $1", [Ecto.UUID.dump!(id)])

    :ok
  end

  @impl true
  def count(filter), do: Trinity.Memory.VectorStores.Brute.count(filter)
end
