# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.Semantic do
  @moduledoc """
  The semantic tier (slice 032): unbounded rows of `memories` with `tier: "semantic"`, each
  carrying the vector its embedder produced, written by the observer after a turn and read by
  the retriever and the `recall` tool. Every write is a row in the change log, as the
  always-on tiers' are (030).

  Whether the tier is on is `status/0`: the embedder in force can serve. When it cannot, the
  tier is off (the observer and the retriever stand down, the recall tool says so, the memory
  page says "unavailable"), never rerouted to a hosted embedder (NOTES decision 3). The status
  is computed from the embedder's `availability/0` and the serving's presence every time it
  is asked; nothing is cached, so a download changes the answer.
  """

  import Ecto.Query

  alias Trinity.Memory.{AlwaysOn, Embedder, Entry, VectorStore}
  alias Trinity.Repo

  @type status :: :on | {:off, term()}

  @doc "The tier's status now."
  @spec status() :: status()
  def status do
    impl = Embedder.impl()

    case impl.availability() do
      :ok -> if serving?(impl), do: :on, else: {:off, :serving_not_started}
      {:off, reason} -> {:off, reason}
    end
  end

  @doc "True when the tier is on."
  @spec on?() :: boolean()
  def on?, do: status() == :on

  @doc "The status as a sentence for a page or a tool."
  @spec describe(status()) :: String.t()
  def describe(:on), do: "semantic recall is on (#{Embedder.impl().model_id()})"

  def describe({:off, :model_missing}),
    do: "semantic recall is unavailable: the local model is not downloaded"

  def describe({:off, :no_local_backend}),
    do: "semantic recall is unavailable on this platform: no local embedding backend yet"

  def describe({:off, :not_configured}),
    do: "semantic recall is unavailable: the hosted embedder is not configured"

  def describe({:off, :serving_not_started}),
    do: "semantic recall is unavailable: the embedding serving is not running"

  def describe({:off, reason}), do: "semantic recall is unavailable: #{inspect(reason)}"

  @doc "The model id rows written now carry; the filter every search runs under."
  @spec model() :: String.t()
  def model, do: Embedder.impl().model_id()

  @doc "The search filter for a persona and the scopes it may see (M6: never wider)."
  @spec filter(String.t(), [String.t()]) :: VectorStore.filter()
  def filter(persona_id, scopes), do: %{persona_id: persona_id, scopes: scopes, model: model()}

  @doc """
  Adds a semantic memory: embeds the body (or takes `vector:` when the caller embedded it
  already, the observer's batch), inserts the row with its vector and the model that
  produced it, logs the change (`by:`, `session_id:`). `{:error, {:embedder_off, _}}` when the
  tier is off; `{:error, :exists}` when the key is taken in that scope.
  """
  @spec add(map(), keyword()) :: {:ok, Entry.t()} | {:error, term()}
  def add(attrs, opts) do
    attrs = Map.new(attrs, fn {k, v} -> {to_atom(k), v} end)

    with nil <- AlwaysOn.get("semantic", attrs[:scope], attrs[:key]),
         {:ok, [vector]} <- vector_for(attrs[:body], Keyword.get(opts, :vector)),
         {:ok, entry} <- insert(attrs, vector) do
      # The bytes column is on the row already (the changeset); the Postgres store also fills
      # its vector column. `upsert/3` is the one place that knows about both.
      :ok = VectorStore.upsert(entry.id, vector, model())
      AlwaysOn.log(entry, "add", nil, entry.body, Keyword.put_new(opts, :by, "observer"))
      {:ok, Repo.reload!(entry)}
    else
      %Entry{} -> {:error, :exists}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "The nearest existing memory to a vector within the scopes, when its cosine reaches `threshold`."
  @spec near(String.t(), [String.t()], Embedder.vector(), float()) :: VectorStore.hit() | nil
  def near(persona_id, scopes, vector, threshold) do
    case VectorStore.search(vector, 1, filter(persona_id, scopes)) do
      [%{score: score} = hit] when score >= threshold -> hit
      _ -> nil
    end
  end

  @doc "Removes a semantic memory; logged."
  @spec remove(Entry.t(), keyword()) :: {:ok, Entry.t()} | {:error, term()}
  def remove(%Entry{tier: "semantic"} = entry, opts) do
    with {:ok, deleted} <- Repo.delete(entry) do
      AlwaysOn.log(entry, "remove", entry.body, nil, Keyword.put_new(opts, :by, "owner"))
      {:ok, deleted}
    end
  end

  @doc """
  Pins a semantic memory: it becomes an `always_on` entry of the same scope and key through
  `AlwaysOn.add/2` (the budget check and the consolidator apply), and the semantic row goes,
  logged as `pin`. `{:error, :exists}` when the always-on tier has the key already.
  """
  @spec pin(Entry.t(), keyword()) :: {:ok, Entry.t()} | {:error, term()}
  def pin(%Entry{tier: "semantic"} = entry, opts) do
    opts = Keyword.put_new(opts, :by, "owner")

    attrs = %{
      persona_id: entry.persona_id,
      tier: "always_on",
      scope: entry.scope,
      key: entry.key,
      body: entry.body,
      source_message_id: entry.source_message_id,
      confidence: entry.confidence
    }

    with {:ok, pinned} <- AlwaysOn.add(attrs, opts),
         {:ok, _} <- Repo.delete(entry) do
      AlwaysOn.log(entry, "pin", entry.body, "always_on", opts)
      {:ok, pinned}
    end
  end

  @doc "Marks memories as used now (the retriever's hits), so recency decay sees them."
  @spec touch([String.t()]) :: :ok
  def touch([]), do: :ok

  def touch(ids) do
    Repo.update_all(from(e in Entry, where: e.id in ^ids),
      set: [last_used_at: DateTime.utc_now()]
    )

    :ok
  end

  @doc "A persona's semantic memories within the scopes, newest first (`limit:`)."
  @spec entries(String.t(), [String.t()], keyword()) :: [Entry.t()]
  def entries(persona_id, scopes, opts \\ []) do
    from(e in Entry,
      where:
        e.persona_id == ^persona_id and e.tier == "semantic" and e.scope in ^scopes and
          is_nil(e.archived_at),
      order_by: [desc: e.inserted_at],
      limit: ^Keyword.get(opts, :limit, 200)
    )
    |> Repo.all()
  end

  @doc "Every semantic memory of a persona, in all scopes, newest first (`limit:`; the memory page)."
  @spec all(String.t(), keyword()) :: [Entry.t()]
  def all(persona_id, opts \\ []) do
    from(e in Entry,
      where: e.persona_id == ^persona_id and e.tier == "semantic",
      order_by: [desc: e.inserted_at],
      limit: ^Keyword.get(opts, :limit, 200)
    )
    |> Repo.all()
  end

  @doc "How many semantic memories a persona has, in all scopes."
  @spec count(String.t()) :: non_neg_integer()
  def count(persona_id),
    do:
      Repo.aggregate(
        from(e in Entry, where: e.persona_id == ^persona_id and e.tier == "semantic"),
        :count
      )

  @doc "A semantic memory by id."
  @spec get(String.t()) :: Entry.t() | nil
  def get(id), do: Repo.get_by(Entry, id: id, tier: "semantic")

  @doc """
  The packaged binary's vector check (slice 032, AC7, `--smoke`): three rows of the fake
  embedder's deterministic vectors on a throwaway persona, the nearest expected first through
  the store in force, all rolled back. `{:ok, store}` or `{:error, reason}`.
  """
  @spec smoke() :: {:ok, module()} | {:error, term()}
  def smoke do
    alias Trinity.Memory.Embedders.Fake

    Repo.transaction(fn ->
      {:ok, persona} =
        Trinity.Personas.create(%{name: "smoke-#{System.unique_integer([:positive])}"})

      scope = AlwaysOn.persona_scope(persona.id)
      texts = ["the cat sat", "quarterly tax filing", "a dog barked"]

      ids =
        for {t, i} <- Enum.with_index(texts) do
          attrs = %{persona_id: persona.id, scope: scope, key: "k#{i}", body: t}
          {:ok, e} = %Entry{} |> Entry.semantic_changeset(attrs) |> Repo.insert()
          :ok = VectorStore.upsert(e.id, Fake.vector(t), Fake.model_id())
          e.id
        end

      filter = %{persona_id: persona.id, scopes: [scope], model: Fake.model_id()}
      hits = VectorStore.search(Fake.vector("a dog barked"), 3, filter)

      expected = Enum.at(ids, 2)

      result =
        case hits do
          [%{id: ^expected, score: score}, _, _] when score > 0.999 ->
            {:ok, VectorStore.impl()}

          _ ->
            {:error, {:wrong_order, Enum.map(hits, &{&1.entry.body, Float.round(&1.score, 3)})}}
        end

      Repo.rollback(result)
    end)
    |> case do
      {:error, {:ok, store}} -> {:ok, store}
      {:error, {:error, reason}} -> {:error, reason}
      other -> {:error, other}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp vector_for(body, nil), do: Embedder.embed([body])
  defp vector_for(_body, vector) when is_list(vector), do: {:ok, [vector]}

  defp insert(attrs, vector) do
    attrs =
      Map.merge(attrs, %{
        embedding: Embedder.to_binary(vector),
        embedding_model: model(),
        embedding_dim: length(vector)
      })

    %Entry{} |> Entry.semantic_changeset(attrs) |> Repo.insert()
  end

  defp serving?(Trinity.Memory.Embedders.Bumblebee),
    do: is_pid(Process.whereis(Trinity.Memory.Embedders.Bumblebee.serving_name()))

  defp serving?(_), do: true

  defp to_atom(k) when is_atom(k), do: k
  defp to_atom(k) when is_binary(k), do: String.to_existing_atom(k)
end
