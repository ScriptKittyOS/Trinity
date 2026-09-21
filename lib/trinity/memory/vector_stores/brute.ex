# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.VectorStores.Brute do
  @moduledoc """
  The SQLite vector store (slice 032): vectors as float32 bytes on `memories.embedding`,
  a search loads the filter's rows (a persona's semantic tier, the named scopes, the
  embedder in force's model) and scores them in Elixir by cosine. Measured at G3 for 10,000
  rows; docs/02 puts brute force at fine to about 10^5, and hnswlib is the step after.
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
          e.embedding_model == ^model and not is_nil(e.embedding)
    )
    |> Repo.all()
    |> Enum.map(fn e ->
      %{id: e.id, score: Embedder.cosine(query, Embedder.from_binary(e.embedding)), entry: e}
    end)
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(k)
  end

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
            e.embedding_model == ^model and not is_nil(e.embedding)
      ),
      :count
    )
  end
end
