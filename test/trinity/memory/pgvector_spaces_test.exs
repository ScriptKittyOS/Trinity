# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.PgvectorSpacesTest do
  @moduledoc """
  Slice 133, AC2: on Postgres a 256-dimension space and a 384-dimension space coexist in one
  table, and each search uses its own partial index, shown by `EXPLAIN`.

  Both spaces' vectors are in `memory_embeddings.embedding_vector`, an untyped `vector` column;
  each space has its index, `((embedding_vector::vector(<dim>)) vector_cosine_ops) WHERE space_id
  = '<id>'`. The plans are read for the exact statement a search runs
  (`Trinity.Memory.VectorStores.Pgvector.sql/1`), with sequential scans disabled for the
  statement so the planner shows whether the index **can** serve it: a partial index whose
  predicate or expression did not match the query would leave a sequential scan in the plan
  whatever the cost.

  `:postgres`: excluded on SQLite, run by the postgres job.
  """
  use Trinity.DataCase, async: false

  @moduletag :postgres

  alias Trinity.{Factory, FakeEmbedderB, Repo}
  alias Trinity.Memory.{AlwaysOn, Embedders.Fake, Entry, Semantic, Spaces, VectorStore}
  alias Trinity.Memory.VectorStores.Pgvector, as: Store

  @rows 3_000

  setup do
    persona = Factory.persona!()
    scope = AlwaysOn.persona_scope(persona.id)

    # Spaces of this test's own: the rows it writes are rolled back, and the dead entries they leave
    # in an HNSW index cost recall to whatever test reads that index next (slice 133 NOTES, F3).
    {:ok, a} = Spaces.register(space_a())
    {:ok, b} = Spaces.register(space_b())

    now = DateTime.utc_now()

    for chunk <- Enum.chunk_every(1..@rows, 500) do
      entries =
        for i <- chunk do
          %{
            id: Trinity.UUID.generate(),
            persona_id: persona.id,
            tier: "semantic",
            scope: scope,
            key: "k#{i}",
            body: "fact #{i}",
            inserted_at: now,
            updated_at: now
          }
        end

      Repo.insert_all(Entry, entries)

      # Both spaces' vectors in the one untyped column, written as `Spaces.put_vector/5` writes
      # them (bytes and the pgvector value), in bulk.
      rows =
        for e <- entries,
            {space, row, v} <- [
              {space_a(), a, va(e.body)},
              {space_b(), b, vb(e.body)}
            ] do
          %{
            memory_id: Ecto.UUID.dump!(e.id),
            space_id: row.id,
            dim: space.dim,
            vector: Trinity.Memory.Space.encode_vector(space, v),
            embedding_vector: Pgvector.new(v),
            inserted_at: now
          }
        end

      Repo.insert_all("memory_embeddings", rows)
    end

    Repo.query!("ANALYZE memory_embeddings")
    Repo.query!("ANALYZE memories")
    {:ok, persona: persona, scope: scope, a: a, b: b}
  end

  defp space_a, do: %{Fake.space() | model_id: "ac2:384"}
  defp space_b, do: %{FakeEmbedderB.space() | model_id: "ac2:256"}
  defp va(text), do: Fake.vector(text, 384, "ac2")
  defp vb(text), do: Fake.vector(text, 256, "ac2")

  defp plan(space, query, persona, scope) do
    {:ok, plan} =
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL hnsw.iterative_scan = strict_order")

        Repo.query!("EXPLAIN " <> Store.sql(space), [
          Pgvector.new(query),
          Ecto.UUID.dump!(persona.id),
          [scope],
          5
        ]).rows
        |> Enum.map_join("\n", &hd/1)
      end)

    plan
  end

  test "AC2: a 256 and a 384 space in one untyped column, each search planned on its own index",
       %{persona: persona, scope: scope, a: a, b: b} do
    %{rows: [[type]]} =
      Repo.query!(
        "SELECT format_type(atttypid, atttypmod) FROM pg_attribute WHERE attrelid = 'memory_embeddings'::regclass AND attname = 'embedding_vector'"
      )

    assert type == "vector"

    %{rows: dims} =
      Repo.query!(
        "SELECT space_id, vector_dims(embedding_vector), count(*) FROM memory_embeddings GROUP BY 1, 2 ORDER BY 2"
      )

    assert dims == [[b.id, 256, @rows], [a.id, 384, @rows]]

    plan_a = plan(a, va("fact 7"), persona, scope)
    plan_b = plan(b, vb("fact 7"), persona, scope)
    shown = &String.replace(&1, ~r/'\[[-0-9.,e]+\]'/, "'[query]'")

    IO.puts(
      "\nAC2 EXPLAIN, the 384 space:\n#{shown.(plan_a)}\n\nAC2 EXPLAIN, the 256 space:\n#{shown.(plan_b)}"
    )

    assert plan_a =~ "Index Scan using #{Spaces.index_name(a.id)}"
    refute plan_a =~ Spaces.index_name(b.id)
    assert plan_b =~ "Index Scan using #{Spaces.index_name(b.id)}"
    refute plan_b =~ Spaces.index_name(a.id)

    # And the searches answer from their own space.
    {:ok, [hit_a | _]} =
      VectorStore.search(va("fact 7"), 5, Semantic.filter(persona.id, [scope], a))

    {:ok, [hit_b | _]} =
      VectorStore.search(
        vb("fact 7"),
        5,
        Semantic.filter(persona.id, [scope], b)
      )

    assert {hit_a.entry.body, hit_a.space_id} == {"fact 7", a.id}
    assert {hit_b.entry.body, hit_b.space_id} == {"fact 7", b.id}
  end

  test "the database refuses a vector of the wrong width under a space's index", %{a: a} do
    %{rows: [[memory_id]]} = Repo.query!("SELECT memory_id FROM memory_embeddings LIMIT 1")

    error =
      catch_error(
        Repo.query!(
          "UPDATE memory_embeddings SET embedding_vector = $1 WHERE memory_id = $2 AND space_id = $3",
          [Pgvector.new(List.duplicate(0.5, 256)), memory_id, a.id]
        )
      )

    assert Exception.message(error) =~ "expected 384 dimensions, not 256"
  end
end
