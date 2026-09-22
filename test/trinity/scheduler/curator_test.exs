# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.CuratorTest do
  @moduledoc """
  Slice 050: the curator marks an entry untouched for 30 days stale (a query receipt) and one
  untouched for 90 days archived (an effect receipt); a fresh one is untouched; nothing is
  deleted; an archived entry leaves the always-on chain and the semantic entries; the observer
  is a job on the memory queue with the message ids, never the text.
  """
  use Trinity.DataCase, async: false
  use Oban.Testing, repo: Trinity.Repo
  @moduletag :capture_log

  import Ecto.Query, only: [from: 2]

  alias Trinity.Memory.{AlwaysOn, Curator, Entry, Observer, ObserverWorker, Semantic}
  alias Trinity.Receipts
  alias Trinity.Repo

  setup do
    persona = Trinity.Factory.persona!()
    scope = AlwaysOn.persona_scope(persona.id)
    on_exit(fn -> Receipts.stop_writer(Curator.scope(persona.id)) end)
    {:ok, persona: persona, scope: scope}
  end

  defp aged!(persona, scope, key, days) do
    {:ok, e} =
      AlwaysOn.add(
        %{persona_id: persona.id, tier: "always_on", scope: scope, key: key, body: key},
        by: "test"
      )

    at = DateTime.utc_now() |> DateTime.add(-days, :day)

    Repo.update_all(from(x in Entry, where: x.id == ^e.id),
      set: [last_used_at: at, updated_at: at]
    )

    Repo.get!(Entry, e.id)
  end

  test "stale at 30 days with a query receipt, archived at 90 with an effect receipt, fresh untouched, nothing deleted; the archived entry leaves recall",
       %{persona: persona, scope: scope} do
    fresh = aged!(persona, scope, "fresh", 1)
    stale = aged!(persona, scope, "stale", 31)
    old = aged!(persona, scope, "old", 91)
    now = DateTime.utc_now()

    assert {:ok, %{stale: 1, archived: 1}} =
             perform_job(Curator, %{"now" => DateTime.to_iso8601(now)})

    assert %Entry{stale_at: nil, archived_at: nil} = Repo.get!(Entry, fresh.id)
    assert %Entry{stale_at: %DateTime{}, archived_at: nil} = Repo.get!(Entry, stale.id)
    assert %Entry{archived_at: %DateTime{}} = Repo.get!(Entry, old.id)
    assert Repo.aggregate(from(e in Entry, where: e.persona_id == ^persona.id), :count) == 3

    receipts = Receipts.list(Curator.scope(persona.id))

    assert [
             %{
               kind: "effect",
               subject: %{"entry_id" => oid, "phase" => "done", "curator" => "archive"}
             }
           ] = Enum.filter(receipts, &(&1.kind == "effect"))

    assert oid == old.id

    assert [%{kind: "query", subject: %{"curator" => "stale", "entries" => [sid]}}] =
             Enum.filter(receipts, &(&1.kind == "query"))

    assert sid == stale.id

    # Recall: the archived entry is gone from the chain a session sees; the stale one stays.
    keys = AlwaysOn.entries(persona.id, nil) |> Enum.map(& &1.key) |> Enum.sort()
    assert keys == ["fresh", "stale"]

    # A second run changes nothing more.
    assert {:ok, %{stale: 0, archived: 0}} =
             perform_job(Curator, %{"now" => DateTime.to_iso8601(now)})
  end

  test "an archived semantic entry leaves the semantic entries and the brute store's search", %{
    persona: persona,
    scope: scope
  } do
    vector = Enum.map(1..8, fn _ -> 0.1 end)

    {:ok, e} =
      %Entry{}
      |> Entry.semantic_changeset(%{
        persona_id: persona.id,
        tier: "semantic",
        scope: scope,
        key: "cat",
        body: "the cat is grey",
        confidence: 0.9,
        embedding: Trinity.Memory.Embedder.to_binary(vector),
        embedding_model: "fake:embed",
        embedding_dim: 8
      })
      |> Repo.insert()

    assert [_] = Semantic.entries(persona.id, [scope])

    assert [_] =
             Trinity.Memory.VectorStores.Brute.search(vector, 5, %{
               persona_id: persona.id,
               scopes: [scope],
               model: "fake:embed"
             })

    Repo.update_all(from(x in Entry, where: x.id == ^e.id),
      set: [archived_at: DateTime.utc_now()]
    )

    assert [] = Semantic.entries(persona.id, [scope])

    assert [] =
             Trinity.Memory.VectorStores.Brute.search(vector, 5, %{
               persona_id: persona.id,
               scopes: [scope],
               model: "fake:embed"
             })
  end

  test "the observer enqueues a memory job carrying the message ids and not their text; the job runs run/2",
       %{persona: persona} do
    session = Trinity.Factory.session!(%{persona_id: persona.id})
    m1 = Trinity.Factory.message!(session.id, %{role: "user", content: "I live in Lisbon"})
    m2 = Trinity.Factory.message!(session.id, %{role: "assistant", content: "Noted."})
    turn = %{session_id: session.id, persona_id: persona.id, model: "fake:chat"}

    Application.put_env(
      :trinity,
      :memory,
      Keyword.put(Application.get_env(:trinity, :memory, []), :observer, true)
    )

    on_exit(fn ->
      Application.put_env(
        :trinity,
        :memory,
        Keyword.put(Application.get_env(:trinity, :memory, []), :observer, false)
      )
    end)

    case Observer.observe(turn, [
           %{id: m1.id, role: "user", content: m1.content},
           %{id: m2.id, role: "assistant", content: m2.content}
         ]) do
      {:ok, %Oban.Job{args: args}} ->
        assert args == %{
                 "turn" => %{
                   "session_id" => session.id,
                   "persona_id" => persona.id,
                   "model" => "fake:chat"
                 },
                 "message_ids" => [m1.id, m2.id]
               }

        refute inspect(args) =~ "Lisbon"
        assert_enqueued(worker: ObserverWorker, queue: :memory)

      :off ->
        # The semantic tier is off in this environment (no store or model): the job is not
        # enqueued and the assertion is that nothing else happened.
        refute_enqueued(worker: ObserverWorker)
    end
  end
end
