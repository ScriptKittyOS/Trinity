# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.VectorStoreTest do
  @moduledoc """
  Slice 032, AC1: 1,000 fake vectors through the store in force (`Brute` on SQLite,
  `Pgvector` on the postgres job), the known nearest in order; the scope filter (M6) holds.
  Slice 133: vectors live in `memory_embeddings` under a space, a search ranks one space, and
  another space's vectors of the same memory are never mixed in.
  """
  use Trinity.DataCase, async: false

  alias Trinity.Factory
  alias Trinity.Memory.{AlwaysOn, Embedder, Embedders.Fake, Semantic, Space, Spaces, VectorStore}

  setup do
    persona = Factory.persona!()
    {:ok, persona: persona, scope: AlwaysOn.persona_scope(persona.id)}
  end

  defp add!(persona, scope, key, body, opts \\ [by: "test"]) do
    {:ok, e} = Semantic.add(%{persona_id: persona.id, scope: scope, key: key, body: body}, opts)
    e
  end

  # The store's active space: the fake's, pinned by the first write of each test.
  defp filter(persona_id, scopes), do: Semantic.filter(persona_id, scopes, Spaces.active())

  defp search!(query, k, filter) do
    {:ok, hits} = VectorStore.search(query, k, filter)
    hits
  end

  test "AC1: 1,000 vectors, search/3 returns the known nearest with correct ordering", %{
    persona: persona,
    scope: scope
  } do
    texts = for i <- 1..1_000, do: "fact number #{i}"
    ids = for {t, i} <- Enum.with_index(texts, 1), do: add!(persona, scope, "fact-#{i}", t).id
    filter = filter(persona.id, [scope])
    assert VectorStore.count(filter) == 1_000

    # The expected order comes from the same cosine over the same vectors, computed here.
    query = Fake.vector("fact number 500")

    expected =
      texts
      |> Enum.zip(ids)
      |> Enum.map(fn {t, id} -> {id, Embedder.cosine(query, Fake.vector(t))} end)
      |> Enum.sort_by(&elem(&1, 1), :desc)
      |> Enum.take(10)

    hits = search!(query, 10, filter)
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

    assert Enum.map(search!(query, 5, filter(persona.id, [scope])), & &1.id) ==
             [a.id]

    assert Enum.map(
             search!(query, 5, filter(persona.id, ["global"])),
             & &1.id
           ) == [b.id]

    assert Enum.sort(
             Enum.map(
               search!(query, 5, filter(persona.id, [scope, "global"])),
               & &1.id
             )
           ) == Enum.sort([a.id, b.id])

    assert search!(query, 5, filter(persona.id, [])) == []

    assert_raise FunctionClauseError, fn ->
      VectorStore.search(query, 5, %{persona_id: persona.id})
    end
  end

  test "another persona's rows are not hits", %{persona: persona, scope: scope} do
    other = Factory.persona!()
    add!(other, AlwaysOn.persona_scope(other.id), "a", "shared words")

    assert search!(
             Fake.vector("shared words"),
             5,
             filter(persona.id, [scope, AlwaysOn.persona_scope(other.id)])
           ) == []
  end

  test "another space's vector of the same memory is never mixed in (slice 133)", %{
    persona: persona,
    scope: scope
  } do
    e = add!(persona, scope, "a", "one text")
    query = Fake.vector("one text")
    a = Spaces.active()
    assert [%{id: id, space_id: space_id}] = search!(query, 5, filter(persona.id, [scope]))
    assert {id, space_id} == {e.id, a.id}

    # The same memory in a second space, 256 wide: two rows, one per space.
    other = %{Fake.space() | model_id: "other:model", dim: 256}
    {:ok, b} = Spaces.register(other)
    :ok = Spaces.put_vector(e.id, b.id, other, Enum.take(query, 256))

    assert [%{space_id: ^space_id}] = search!(query, 5, filter(persona.id, [scope]))

    assert [%{space_id: b_id}] =
             search!(Enum.take(query, 256), 5, Semantic.filter(persona.id, [scope], b))

    assert b_id == b.id
    assert VectorStore.count(filter(persona.id, [scope])) == 1
    assert VectorStore.count(Semantic.filter(persona.id, [scope], b)) == 1

    # A vector of another width is refused at the write, never stored under the space.
    assert {:error, {:wrong_width, 384, 256}} = Spaces.put_vector(e.id, b.id, other, query)
  end

  test "deleting a memory deletes its vectors in every space", %{persona: persona, scope: scope} do
    e = add!(persona, scope, "a", "one text")
    assert Spaces.count(Spaces.active().id) == 1
    {:ok, _} = Semantic.remove(e, by: "test")
    assert Spaces.count(Spaces.active().id) == 0
    assert search!(Fake.vector("one text"), 5, filter(persona.id, [scope])) == []
  end

  test "the vector row records its space, its width and its bytes, float32 little-endian", %{
    persona: persona,
    scope: scope
  } do
    e = add!(persona, scope, "a", "one text")
    row = Trinity.Repo.get_by!(Trinity.Memory.Vector, memory_id: e.id)
    assert row.space_id == Space.id(Fake.space())
    assert row.dim == 384
    assert byte_size(row.vector) == 384 * 4
    stored = Space.decode_vector("f32", row.vector)
    for {x, y} <- Enum.zip(stored, Fake.vector("one text")), do: assert_in_delta(x, y, 1.0e-6)
  end

  test "Semantic.smoke/0 (the packaged binary's vector check) passes on the store in force and leaves nothing behind" do
    before = length(Trinity.Personas.list())
    assert {:ok, store} = Semantic.smoke()
    assert store == VectorStore.impl()
    assert length(Trinity.Personas.list()) == before
    assert Trinity.Smoke.vec_line() == "TRINITY_SMOKE_VEC=ok:#{inspect(store)}"

    # The probe child (placed before the endpoint) computes the three lines and starts nothing.
    assert :ignore = Trinity.Smoke.Probe.start_link()

    assert ["TRINITY_SMOKE_EXLA=" <> _, "TRINITY_SMOKE_VEC=ok:" <> _, "TRINITY_SMOKE_SEMANTIC=on"] =
             Trinity.Smoke.probed()

    assert Trinity.Smoke.probe(["--smoke"]) == [Trinity.Smoke.Probe]
    assert Trinity.Smoke.probe([]) == []
  end

  test "the EXLA product and the Elixir cosine agree on a float32 space",
       %{persona: persona, scope: scope} do
    rows =
      for i <- 1..50 do
        e = add!(persona, scope, "k#{i}", "text #{i}")
        {e, Space.encode_vector("f32", Fake.vector("text #{i}"))}
      end

    query = Fake.vector("text 7")
    elixir = Trinity.Memory.VectorStores.Brute.elixir_scores(rows, query)
    assert Enum.max(elixir) > 0.999

    # exla is runtime: false and started on demand; the store asks Bumblebee.exla/0 first.
    if Code.ensure_loaded?(EXLA.Backend) and Trinity.Memory.Embedders.Bumblebee.exla() == :ok do
      exla = Trinity.Memory.VectorStores.Brute.exla_scores(rows, query)
      for {a, b} <- Enum.zip(elixir, exla), do: assert_in_delta(a, b, 1.0e-5)
    else
      IO.puts("\nEXLA not loaded here: the Elixir path is the one in force")
    end
  end
end
