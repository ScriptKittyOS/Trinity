# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.Spaces do
  @moduledoc """
  The store's embedding spaces and its one active space (slice 133, D3-pinning).

  **The active space changes only by the operator's action.** Nothing here is called on a
  boot path, on a failure, or because configuration changed: a store pinned to space A while
  configuration names an embedder for space B answers semantic recall OFF with a named reason
  (`Trinity.Memory.Semantic.status/0`), keeps the pointer where it is, and enqueues nothing. The
  only implicit write is the first pin of an **empty** store (no active space, no vector in
  it), which is not a switch: there is nothing to switch from (NOTES, decision 2).

  **Re-tier** (`retier/2`, `mix trinity.space.retier`) builds the target space beside the active
  one, embedding every semantic memory into it in batches, each batch its own transaction, while
  the store goes on answering from the active space. When no memory lacks a vector in the
  target, one transaction marks it complete and moves the pointer. The old space's rows stay.

  **Drop** (`drop/2`, `mix trinity.space.drop <id> --confirm`) deletes a space's vectors and its
  row; without `confirm: true` it refuses, and it never drops the active space.

  On Postgres each space has its own partial expression HNSW index over the untyped `vector`
  column (`index_name/1`), created when the space is registered.
  """

  import Ecto.Query

  alias Trinity.Memory.{Entry, Space, SpaceRow, Vector}
  alias Trinity.Repo

  require Logger

  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @adapter Application.compile_env(:trinity, :db_adapter, Ecto.Adapters.SQLite3)

  @doc "The active space's row, or nil."
  @spec active() :: SpaceRow.t() | nil
  def active, do: Repo.one(from(s in SpaceRow, where: s.active == true))

  @doc "A space's row by id, or nil."
  @spec get(Space.id()) :: SpaceRow.t() | nil
  def get(id), do: Repo.get(SpaceRow, id)

  @doc "Every space's row with its vector count, the active one first."
  @spec list() :: [%{row: SpaceRow.t(), vectors: non_neg_integer()}]
  def list do
    counts =
      from(v in Vector, group_by: v.space_id, select: {v.space_id, count(v.memory_id)})
      |> Repo.all()
      |> Map.new()

    from(s in SpaceRow, order_by: [desc: s.active, asc: s.inserted_at])
    |> Repo.all()
    |> Enum.map(&%{row: &1, vectors: Map.get(counts, &1.id, 0)})
  end

  @doc "How many vectors a space holds."
  @spec count(Space.id()) :: non_neg_integer()
  def count(id), do: Repo.aggregate(from(v in Vector, where: v.space_id == ^id), :count)

  @doc "True when the store holds no vector in any space."
  @spec empty?() :: boolean()
  def empty?, do: not Repo.exists?(from(v in Vector, select: 1))

  @doc """
  Records a space (idempotent): its row, `state` `"complete"` unless told `"building"`, and on
  Postgres its index. Returns the row as stored.
  """
  @spec register(Space.t(), String.t()) :: {:ok, SpaceRow.t()}
  def register(%Space{} = space, state \\ "complete") when state in ["complete", "building"] do
    id = Space.id(space)

    case get(id) do
      %SpaceRow{} = row ->
        {:ok, row}

      nil ->
        now = DateTime.utc_now()

        row = %SpaceRow{
          id: id,
          manifest: Space.manifest(space),
          dim: space.dim,
          quantization: space.quantization,
          state: state,
          active: false,
          completed_at: if(state == "complete", do: now)
        }

        {:ok, row} = Repo.insert(row, on_conflict: :nothing, conflict_target: :id)
        create_index(id, space.dim)
        {:ok, get(id) || row}
    end
  end

  @doc """
  The first pin of an empty store: when there is no active space and no vector in the store,
  `space` becomes active. `{:ok, row}` when the store is (now) pinned to `space`;
  `{:error, {:pinned_elsewhere, id}}` when it is pinned to another; `{:error, :store_not_empty}`
  when it holds vectors and no active space (only an operator's re-tier pins it then).
  """
  @spec pin_if_empty(Space.t()) :: {:ok, SpaceRow.t()} | {:error, term()}
  def pin_if_empty(%Space{} = space) do
    id = Space.id(space)

    Repo.transaction(fn ->
      case active() do
        %SpaceRow{id: ^id} = row -> row
        %SpaceRow{id: other} -> Repo.rollback({:pinned_elsewhere, other})
        nil -> first_pin(space, id)
      end
    end)
  end

  defp first_pin(space, id) do
    if empty?() do
      {:ok, _} = register(space)
      {1, _} = Repo.update_all(from(s in SpaceRow, where: s.id == ^id), set: [active: true])
      Logger.info("memory: the empty store is pinned to space #{Space.short(id)}")
      get(id)
    else
      Repo.rollback(:store_not_empty)
    end
  end

  @doc """
  Re-tier: builds `embedder`'s space beside the active one and, when it is complete, moves the
  pointer in one transaction. Options: `batch:` (64), `on_batch:` (a function called with the
  running count, for progress and for tests that act mid-build). `{:ok, %{space: id, previous:
  id | nil, embedded: n}}`, or `{:error, reason}`: `:already_active`, an embedder that is not
  available, or an embedding error (the partial space is left `building`, and a re-run resumes it).
  """
  @spec retier(module(), keyword()) :: {:ok, map()} | {:error, term()}
  def retier(embedder, opts \\ []) when is_atom(embedder) do
    space = embedder.space()
    id = Space.id(space)
    previous = active()

    cond do
      previous && previous.id == id ->
        {:error, :already_active}

      (availability = embedder.availability()) != :ok ->
        {:error, {:embedder_unavailable, availability}}

      true ->
        {:ok, _} = register(space, "building")
        build(embedder, space, id, previous, Keyword.get(opts, :batch, 64), opts, 0)
    end
  end

  defp build(embedder, space, id, previous, batch, opts, done) do
    case missing(id, batch) do
      [] ->
        case cutover(id) do
          :ok ->
            Logger.info(
              "memory: re-tier complete, space #{Space.short(id)} active (#{done} embedded)"
            )

            {:ok, %{space: id, previous: previous && previous.id, embedded: done}}

          :more ->
            build(embedder, space, id, previous, batch, opts, done)
        end

      entries ->
        with {:ok, done} <- embed_batch(embedder, entries, id, space, done, opts) do
          build(embedder, space, id, previous, batch, opts, done)
        end
    end
  end

  defp embed_batch(embedder, entries, id, space, done, opts) do
    with {:ok, vectors} <- embedder.embed(Enum.map(entries, & &1.body)) do
      :ok = put_vectors(Enum.zip(Enum.map(entries, & &1.id), vectors), id, space)
      done = done + length(entries)
      if f = opts[:on_batch], do: f.(done)
      {:ok, done}
    end
  end

  # Semantic memories with no vector in the space yet, oldest first.
  defp missing(id, limit) do
    from(e in Entry,
      as: :e,
      where:
        e.tier == "semantic" and
          not exists(
            from(v in Vector,
              where: v.memory_id == parent_as(:e).id and v.space_id == ^id,
              select: 1
            )
          ),
      order_by: [asc: e.inserted_at, asc: e.id],
      limit: ^limit
    )
    |> Repo.all()
  end

  # One transaction: if every semantic memory has a vector in the space, mark it complete and
  # make it the only active space; if a memory arrived since the last batch, say so and build on.
  defp cutover(id) do
    {:ok, result} =
      Repo.transaction(fn ->
        if missing(id, 1) == [] do
          now = DateTime.utc_now()
          Repo.update_all(from(s in SpaceRow, where: s.active == true), set: [active: false])

          {1, _} =
            Repo.update_all(from(s in SpaceRow, where: s.id == ^id),
              set: [active: true, state: "complete", completed_at: now, updated_at: now]
            )

          :ok
        else
          :more
        end
      end)

    result
  end

  @doc """
  Stores a memory's vector in a space (replacing one already there), in the space's encoding;
  on Postgres the untyped `vector` column too, in the same statement. The space's width is
  checked: a vector of another width is refused, never stored under the wrong space.
  """
  @spec put_vector(String.t(), Space.id(), Space.t(), [float()], DateTime.t()) ::
          :ok | {:error, term()}
  def put_vector(memory_id, space_id, %Space{} = space, floats, now \\ DateTime.utc_now()),
    do: put_vectors([{memory_id, floats}], space_id, space, now)

  @doc "`put_vector/5` for many memories at once, in one statement; all refused if one has the wrong width."
  @spec put_vectors([{String.t(), [float()]}], Space.id(), Space.t(), DateTime.t()) ::
          :ok | {:error, term()}
  def put_vectors(pairs, space_id, %Space{dim: dim} = space, now \\ DateTime.utc_now()) do
    case Enum.find(pairs, fn {_, floats} -> length(floats) != dim end) do
      {_, floats} ->
        {:error, {:wrong_width, length(floats), dim}}

      nil ->
        rows =
          for {memory_id, floats} <- pairs do
            row(memory_id, space_id, space, floats, now)
          end

        Repo.insert_all(table(), rows,
          on_conflict: {:replace, replaced()},
          conflict_target: [:memory_id, :space_id]
        )

        :ok
    end
  end

  if @adapter == Ecto.Adapters.Postgres do
    # The pgvector value is the stored vector decoded (for an int8 space, the int8 values'
    # direction, which is all a cosine reads), so the index ranks exactly what the bytes hold.
    defp row(memory_id, space_id, space, floats, now) do
      bytes = Space.encode_vector(space, floats)

      %{
        memory_id: Ecto.UUID.dump!(memory_id),
        space_id: space_id,
        dim: space.dim,
        vector: bytes,
        embedding_vector: Pgvector.new(Space.decode_vector(space, bytes)),
        inserted_at: now
      }
    end

    defp replaced, do: [:vector, :dim, :inserted_at, :embedding_vector]

    # Schemaless, for the column the schema does not map; Postgrex binds by the column's type.
    defp table, do: "memory_embeddings"

    # Built without parallel workers: a parallel HNSW build allocates its working memory in
    # dynamic shared memory, and a container's default 64 MB /dev/shm refuses it ("could not
    # resize shared memory segment", the local pgvector container, 2026-10-08). The index of a
    # new space is built while the space is empty, so a serial build costs nothing here.
    # sobelow_skip reason: SQL.Query: the only thing spliced into the statement is a space ID,
    # checked by `valid_id?/1` to be exactly 64 lowercase hex characters before use, and an integer
    # width; a partial index needs its predicate as a literal, which a bound parameter cannot be.
    @sobelow_skip ["SQL.Query"]
    defp create_index(id, dim) when dim <= 2000 do
      true = valid_id?(id)

      {:ok, _} =
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL max_parallel_maintenance_workers = 0")

          Repo.query!(
            "CREATE INDEX IF NOT EXISTS #{index_name(id)} ON memory_embeddings " <>
              "USING hnsw ((embedding_vector::vector(#{dim})) vector_cosine_ops) WHERE space_id = '#{id}'"
          )
        end)

      :ok
    end

    defp create_index(_id, _dim), do: :ok

    # sobelow_skip reason: SQL.Query: the only thing spliced into the statement is a space ID,
    # checked by `valid_id?/1` to be exactly 64 lowercase hex characters before use, and an integer
    # width; a partial index needs its predicate as a literal, which a bound parameter cannot be.
    @sobelow_skip ["SQL.Query"]
    defp drop_index(id) do
      true = valid_id?(id)
      Repo.query!("DROP INDEX IF EXISTS #{index_name(id)}")
    end
  else
    defp row(memory_id, space_id, space, floats, now) do
      %{
        memory_id: memory_id,
        space_id: space_id,
        dim: space.dim,
        vector: Space.encode_vector(space, floats),
        inserted_at: now
      }
    end

    defp replaced, do: [:vector, :dim, :inserted_at]

    # Through the schema, so the bytes are bound as a BLOB: a schemaless binary reaches SQLite as
    # TEXT, and `length/1` of TEXT counts characters, which the fit check would read as a misfit.
    defp table, do: Vector
    defp create_index(_id, _dim), do: :ok
    defp drop_index(_id), do: :ok
  end

  @doc "The name of a space's HNSW index on Postgres."
  @spec index_name(Space.id()) :: String.t()
  def index_name(id), do: "memory_embeddings_hnsw_" <> binary_part(id, 0, 16)

  @doc "True for a well-formed space ID (64 lowercase hex), the only thing ever spliced into SQL."
  @spec valid_id?(term()) :: boolean()
  def valid_id?(id), do: is_binary(id) and id =~ ~r/\A[0-9a-f]{64}\z/

  @doc """
  Drops a space: its vectors, its index and its row. Refuses without `confirm: true`
  (`{:error, :confirm_required}`), refuses the active space (`{:error, :active}`), and
  `{:error, :not_found}` for an unknown id. A unique prefix of the id (12 characters or more, as
  `list/0` prints them) is accepted. `{:ok, %{space: id, vectors: n}}`.
  """
  @spec drop(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def drop(id_or_prefix, opts \\ []) do
    with {:ok, row} <- resolve(id_or_prefix),
         :ok <- confirmed(opts),
         :ok <- inactive(row) do
      {:ok, n} =
        Repo.transaction(fn ->
          {n, _} = Repo.delete_all(from(v in Vector, where: v.space_id == ^row.id))
          Repo.delete!(row)
          n
        end)

      drop_index(row.id)
      Logger.info("memory: space #{Space.short(row.id)} dropped (#{n} vectors)")
      {:ok, %{space: row.id, vectors: n}}
    end
  end

  defp confirmed(opts),
    do: if(Keyword.get(opts, :confirm) == true, do: :ok, else: {:error, :confirm_required})

  defp inactive(%SpaceRow{active: true}), do: {:error, :active}
  defp inactive(%SpaceRow{}), do: :ok

  @doc "A space by full id or a unique prefix of 12 hex characters or more."
  @spec resolve(String.t()) :: {:ok, SpaceRow.t()} | {:error, term()}
  def resolve(id_or_prefix) when is_binary(id_or_prefix) do
    cond do
      valid_id?(id_or_prefix) ->
        case get(id_or_prefix) do
          nil -> {:error, :not_found}
          row -> {:ok, row}
        end

      id_or_prefix =~ ~r/\A[0-9a-f]{12,63}\z/ ->
        rows = Repo.all(from(s in SpaceRow, where: like(s.id, ^(id_or_prefix <> "%"))))

        case rows do
          [row] -> {:ok, row}
          [] -> {:error, :not_found}
          _ -> {:error, :ambiguous}
        end

      true ->
        {:error, :not_found}
    end
  end
end
