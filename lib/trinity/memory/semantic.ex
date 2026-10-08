# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.Semantic do
  @moduledoc """
  The semantic tier (slice 032): unbounded rows of `memories` with `tier: "semantic"`, each
  with a vector, written by the observer after a turn and read by the retriever and the `recall`
  tool. Every write is a row in the change log, as the always-on tiers' are (030).

  **Slice 133: one active space, served or OFF.** Vectors live in `memory_embeddings` under the
  space that produced them (`Trinity.Memory.Space`), and the store has exactly one active space
  (`Trinity.Memory.Spaces`). The store is served by the configured embedder whose space is the
  active one, and by nothing else: when no configured embedder writes the active space, semantic
  memory is OFF with `{:space_mismatch, ...}`, the pointer stays, and nothing is re-embedded
  (D3). `status/0` is the one answer, from four places, in this order:

  1. **Configuration** (`Trinity.Memory.EmbedderConfig`): a declared locality that is missing or
     wrong is `{:off, {:config, reason}}` (under `:regulated` the boot refused it already).
  2. **The pointer**: `{:off, {:space_mismatch, ...}}`, or `{:off, :no_active_space}` for a store
     holding vectors and no active space.
  3. **The embedder**: its `availability/0` (`:weights_missing`, `:weights_digest_mismatch`,
     `:model_missing`, ...).
  4. **The last runtime fault** (`:endpoint_unreachable`, `{:mixed_space, n}`), recorded when an
     embed or a search fails and cleared by the next that succeeds.

  When the tier is off the observer and the retriever stand down and full-text recall goes on
  (NOTES decision 3); nothing is rerouted to another embedder or another space.
  """

  import Ecto.Query

  alias Trinity.Memory.{
    AlwaysOn,
    Embedder,
    EmbedderConfig,
    Entry,
    Space,
    SpaceRow,
    Spaces,
    VectorStore
  }

  alias Trinity.Repo

  @adapter Application.compile_env(:trinity, :db_adapter, Ecto.Adapters.SQLite3)
  @fault_key {__MODULE__, :fault}

  @type status :: :on | {:off, term()}

  @typedoc "What serves the store: the embedder, its space, and the active row (nil before the first pin)."
  @type serving :: %{
          module: module(),
          space: Space.t(),
          space_id: Space.id(),
          row: SpaceRow.t() | nil
        }

  @doc "The tier's status now."
  @spec status() :: status()
  def status do
    with {:ok, %{space_id: id}} <- ready(),
         nil <- fault(id) do
      :on
    else
      {:off, reason} -> {:off, reason}
      {:fault, reason} -> {:off, reason}
    end
  end

  # Everything but the runtime fault: configuration, the pointer, the embedder's availability.
  # An embed or a search is attempted on this, so the attempt that succeeds is what clears a
  # fault (an endpoint that came back, a store whose odd row was removed).
  defp ready do
    case serving() do
      {:ok, %{module: module} = s} ->
        with :ok <- module.availability(),
             :ok <- serving_started(module) do
          {:ok, s}
        end

      {:off, reason} ->
        {:off, reason}
    end
  end

  @doc "True when the tier is on."
  @spec on?() :: boolean()
  def on?, do: status() == :on

  @doc """
  What serves the store, or why nothing does: the configured embedder whose space is active;
  before the first pin of an empty store, the first configured embedder.
  """
  @spec serving() :: {:ok, serving()} | {:off, term()}
  def serving do
    with :ok <- config_check() do
      modules = Embedder.modules()
      spaces = Enum.map(modules, fn m -> {m, m.space()} end)

      case Spaces.active() do
        nil -> unpinned(spaces)
        %SpaceRow{} = row -> pinned(spaces, row)
      end
    end
  end

  # No active space: an empty store is served by the first configured embedder (its first
  # write pins it); a store holding vectors is not served until an operator pins it.
  defp unpinned([{m, space} | _]) do
    if Spaces.empty?(),
      do: {:ok, %{module: m, space: space, space_id: Space.id(space), row: nil}},
      else: {:off, :no_active_space}
  end

  defp pinned(spaces, %SpaceRow{id: active} = row) do
    case Enum.find(spaces, fn {_, space} -> Space.id(space) == active end) do
      {m, space} ->
        {:ok, %{module: m, space: space, space_id: active, row: row}}

      nil ->
        configured = Enum.map(spaces, fn {_, sp} -> Space.short(Space.id(sp)) end)
        {:off, {:space_mismatch, %{active: Space.short(active), configured: configured}}}
    end
  end

  defp config_check do
    case EmbedderConfig.check(
           Trinity.Profile.current(),
           Application.get_env(:trinity, :memory, []),
           Application.get_env(:trinity, :llm, []) |> Keyword.get(:models, []),
           Trinity.Profile.raw_endpoints()
         ) do
      :ok -> :ok
      {:error, reason} -> {:off, {:config, reason}}
    end
  end

  @doc "The status as a sentence for a page or a tool."
  @spec describe(status()) :: String.t()
  def describe(:on) do
    case serving() do
      {:ok, %{module: m, space_id: id}} ->
        "semantic recall is on (#{m.model_id()}, space #{Space.short(id)})"

      _ ->
        "semantic recall is on"
    end
  end

  def describe({:off, :model_missing}),
    do: "semantic recall is unavailable: the local model is not downloaded"

  def describe({:off, :no_local_backend}),
    do: "semantic recall is unavailable on this platform: no local embedding backend yet"

  def describe({:off, :not_configured}),
    do: "semantic recall is unavailable: the hosted embedder is not configured"

  def describe({:off, :serving_not_started}),
    do: "semantic recall is unavailable: the embedding serving is not running"

  def describe({:off, :weights_missing}),
    do: "semantic recall is unavailable: the static embedder's weights are not installed"

  def describe({:off, :weights_digest_mismatch}),
    do: "semantic recall is unavailable: the static embedder's weights failed their digest check"

  def describe({:off, :endpoint_unreachable}),
    do: "semantic recall is unavailable: the embedder's endpoint is unreachable"

  def describe({:off, {:space_mismatch, %{active: a}}}),
    do:
      "semantic recall is unavailable: the store is pinned to space #{a} and no configured " <>
        "embedder writes it (an operator re-tier changes the space)"

  def describe({:off, {:mixed_space, n}}),
    do: "semantic recall is unavailable: #{n} stored vector(s) do not fit the active space"

  def describe({:off, {:config, reason}}),
    do:
      "semantic recall is unavailable: the embedder configuration is refused (#{inspect(reason)})"

  def describe({:off, reason}), do: "semantic recall is unavailable: #{inspect(reason)}"

  @doc """
  The serving space's thresholds (`Trinity.Memory.Embedder.thresholds/0`), with
  `config :trinity, :memory, dedupe_cosine:` and `recall_min_cosine:` as explicit overrides.
  The first configured embedder's when nothing serves.
  """
  @spec thresholds() :: %{floor: float(), dedupe: float()}
  def thresholds do
    module =
      case serving() do
        {:ok, %{module: m}} -> m
        _ -> Embedder.impl()
      end

    config = Application.get_env(:trinity, :memory, [])
    base = module.thresholds()

    %{
      floor: Keyword.get(config, :recall_min_cosine) || base.floor,
      dedupe: Keyword.get(config, :dedupe_cosine) || base.dedupe
    }
  end

  @doc """
  Embeds texts for the store: through the serving embedder, tagged with the space the vectors
  belong to. A failure is recorded as the tier's runtime fault (an endpoint error as
  `:endpoint_unreachable`); a success clears it.
  """
  @spec embed([String.t()]) :: {:ok, [Embedder.vector()], Space.id()} | {:error, term()}
  def embed(texts) do
    with {:ok, %{module: m, space_id: id}} <- serving_on() do
      case m.embed(texts) do
        {:ok, vectors} ->
          clear_fault(id, :embed)
          {:ok, vectors, id}

        {:error, reason} ->
          {:error, put_fault(id, runtime_reason(reason))}
      end
    end
  end

  defp serving_on do
    case ready() do
      {:ok, s} -> {:ok, s}
      {:off, reason} -> {:error, {:embedder_off, reason}}
    end
  end

  defp runtime_reason(%Trinity.LLM.Error{transient?: true}), do: :endpoint_unreachable
  defp runtime_reason({:endpoint_unreachable, _}), do: :endpoint_unreachable
  defp runtime_reason(:endpoint_unreachable), do: :endpoint_unreachable

  defp runtime_reason(%Trinity.LLM.Error{status: status}) when is_integer(status),
    do: {:embed_failed, status}

  defp runtime_reason(other), do: {:embed_failed, other}

  @doc """
  The `k` nearest semantic memories to a query text within a persona's scopes, in the active
  space: `{:ok, hits}` (each hit names its `space_id`), or `{:error, reason}` when the tier is
  off, the embed failed, or the store refused to rank (`{:mixed_space, n}`).
  """
  @spec search(String.t(), [String.t()], String.t(), pos_integer()) ::
          {:ok, [VectorStore.hit()]} | {:error, term()}
  def search(persona_id, scopes, query, k) do
    with {:ok, [vector], space_id} <- embed([query]) do
      search_vector(persona_id, scopes, vector, space_id, k)
    end
  end

  @doc "As `search/4`, for a vector already embedded in `space_id`."
  @spec search_vector(String.t(), [String.t()], Embedder.vector(), Space.id(), pos_integer()) ::
          {:ok, [VectorStore.hit()]} | {:error, term()}
  def search_vector(persona_id, scopes, vector, space_id, k) do
    case Spaces.get(space_id) do
      nil ->
        {:ok, []}

      row ->
        case VectorStore.search(vector, k, filter(persona_id, scopes, row)) do
          {:ok, hits} ->
            clear_fault(space_id, :search)
            {:ok, hits}

          {:error, {:mixed_space, _} = reason} ->
            {:error, put_fault(space_id, reason)}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc "The search filter for a persona, the scopes it may see (M6: never wider) and a space."
  @spec filter(String.t(), [String.t()], SpaceRow.t()) :: VectorStore.filter()
  def filter(persona_id, scopes, %SpaceRow{} = row),
    do: %{persona_id: persona_id, scopes: scopes, space: row}

  @doc """
  Adds a semantic memory: embeds the body through the serving embedder (or takes `vector:` with
  the `space_id:` it was embedded in, the observer's batch), inserts the row, stores the vector
  under the active space and logs the change (`by:`, `session_id:`). An empty store is pinned
  to the serving space on this first write (`Spaces.pin_if_empty/1`). A vector embedded in a
  space that is no longer the active one is embedded again rather than stored under the wrong
  space. `{:error, {:embedder_off, reason}}` when the tier is off; `{:error, :exists}` when the
  key is taken in that scope.
  """
  @spec add(map(), keyword()) :: {:ok, Entry.t()} | {:error, term()}
  def add(attrs, opts) do
    attrs = Map.new(attrs, fn {k, v} -> {to_atom(k), v} end)

    with nil <- AlwaysOn.get("semantic", attrs[:scope], attrs[:key]),
         {:ok, vector, space_id} <- vector_for(attrs[:body], opts),
         {:ok, entry} <- insert(attrs, vector, space_id) do
      AlwaysOn.log(entry, "add", nil, entry.body, Keyword.put_new(opts, :by, "observer"))
      {:ok, Repo.reload!(entry)}
    else
      %Entry{} -> {:error, :exists}
      {:error, reason} -> {:error, reason}
    end
  end

  defp vector_for(body, opts) do
    case {Keyword.get(opts, :vector), Keyword.get(opts, :space_id)} do
      {v, id} when is_list(v) and is_binary(id) ->
        {:ok, v, id}

      _ ->
        with {:ok, [v], id} <- embed([body]), do: {:ok, v, id}
    end
  end

  # One transaction: the row, then the vector under the space that is active now. If the
  # vector was embedded in another space (a re-tier cut over in between), embed again with the
  # serving embedder; on Postgres the active row is read FOR SHARE, so a cutover waits for this.
  defp insert(attrs, vector, space_id) do
    Repo.transaction(fn ->
      {target, space, vector} = target_space(space_id, vector, attrs[:body])

      with {:ok, entry} <- %Entry{} |> Entry.semantic_changeset(attrs) |> Repo.insert(),
           :ok <- Spaces.put_vector(entry.id, target, space, vector) do
        entry
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp target_space(space_id, vector, body) do
    case active_locked() do
      %SpaceRow{id: ^space_id} = row ->
        {space_id, SpaceRow.space(row), vector}

      nil ->
        with {:ok, %{space: space, space_id: ^space_id}} <- serving(),
             {:ok, row} <- Spaces.pin_if_empty(space) do
          {row.id, space, vector}
        else
          other -> Repo.rollback({:not_pinned, other})
        end

      %SpaceRow{} ->
        case embed([body]) do
          {:ok, [v], id} -> {id, SpaceRow.space(Spaces.get(id)), v}
          {:error, reason} -> Repo.rollback(reason)
        end
    end
  end

  if @adapter == Ecto.Adapters.Postgres do
    defp active_locked,
      do: Repo.one(from(s in SpaceRow, where: s.active == true, lock: "FOR SHARE"))
  else
    defp active_locked, do: Spaces.active()
  end

  @doc """
  The nearest existing memory to a vector (embedded in `space_id`) within the scopes, when its
  cosine reaches `threshold`; nil otherwise, and nil when the search refuses.
  """
  @spec near(String.t(), [String.t()], Embedder.vector(), Space.id(), float()) ::
          VectorStore.hit() | nil
  def near(persona_id, scopes, vector, space_id, threshold) do
    case search_vector(persona_id, scopes, vector, space_id, 1) do
      {:ok, [%{score: score} = hit]} when score >= threshold -> hit
      _ -> nil
    end
  end

  ## Runtime faults: the last one per space, until a success clears it

  @doc "The recorded runtime fault for a space, or nil."
  @spec fault(Space.id()) :: term() | nil
  def fault(space_id) do
    case :persistent_term.get(@fault_key, nil) do
      {^space_id, reason} -> {:fault, reason}
      _ -> nil
    end
  end

  @doc false
  @spec put_fault(Space.id(), term()) :: term()
  def put_fault(space_id, reason) do
    if :persistent_term.get(@fault_key, nil) != {space_id, reason} do
      :persistent_term.put(@fault_key, {space_id, reason})
    end

    reason
  end

  @doc "Forgets every recorded runtime fault (a test starting clean)."
  @spec clear_fault(:all) :: :ok
  def clear_fault(:all) do
    if :persistent_term.get(@fault_key, nil) != nil, do: :persistent_term.erase(@fault_key)
    :ok
  end

  # A successful embed clears an embed fault, a successful search a store fault; neither clears
  # the other's, so an endpoint coming back does not hide a store that still refuses to rank.
  defp clear_fault(space_id, kind) do
    case :persistent_term.get(@fault_key, nil) do
      {^space_id, reason} -> if fault_kind(reason) == kind, do: :persistent_term.erase(@fault_key)
      _ -> :ok
    end

    :ok
  end

  defp fault_kind({:mixed_space, _}), do: :search
  defp fault_kind(_), do: :embed

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
  embedder's deterministic vectors on a throwaway persona, in a throwaway space of their own,
  the nearest expected first through the store in force, all rolled back; the store's active
  space is never touched. `{:ok, store}` or `{:error, reason}`.
  """
  @spec smoke() :: {:ok, module()} | {:error, term()}
  def smoke do
    alias Trinity.Memory.Embedders.Fake

    Repo.transaction(fn ->
      {:ok, persona} =
        Trinity.Personas.create(%{name: "smoke-#{System.unique_integer([:positive])}"})

      scope = AlwaysOn.persona_scope(persona.id)
      space = %{Fake.space() | model_id: "smoke:" <> Fake.model_id(), dim: 384}
      {:ok, row} = Spaces.register(space)
      texts = ["the cat sat", "quarterly tax filing", "a dog barked"]

      ids =
        for {t, i} <- Enum.with_index(texts) do
          attrs = %{persona_id: persona.id, scope: scope, key: "k#{i}", body: t}
          {:ok, e} = %Entry{} |> Entry.semantic_changeset(attrs) |> Repo.insert()
          :ok = Spaces.put_vector(e.id, row.id, space, Fake.vector(t))
          e.id
        end

      expected = Enum.at(ids, 2)

      result =
        case VectorStore.search(Fake.vector("a dog barked"), 3, filter(persona.id, [scope], row)) do
          {:ok, [%{id: ^expected, score: score}, _, _]} when score > 0.999 ->
            {:ok, VectorStore.impl()}

          {:ok, hits} ->
            {:error, {:wrong_order, Enum.map(hits, &{&1.entry.body, Float.round(&1.score, 3)})}}

          {:error, reason} ->
            {:error, reason}
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

  defp serving_started(Trinity.Memory.Embedders.Bumblebee) do
    if is_pid(Process.whereis(Trinity.Memory.Embedders.Bumblebee.serving_name())),
      do: :ok,
      else: {:off, :serving_not_started}
  end

  defp serving_started(_), do: :ok

  defp to_atom(k) when is_atom(k), do: k
  defp to_atom(k) when is_binary(k), do: String.to_existing_atom(k)
end
