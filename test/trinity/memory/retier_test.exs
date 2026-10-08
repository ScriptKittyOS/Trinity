# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.RetierTest do
  @moduledoc """
  Slice 133, AC4: the operator's re-tier builds the new space beside the old; while it runs over
  10^4 memories, 1,000 concurrent queries each return results from exactly one space; the
  pointer moves in one transaction when the new space is complete; the old space's rows remain
  until `mix trinity.space.drop <id> --confirm`, and the command without `--confirm` refuses. A
  mixed-space row makes the retriever refuse rather than rank, shown by injecting one.

  Embedder A is the suite's fake (384 wide), B is `Trinity.FakeEmbedderB` (256 wide), and the
  configuration names both, B first (`embedder: [Trinity.FakeEmbedderB, :fake]`): the store is
  served by whichever writes the active space, so it answers from A while B is built and from B
  once the pointer moves.

  The queries run in tasks against the sandbox's shared connection, so they interleave with the
  builder's batch transactions rather than running beside them in parallel; the cutover is one
  transaction on that same connection, which is what a query can or cannot observe half of.
  """
  use Trinity.DataCase, async: false

  alias Trinity.{Factory, FakeEmbedderB, Repo}

  alias Trinity.Memory.{
    AlwaysOn,
    Embedders.Fake,
    Entry,
    Retriever,
    Semantic,
    Space,
    Spaces,
    Vector
  }

  @moduletag timeout: 600_000
  # The re-tier writes 10^4 vectors through the sandbox's one connection; on Postgres each also
  # updates an HNSW index, which takes longer than the sandbox's default ownership.
  @moduletag ownership_timeout: 600_000

  @total 10_000
  @mine 100

  setup do
    previous = Application.get_env(:trinity, :memory, [])

    # A's fake is seeded apart from the suite's own, so its space (and on Postgres its HNSW
    # index) is this test's alone: ten thousand rows rolled back leave ten thousand dead index
    # entries behind, and an approximate index that other tests read exactly should not carry them.
    Application.put_env(
      :trinity,
      :memory,
      Keyword.merge(previous, embedder: [FakeEmbedderB, :fake], fake_seed: "retier")
    )

    on_exit(fn ->
      Application.put_env(:trinity, :memory, previous)
      Semantic.clear_fault(:all)
    end)

    me = Factory.persona!()
    others = for _ <- 1..9, do: Factory.persona!()
    {:ok, a} = Spaces.pin_if_empty(Fake.space())
    seed!(me, others, a)
    {:ok, me: me, scope: AlwaysOn.persona_scope(me.id), a: a}
  end

  # 10^4 semantic memories with A's vectors: 100 of them the querying persona's, the rest spread
  # over nine others. Inserted in bulk, as a store that had been running for a while would hold.
  defp seed!(me, others, a) do
    now = DateTime.utc_now()
    owners = List.duplicate(me, @mine) ++ Enum.flat_map(others, &List.duplicate(&1, 1_100))

    owners
    |> Enum.with_index(1)
    |> Enum.chunk_every(1_000)
    |> Enum.each(fn chunk ->
      entries =
        for {p, i} <- chunk do
          %{
            id: Trinity.UUID.generate(),
            persona_id: p.id,
            tier: "semantic",
            scope: AlwaysOn.persona_scope(p.id),
            key: "fact-#{i}",
            body: "fact number #{i} about topic #{rem(i, 37)}",
            inserted_at: now,
            updated_at: now
          }
        end

      Repo.insert_all(Entry, entries)

      # As `Spaces.put_vector/5` writes them: the bytes, and on Postgres the pgvector value.
      Repo.insert_all(
        vector_table(),
        for e <- entries do
          v = Fake.vector(e.body)

          %{
            memory_id: Ecto.UUID.dump!(e.id),
            space_id: a.id,
            dim: 384,
            vector: Space.encode_vector("f32", v),
            inserted_at: now
          }
          |> pg_vector(v)
        end
      )
    end)

    assert Spaces.count(a.id) == @total
  end

  defp postgres?, do: Application.get_env(:trinity, :db_adapter) == Ecto.Adapters.Postgres

  # On Postgres schemaless, to write the pgvector column the schema does not map; on SQLite
  # through the schema, so the bytes are a BLOB (as `Spaces.put_vectors/4` writes them).
  defp vector_table, do: if(postgres?(), do: "memory_embeddings", else: Vector)

  defp pg_vector(row, v) do
    if postgres?(),
      do: Map.put(row, :embedding_vector, Pgvector.new(v)),
      else: Map.update!(row, :memory_id, &Ecto.UUID.load!/1)
  end

  defp spaces_of(persona, scope, i) do
    {:ok, hits} =
      Semantic.search(persona.id, [scope], "fact number #{i} about topic #{rem(i, 37)}", 5)

    hits |> Enum.map(& &1.space_id) |> Enum.uniq()
  end

  test "AC4: a re-tier beside the old space, 1,000 concurrent queries each answered from one space, then the cutover",
       %{me: me, scope: scope, a: a} do
    b_id = Space.id(FakeEmbedderB.space())
    test = self()

    # The builder pauses after its first batch until 500 queries have answered, so at least half
    # the queries run while B is being built; the rest run on while it finishes and cuts over.
    builder =
      Task.async(fn ->
        Spaces.retier(FakeEmbedderB,
          batch: 500,
          on_batch: fn
            500 ->
              send(test, :building)
              receive do: (:go -> :ok)

            _ ->
              :ok
          end
        )
      end)

    assert_receive :building, 60_000
    assert Spaces.get(b_id).state == "building"
    assert Spaces.active().id == a.id

    results =
      1..1_000
      |> Task.async_stream(
        fn i ->
          if i == 500, do: send(builder.pid, :go)
          spaces_of(me, scope, i)
        end,
        max_concurrency: 16,
        timeout: 120_000,
        ordered: false
      )
      |> Enum.map(fn {:ok, spaces} -> spaces end)

    assert {:ok, %{space: ^b_id, previous: previous, embedded: @total}} =
             Task.await(builder, 240_000)

    assert previous == a.id

    # Each query answered, from exactly one space.
    assert length(results) == 1_000
    assert Enum.all?(results, &match?([_], &1)), "a query saw no space or two spaces"
    seen = results |> List.flatten() |> Enum.frequencies()

    IO.puts(
      "\nAC4: 1,000 queries during the re-tier, by the space that answered: #{inspect(seen)}"
    )

    assert Map.get(seen, a.id, 0) >= 499
    assert Map.keys(seen) -- [a.id, b_id] == []

    # The pointer moved, in one transaction: B active and complete, A kept, inactive, whole.
    assert Spaces.active().id == b_id
    assert Spaces.get(b_id).state == "complete"
    assert Spaces.get(a.id).active == false
    assert Spaces.count(a.id) == @total
    assert Spaces.count(b_id) == @total
    assert spaces_of(me, scope, 1) == [b_id]

    # The old space stays until the operator confirms.
    assert {:error, :confirm_required} = Spaces.drop(a.id)
    assert Spaces.count(a.id) == @total

    assert_raise Mix.Error, ~r/--confirm/, fn ->
      Mix.Tasks.Trinity.Space.Drop.run([Space.short(a.id)])
    end

    assert Spaces.count(a.id) == @total
    # The active space cannot be dropped, confirmed or not.
    assert {:error, :active} = Spaces.drop(b_id, confirm: true)

    assert {:ok, %{vectors: @total}} = Spaces.drop(a.id, confirm: true)
    assert Spaces.get(a.id) == nil
    assert Spaces.count(a.id) == 0
  end

  test "AC4: an injected mixed-space row makes the retriever refuse rather than rank", %{
    me: me,
    scope: scope,
    a: a
  } do
    past = Factory.session!(%{persona_id: me.id, title: "Earlier"})
    Factory.message!(past.id, %{role: "user", content: "fact number 3 about topic 3 again"})

    hits = Retriever.relevant(me.id, nil, "fact number 3 about topic 3", touch: false)
    assert Enum.any?(hits, &(&1.kind == :memory))

    # One row filed under the active space with another space's width.
    {:ok, odd} =
      %Entry{}
      |> Entry.semantic_changeset(%{persona_id: me.id, scope: scope, key: "odd", body: "odd one"})
      |> Repo.insert()

    Repo.insert_all(Vector, [
      %{
        memory_id: odd.id,
        space_id: a.id,
        dim: 256,
        vector: Space.encode_vector("f32", FakeEmbedderB.vector("odd one")),
        inserted_at: DateTime.utc_now()
      }
    ])

    assert {:error, {:mixed_space, 1}} = Semantic.search(me.id, [scope], "fact number 3", 5)
    assert Semantic.status() == {:off, {:mixed_space, 1}}

    # Refused, not ranked: no memory hit at all, and the full-text half still answers.
    hits = Retriever.relevant(me.id, nil, "fact number 3 about topic 3", touch: false)
    refute Enum.any?(hits, &(&1.kind == :memory))
    assert Enum.any?(hits, &(&1.kind == :message))

    # The row removed, the next search ranks again and the fault clears.
    Repo.delete_all(from(v in Vector, where: v.memory_id == ^odd.id))
    assert {:ok, [_ | _]} = Semantic.search(me.id, [scope], "fact number 3 about topic 3", 5)
    assert Semantic.status() == :on
  end
end
