# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.PinningTest do
  @moduledoc """
  Slice 133, AC3: the active space changes only through the operator's command.

  A store holding space A's vectors, with configuration then naming embedder B. Before this
  slice the semantic leg returned nothing and said nothing: the status read `:on`, because the
  status asked only whether B could embed, while every search filtered on B's model and found
  none of A's rows. After it, semantic memory is OFF with a reason that names the mismatch, the
  active pointer stays on A, and no re-embed job is enqueued.
  """
  use Trinity.DataCase, async: false

  alias Trinity.Factory
  alias Trinity.Memory.{AlwaysOn, Embedders, Retriever, Semantic, Space, Spaces}

  setup do
    previous = Application.get_env(:trinity, :memory, [])
    on_exit(fn -> Application.put_env(:trinity, :memory, previous) end)
    persona = Factory.persona!()
    {:ok, persona: persona, scope: AlwaysOn.persona_scope(persona.id), previous: previous}
  end

  defp configure_b(previous) do
    # Embedder B: the suite's fake with another seed and width, so another space.
    Application.put_env(
      :trinity,
      :memory,
      Keyword.merge(previous, embedder: :fake, fake_dim: 256, fake_seed: "b")
    )
  end

  defp jobs(worker) do
    Trinity.Repo.aggregate(
      from(j in Oban.Job, where: j.worker == ^worker),
      :count
    )
  end

  test "AC3: pinned to A, configured B: OFF with a named reason, nothing enqueued", %{
    persona: persona,
    scope: scope,
    previous: previous
  } do
    {:ok, _} =
      Semantic.add(
        %{persona_id: persona.id, scope: scope, key: "rex", body: "the dog is called Rex"},
        by: "test"
      )

    assert Semantic.status() == :on
    # The first write pinned the empty store to A, the fake's space.
    a = Space.id(Embedders.Fake.space())
    assert Spaces.active().id == a

    configure_b(previous)
    b = Space.id(Embedders.Fake.space())
    refute b == a

    # The reason names the mismatch, with both spaces: not :on, and not an unrelated reason.
    assert {:off, {:space_mismatch, %{active: active, configured: [configured]}}} =
             Semantic.status()

    assert {active, configured} == {Space.short(a), Space.short(b)}

    # The pointer did not move, B's space was not even registered, and no vector was written.
    assert Spaces.active().id == a
    assert Spaces.get(b) == nil
    assert Spaces.count(a) == 1

    # Recall still answers (full text), and the vector leg ranks nothing from either space.
    hits = Retriever.relevant(persona.id, nil, "the dog is called Rex")
    assert Enum.all?(hits, &(&1.kind != :memory))

    assert jobs("Trinity.Memory.ReEmbedWorker") == 0

    # A write while off is refused, and still moves nothing.
    assert {:error, {:embedder_off, {:space_mismatch, _}}} =
             Semantic.add(%{persona_id: persona.id, scope: scope, key: "k2", body: "another"},
               by: "test"
             )

    assert Spaces.active().id == a
    assert Spaces.count(a) == 1
  end

  test "an empty store is pinned on its first write, and only then", %{
    persona: persona,
    scope: scope,
    previous: previous
  } do
    assert Spaces.active() == nil
    # Before any write the configured embedder serves an empty store: on, nothing pinned yet.
    assert Semantic.status() == :on
    configure_b(previous)
    assert Semantic.status() == :on
    assert Spaces.active() == nil

    {:ok, _} =
      Semantic.add(%{persona_id: persona.id, scope: scope, key: "k", body: "first"}, by: "test")

    assert Spaces.active().id == Space.id(Embedders.Fake.space())
  end
end
