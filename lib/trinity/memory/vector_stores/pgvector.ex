# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.VectorStores.Pgvector do
  @moduledoc """
  The Postgres vector store (slice 032; spaces at slice 133). The vectors are in
  `memory_embeddings.embedding_vector`, an **untyped** pgvector column, so a 256-wide space and a
  384-wide one share the table; each space has its own partial expression HNSW index,
  `((embedding_vector::vector(<dim>)) vector_cosine_ops) WHERE space_id = '<id>'`
  (`Trinity.Memory.Spaces.index_name/1`). A search orders by the same expression under the same
  predicate, with the space id written into the statement as a literal so the planner can match
  the partial index (a bound parameter cannot prove the predicate for a generic plan); the id is
  checked to be 64 lowercase hex before it is ever spliced (`Spaces.valid_id?/1`). AC2's test
  reads the plan with `EXPLAIN`.

  pgvector 0.8's iterative scan (`SET LOCAL hnsw.iterative_scan = strict_order`) keeps a
  filtered query from coming back short (slice 032 NOTES, finding 12). A space wider than HNSW's
  2,000 dimensions has no index and is scored by `Brute`.
  """
  @behaviour Trinity.Memory.VectorStore

  import Ecto.Query

  alias Trinity.Memory.{Entry, SpaceRow, Spaces}
  alias Trinity.Repo

  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @impl true
  def search(query, k, %{persona_id: persona_id, scopes: scopes, space: %SpaceRow{} = space} = f)
      when is_list(query) do
    cond do
      space.dim > 2000 ->
        Trinity.Memory.VectorStores.Brute.search(query, k, f)

      (n = misfits(space)) > 0 ->
        {:error, {:mixed_space, n}}

      true ->
        {:ok, indexed(query, k, persona_id, scopes, space)}
    end
  end

  # `VectorStore.misfits/1`'s rows, and on this store one more kind: a row of an indexed space
  # whose pgvector value is missing or of another width cannot be ranked by the index (its
  # distance is NULL, or the cast fails); it does not fit the space's storage either. Each row
  # counted once.
  defp misfits(%SpaceRow{id: id, dim: dim, quantization: q}) do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM memory_embeddings WHERE space_id = $1 AND (dim <> $2 OR " <>
          "length(vector) <> $3 OR embedding_vector IS NULL OR vector_dims(embedding_vector) <> $2)",
        [id, dim, Trinity.Memory.Space.vector_bytes(q, dim)]
      )

    n
  end

  @doc """
  The SQL a search runs for a space, with its parameters' positions: `$1` the query vector,
  `$2` the persona, `$3` the scopes, `$4` the limit. Public so AC2's test can `EXPLAIN` exactly
  what a search executes.
  """
  @spec sql(SpaceRow.t()) :: String.t()
  def sql(%SpaceRow{id: id, dim: dim}) do
    true = Spaces.valid_id?(id) and is_integer(dim)
    expr = "(v.embedding_vector::vector(#{dim}))"

    "SELECT v.memory_id, 1 - (#{expr} <=> $1::vector(#{dim})) AS score " <>
      "FROM memory_embeddings v JOIN memories e ON e.id = v.memory_id " <>
      "WHERE v.space_id = '#{id}' AND e.persona_id = $2 AND e.tier = 'semantic' " <>
      "AND e.scope = ANY($3) AND e.archived_at IS NULL " <>
      "ORDER BY #{expr} <=> $1::vector(#{dim}) LIMIT $4"
  end

  # The vector is bound as the dequantized floats; for an int8 space those are the stored
  # int8 values' direction, which is all a cosine reads.
  # sobelow_skip reason: SQL.Query: `sql/1` splices only the space ID, checked to be 64 lowercase
  # hex (`Spaces.valid_id?/1`), and the integer width; the planner can match a partial index only
  # to a literal predicate. The query vector, the persona, the scopes and the limit are bound
  # parameters.
  @sobelow_skip ["SQL.Query"]
  defp indexed(query, k, persona_id, scopes, space) do
    params = [Pgvector.new(query), Ecto.UUID.dump!(persona_id), scopes, k]

    {:ok, %{rows: rows}} =
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL hnsw.iterative_scan = strict_order")
        Repo.query!(sql(space), params)
      end)

    ids = Enum.map(rows, fn [id, _] -> Ecto.UUID.load!(id) end)
    entries = Map.new(Repo.all(from(e in Entry, where: e.id in ^ids)), &{&1.id, &1})

    for [id, score] <- rows, id = Ecto.UUID.load!(id), entry = entries[id] do
      %{id: id, score: score * 1.0, entry: entry, space_id: space.id}
    end
  end

  @impl true
  def count(filter), do: Trinity.Memory.VectorStores.Brute.count(filter)
end
