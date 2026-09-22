# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.VectorStores.Brute do
  @moduledoc """
  The SQLite vector store (slice 032): vectors as float32 bytes on `memories.embedding`,
  a search loads the filter's rows (a persona's semantic tier, the named scopes, the
  embedder in force's model) and scores them by cosine: as one matrix product on EXLA when
  the NIF is loaded (the local embedder's own backend), in Elixir over decoded lists when
  it is not (the hosted embedder on a machine without EXLA). Measured at G3 over 10,000
  rows (docs/perf.md): loading the rows 93 ms, the Elixir cosine 571 ms, the EXLA product
  6 ms after its first compile for that row count (102 ms). docs/02's "fine to about 10^5"
  holds for the product, not for the Elixir path; hnswlib is the step after.
  """
  @behaviour Trinity.Memory.VectorStore

  import Ecto.Query

  alias Trinity.Memory.{Embedder, Entry}
  alias Trinity.Repo

  @impl true
  def upsert(id, vector, model) when is_list(vector) do
    {n, _} =
      Repo.update_all(from(e in Entry, where: e.id == ^id),
        set: [
          embedding: Embedder.to_binary(vector),
          embedding_model: model,
          embedding_dim: length(vector)
        ]
      )

    if n == 1, do: :ok, else: {:error, :no_such_entry}
  end

  @impl true
  def search(query, k, %{persona_id: persona_id, scopes: scopes, model: model})
      when is_list(query) do
    from(e in Entry,
      where:
        e.persona_id == ^persona_id and e.tier == "semantic" and e.scope in ^scopes and
          e.embedding_model == ^model and not is_nil(e.embedding) and is_nil(e.archived_at)
    )
    |> Repo.all()
    |> score(query)
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(k)
  end

  @doc "Cosine of the query against every row's vector, as hits; the EXLA product when the NIF is loaded, Elixir otherwise."
  @spec score([Entry.t()], Embedder.vector()) :: [Trinity.Memory.VectorStore.hit()]
  def score([], _query), do: []

  def score(rows, query) do
    scores = if exla?(), do: exla_scores(rows, query), else: elixir_scores(rows, query)
    Enum.zip_with(rows, scores, fn e, s -> %{id: e.id, score: s, entry: e} end)
  end

  @doc "Cosines in Elixir over decoded lists (the path without EXLA); public so the suite can hold the two paths to the same numbers."
  @spec elixir_scores([Entry.t()], Embedder.vector()) :: [float()]
  def elixir_scores(rows, query),
    do: Enum.map(rows, &Embedder.cosine(query, Embedder.from_binary(&1.embedding)))

  @doc "Cosines as one (rows x dim) . dim product on the EXLA host client; a row of another width scores 0.0, as `cosine/2` refuses it."
  @spec exla_scores([Entry.t()], Embedder.vector()) :: [float()]
  def exla_scores(rows, query) do
    dim = length(query)
    fit = Enum.filter(rows, &(byte_size(&1.embedding) == dim * 4))
    scores = if fit == [], do: %{}, else: product(fit, query, dim)
    Enum.map(rows, &Map.get(scores, &1.id, 0.0))
  end

  defp product(fit, query, dim) do
    m =
      fit
      |> Enum.map(& &1.embedding)
      |> IO.iodata_to_binary()
      |> Nx.from_binary(:f32, backend: EXLA.Backend)
      |> Nx.reshape({length(fit), dim})

    q = Nx.tensor(query, type: :f32, backend: EXLA.Backend)
    norms = Nx.multiply(Nx.LinAlg.norm(m, axes: [1]), Nx.LinAlg.norm(q))

    m
    |> Nx.dot(q)
    |> Nx.divide(Nx.select(Nx.equal(norms, 0.0), 1.0, norms))
    |> Nx.to_flat_list()
    |> then(&Map.new(Enum.zip(Enum.map(fit, fn e -> e.id end), &1)))
  end

  defp exla?,
    do: Code.ensure_loaded?(EXLA.Backend) and Trinity.Memory.Embedders.Bumblebee.exla() == :ok

  @impl true
  def delete(id) do
    Repo.update_all(from(e in Entry, where: e.id == ^id),
      set: [embedding: nil, embedding_model: nil, embedding_dim: nil]
    )

    :ok
  end

  @impl true
  def count(%{persona_id: persona_id, scopes: scopes, model: model}) do
    Repo.aggregate(
      from(e in Entry,
        where:
          e.persona_id == ^persona_id and e.tier == "semantic" and e.scope in ^scopes and
            e.embedding_model == ^model and not is_nil(e.embedding) and is_nil(e.archived_at)
      ),
      :count
    )
  end
end
