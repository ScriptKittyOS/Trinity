# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.VectorStoreTest do
  @moduledoc """
  Slice 032, AC1: 1,000 fake vectors through the store in force (`Brute` on SQLite,
  `Pgvector` on the postgres job), the known nearest in order; the scope filter (M6) and the
  model filter (NOTES decision 4) hold.
  """
  use Trinity.DataCase, async: false

  alias Trinity.Factory
  alias Trinity.Memory.{AlwaysOn, Embedder, Embedders.Fake, Semantic, VectorStore}

  setup do
    persona = Factory.persona!()
    {:ok, persona: persona, scope: AlwaysOn.persona_scope(persona.id)}
  end

  defp add!(persona, scope, key, body, opts \\ [by: "test"]) do
    {:ok, e} = Semantic.add(%{persona_id: persona.id, scope: scope, key: key, body: body}, opts)
    e
  end

  test "AC1: 1,000 vectors, search/3 returns the known nearest with correct ordering", %{
    persona: persona,
    scope: scope
  } do
    texts = for i <- 1..1_000, do: "fact number #{i}"
    ids = for {t, i} <- Enum.with_index(texts, 1), do: add!(persona, scope, "fact-#{i}", t).id
    filter = Semantic.filter(persona.id, [scope])
    assert VectorStore.count(filter) == 1_000

    # The expected order comes from the same cosine over the same vectors, computed here.
    query = Fake.vector("fact number 500")

    expected =
      texts
      |> Enum.zip(ids)
      |> Enum.map(fn {t, id} -> {id, Embedder.cosine(query, Fake.vector(t))} end)
      |> Enum.sort_by(&elem(&1, 1), :desc)
      |> Enum.take(10)

    hits = VectorStore.search(query, 10, filter)
    assert Enum.map(hits, & &1.id) == Enum.map(expected, &elem(&1, 0))
    assert hd(hits).entry.body == "fact number 500"
    assert_in_delta hd(hits).score, 1.0, 1.0e-5

    for {hit, {_, score}} <- Enum.zip(hits, expected),
        do: assert_in_delta(hit.score, score, 1.0e-5)

    assert hits == Enum.sort_by(hits, & &1.score, :desc)
    # The store in force is the adapter's (compile time); the postgres job's log names it.
    assert VectorStore.impl() in [
             Trinity.Memory.VectorStores.Brute,
             Trinity.Memory.VectorStores.Pgvector
           ]

    IO.puts("\nAC1 store in force: #{inspect(VectorStore.impl())}")
  end

  test "the scope filter is required and binds: a row outside the named scopes is never a hit (M6)",
       %{persona: persona, scope: scope} do
    a = add!(persona, scope, "a", "the same text")
    b = add!(persona, "global", "a", "the same text")
    query = Fake.vector("the same text")

    assert Enum.map(VectorStore.search(query, 5, Semantic.filter(persona.id, [scope])), & &1.id) ==
             [a.id]

    assert Enum.map(
             VectorStore.search(query, 5, Semantic.filter(persona.id, ["global"])),
             & &1.id
           ) == [b.id]

    assert Enum.sort(
             Enum.map(
               VectorStore.search(query, 5, Semantic.filter(persona.id, [scope, "global"])),
               & &1.id
             )
           ) == Enum.sort([a.id, b.id])

    assert VectorStore.search(query, 5, Semantic.filter(persona.id, [])) == []

    assert_raise FunctionClauseError, fn ->
      VectorStore.search(query, 5, %{persona_id: persona.id})
    end
  end

  test "another persona's rows are not hits", %{persona: persona, scope: scope} do
    other = Factory.persona!()
    add!(other, AlwaysOn.persona_scope(other.id), "a", "shared words")

    assert VectorStore.search(
             Fake.vector("shared words"),
             5,
             Semantic.filter(persona.id, [scope, AlwaysOn.persona_scope(other.id)])
           ) == []
  end

  test "vectors of another model are never mixed in (decision 4)", %{
    persona: persona,
    scope: scope
  } do
    e = add!(persona, scope, "a", "one text")
    query = Fake.vector("one text")
    assert [%{id: id}] = VectorStore.search(query, 5, Semantic.filter(persona.id, [scope]))
    assert id == e.id

    :ok = VectorStore.upsert(e.id, query, "other:model-384")
    assert VectorStore.search(query, 5, Semantic.filter(persona.id, [scope])) == []
    assert VectorStore.count(Semantic.filter(persona.id, [scope])) == 0

    assert VectorStore.count(%{persona_id: persona.id, scopes: [scope], model: "other:model-384"}) ==
             1
  end

  test "delete/1 clears the vector and the row stays; upsert on a missing row is an error", %{
    persona: persona,
    scope: scope
  } do
    e = add!(persona, scope, "a", "one text")
    :ok = VectorStore.delete(e.id)
    assert %{embedding: nil, embedding_model: nil, embedding_dim: nil} = Trinity.Repo.reload!(e)

    assert VectorStore.search(Fake.vector("one text"), 5, Semantic.filter(persona.id, [scope])) ==
             []

    assert {:error, :no_such_entry} =
             VectorStore.upsert(Ecto.UUID.generate(), Fake.vector("x"), "fake")
  end

  test "the row records the embedder that produced its vector, float32 little-endian", %{
    persona: persona,
    scope: scope
  } do
    e = add!(persona, scope, "a", "one text")
    assert e.embedding_model == "fake:sha256-384"
    assert e.embedding_dim == 384
    assert byte_size(e.embedding) == 384 * 4
    stored = Embedder.from_binary(e.embedding)
    for {x, y} <- Enum.zip(stored, Fake.vector("one text")), do: assert_in_delta(x, y, 1.0e-6)
  end
end
