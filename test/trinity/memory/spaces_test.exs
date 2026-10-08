# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.SpacesTest do
  @moduledoc """
  Slice 133: the spaces' bookkeeping around AC3 and AC4: one active space held by the database,
  ids resolved from the prefixes the commands print, a re-tier refused when it has nothing to do
  or its embedder cannot serve, the commands' output, and the re-embed job as the one way a
  running node re-tiers (enqueued by nobody but an operator).
  """
  use Trinity.DataCase, async: false

  import ExUnit.CaptureIO

  alias Trinity.{Factory, FakeEmbedderB, Repo}

  alias Trinity.Memory.{
    AlwaysOn,
    Embedders.Fake,
    ReEmbedWorker,
    Semantic,
    Space,
    SpaceRow,
    Spaces
  }

  setup do
    previous = Application.get_env(:trinity, :memory, [])
    on_exit(fn -> Application.put_env(:trinity, :memory, previous) end)
    persona = Factory.persona!()
    scope = AlwaysOn.persona_scope(persona.id)

    for i <- 1..3 do
      {:ok, _} =
        Semantic.add(%{persona_id: persona.id, scope: scope, key: "k#{i}", body: "fact #{i}"},
          by: "test"
        )
    end

    {:ok, previous: previous, a: Spaces.active()}
  end

  test "the database holds at most one active space", %{a: a} do
    {:ok, b} = Spaces.register(FakeEmbedderB.space())

    # Refused by the database itself (SQLite and Postgres name it differently).
    error =
      catch_error(Repo.update_all(from(s in SpaceRow, where: s.id == ^b.id), set: [active: true]))

    assert Exception.message(error) =~
             ~r/UNIQUE constraint failed: embedding_spaces.active|embedding_spaces_one_active/

    assert Spaces.active().id == a.id
  end

  test "register is idempotent; pin_if_empty refuses a store pinned elsewhere or holding vectors",
       %{a: a} do
    assert {:ok, %{id: id}} = Spaces.register(Fake.space())
    assert id == a.id
    assert {:ok, ^a} = Spaces.pin_if_empty(Fake.space())
    other = Space.id(FakeEmbedderB.space())
    assert {:error, {:pinned_elsewhere, ^id}} = Spaces.pin_if_empty(FakeEmbedderB.space())

    Repo.update_all(SpaceRow, set: [active: false])
    assert {:error, :store_not_empty} = Spaces.pin_if_empty(FakeEmbedderB.space())
    assert Spaces.get(other) == nil
    # A store holding vectors with no active space serves nothing, and says so.
    assert Semantic.status() == {:off, :no_active_space}
  end

  test "resolve takes a full id or a unique prefix of twelve or more; drop refuses unknown ids",
       %{
         a: a
       } do
    assert {:ok, %{id: id}} = Spaces.resolve(Space.short(a.id))
    assert id == a.id
    assert {:error, :not_found} = Spaces.resolve("0123456789ab")
    assert {:error, :not_found} = Spaces.resolve("short")
    assert {:error, :not_found} = Spaces.drop(String.duplicate("0", 64), confirm: true)
    refute Spaces.valid_id?("x'; DROP TABLE memories; --")
  end

  test "a re-tier to the active space, or through an embedder that cannot serve, is refused",
       %{previous: previous} do
    assert {:error, :already_active} = Spaces.retier(Fake)
    Application.put_env(:trinity, :memory, Keyword.put(previous, :hosted_model, "no:such"))

    assert {:error, {:embedder_unavailable, {:off, _}}} =
             Spaces.retier(Trinity.Memory.Embedders.Hosted)
  end

  test "the commands: list, retier, drop with and without --confirm", %{previous: previous, a: a} do
    out = capture_io(fn -> Mix.Tasks.Trinity.Space.List.run([]) end)
    assert out =~ "* #{Space.short(a.id)}  complete  384d f32  3 vectors  fake:sha256-384"

    Application.put_env(
      :trinity,
      :memory,
      Keyword.put(previous, :embedder, [FakeEmbedderB, :fake])
    )

    out = capture_io(fn -> Mix.Tasks.Trinity.Space.Retier.run([inspect(FakeEmbedderB)]) end)
    b = Space.id(FakeEmbedderB.space())
    assert out =~ "space #{Space.short(b)} is active (3 embedded)"
    assert out =~ "mix trinity.space.drop #{Space.short(a.id)} --confirm"

    assert_raise Mix.Error, ~r/active space/, fn ->
      Mix.Tasks.Trinity.Space.Drop.run([Space.short(b), "--confirm"])
    end

    assert_raise Mix.Error, ~r/unknown_embedder/, fn ->
      Mix.Tasks.Trinity.Space.Retier.run(["no-such-embedder"])
    end

    out = capture_io(fn -> Mix.Tasks.Trinity.Space.Drop.run([Space.short(a.id), "--confirm"]) end)
    assert out =~ "dropped space #{Space.short(a.id)}: 3 vectors deleted"
  end

  test "the re-embed job re-tiers a running node, and an already-active target is done", %{
    previous: previous
  } do
    Application.put_env(
      :trinity,
      :memory,
      Keyword.put(previous, :embedder, [FakeEmbedderB, :fake])
    )

    assert :ok = perform_job(ReEmbedWorker, %{"embedder" => inspect(FakeEmbedderB)})
    assert Spaces.active().id == Space.id(FakeEmbedderB.space())
    assert :ok = perform_job(ReEmbedWorker, %{"embedder" => inspect(FakeEmbedderB)})

    assert {:error, {:unknown_embedder, "nope"}} =
             perform_job(ReEmbedWorker, %{"embedder" => "nope"})
  end

  defp perform_job(worker, args), do: worker.perform(%Oban.Job{args: args})
end
