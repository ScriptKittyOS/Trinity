# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.VectorStore do
  @moduledoc """
  Where semantic memories' vectors live and how they are searched (slice 032). The scope
  filter is a required argument of `search/3` (M6): a search never sees a scope the caller
  did not name. The store in force is the adapter's: `Brute` on SQLite (the persona's rows
  of the embedder in force loaded and scored in Elixir; docs/02: fine to about 10^5) and
  `Pgvector` on Postgres. Both search only rows whose `embedding_model` is the embedder in
  force's (NOTES decision 4).
  """

  @type hit :: %{id: String.t(), score: float(), entry: Trinity.Memory.Entry.t()}
  @type filter :: %{persona_id: String.t(), scopes: [String.t()], model: String.t()}

  @doc "Stores a vector on an existing semantic memory row."
  @callback upsert(entry_id :: String.t(), vector :: [float()], model :: String.t()) ::
              :ok | {:error, term()}

  @doc "The `k` nearest rows by cosine within the filter, best first."
  @callback search(query :: [float()], k :: pos_integer(), filter()) :: [hit()]

  @doc "Removes a row's vector (the row itself is `AlwaysOn.remove/2`'s to remove)."
  @callback delete(entry_id :: String.t()) :: :ok

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
  @spec upsert(String.t(), [float()], String.t()) :: :ok | {:error, term()}
  def upsert(id, vector, model), do: impl().upsert(id, vector, model)

  @doc "Delegates to the store in force."
  @spec search([float()], pos_integer(), filter()) :: [hit()]
  def search(query, k, filter), do: impl().search(query, k, filter)

  @doc "Delegates to the store in force."
  @spec delete(String.t()) :: :ok
  def delete(id), do: impl().delete(id)

  @doc "Delegates to the store in force."
  @spec count(filter()) :: non_neg_integer()
  def count(filter), do: impl().count(filter)
end
