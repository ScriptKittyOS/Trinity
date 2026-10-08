# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.VectorStores.Brute do
  @moduledoc """
  The SQLite vector store (slice 032; spaces at slice 133): a search loads the filter's rows (a
  persona's semantic tier, the named scopes, one space's vectors from `memory_embeddings`) and
  scores them all.

  * **An int8 space** (the static floor) is scored by `Trinity.Memory.Scorer`, exact int8 cosine,
    in pure Elixir, always: D-scoring makes the floor's path NIF-free, and AC7 holds it to that
    (slice 133 NOTES, R5: before this, the static path loaded EXLA through this module).
  * **A float32 space** (MiniLM) keeps slice 032's choice: one matrix product on EXLA's host
    client when that NIF is loaded, the Elixir cosine over decoded lists when it is not
    (docs/perf.md: at 10^4 rows the product is 24 ms after its compile, the lists 390 ms).

  Before ranking, a space with a row that does not fit it is refused
  (`Trinity.Memory.VectorStore.misfits/1`).
  """
  @behaviour Trinity.Memory.VectorStore

  # The float32 path's EXLA product; a build without the neural group (`TRINITY_WITHOUT_ML=1`)
  # compiles this module with none of these present and never reaches them (`exla?/0`).
  @compile {:no_warn_undefined, [Nx, Nx.LinAlg, EXLA.Backend]}

  import Ecto.Query

  alias Trinity.Memory.{Embedder, Entry, Scorer, Space, SpaceRow, Vector, VectorStore}
  alias Trinity.Repo

  @impl true
  def search(query, k, %{persona_id: persona_id, scopes: scopes, space: %SpaceRow{} = space})
      when is_list(query) do
    case VectorStore.misfits(space) do
      0 ->
        rows = load(persona_id, scopes, space.id)
        {:ok, rows |> rank(query, k, space) |> with_entries()}

      n ->
        {:error, {:mixed_space, n}}
    end
  end

  # The ids and the vectors only: the rows themselves are read for the `k` that rank, not for
  # all of them (at 10^4 rows reading every entry was most of a search's time).
  defp load(persona_id, scopes, space_id) do
    from(e in Entry,
      join: v in Vector,
      on: v.memory_id == e.id and v.space_id == ^space_id,
      where:
        e.persona_id == ^persona_id and e.tier == "semantic" and e.scope in ^scopes and
          is_nil(e.archived_at),
      select: {e.id, v.vector}
    )
    |> Repo.all()
  end

  defp rank([], _query, _k, _space), do: []

  defp rank(rows, query, k, %SpaceRow{quantization: "int8", id: space_id}) do
    rows
    |> Enum.map(fn {id, v} -> {id, v, Scorer.norm2(v), nil} end)
    |> Scorer.exact(Scorer.quantize(query), k)
    |> Enum.map(fn {id, score} -> %{id: id, score: score, space_id: space_id} end)
  end

  defp rank(rows, query, k, %SpaceRow{id: space_id}) do
    ids = Enum.map(rows, &elem(&1, 0))
    scores = if exla?(), do: exla_scores(rows, query), else: elixir_scores(rows, query)

    ids
    |> Enum.zip_with(scores, fn id, s -> %{id: id, score: s, space_id: space_id} end)
    |> Enum.sort_by(&{-&1.score, &1.id})
    |> Enum.take(k)
  end

  defp with_entries([]), do: []

  defp with_entries(hits) do
    ids = Enum.map(hits, & &1.id)
    entries = Map.new(Repo.all(from(e in Entry, where: e.id in ^ids)), &{&1.id, &1})
    for %{id: id} = hit <- hits, entry = entries[id], do: Map.put(hit, :entry, entry)
  end

  @doc "Cosines in Elixir over decoded lists (the float32 path without EXLA), for rows `{id, bytes}`."
  @spec elixir_scores([{term(), binary()}], Embedder.vector()) :: [float()]
  def elixir_scores(rows, query),
    do: Enum.map(rows, fn {_, v} -> Embedder.cosine(query, Space.decode_vector("f32", v)) end)

  @doc "Cosines as one (rows x dim) . dim product on the EXLA host client, for rows `{id, bytes}`."
  @spec exla_scores([{term(), binary()}], Embedder.vector()) :: [float()]
  def exla_scores(rows, query) do
    dim = length(query)

    m =
      rows
      |> Enum.map(&elem(&1, 1))
      |> IO.iodata_to_binary()
      |> Nx.from_binary(:f32, backend: EXLA.Backend)
      |> Nx.reshape({length(rows), dim})

    q = Nx.tensor(query, type: :f32, backend: EXLA.Backend)
    norms = Nx.multiply(Nx.LinAlg.norm(m, axes: [1]), Nx.LinAlg.norm(q))

    m
    |> Nx.dot(q)
    |> Nx.divide(Nx.select(Nx.equal(norms, 0.0), 1.0, norms))
    |> Nx.to_flat_list()
  end

  defp exla?,
    do: Code.ensure_loaded?(EXLA.Backend) and Trinity.Memory.Embedders.Bumblebee.exla() == :ok

  @impl true
  def count(%{persona_id: persona_id, scopes: scopes, space: %SpaceRow{id: space_id}}) do
    Repo.aggregate(
      from(e in Entry,
        join: v in Vector,
        on: v.memory_id == e.id and v.space_id == ^space_id,
        where:
          e.persona_id == ^persona_id and e.tier == "semantic" and e.scope in ^scopes and
            is_nil(e.archived_at)
      ),
      :count
    )
  end
end
