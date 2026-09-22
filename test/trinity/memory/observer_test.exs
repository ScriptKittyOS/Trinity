# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.ObserverTest do
  @moduledoc """
  Slice 032, AC3: the observer extracts memories from a scripted turn (the fake provider's
  facts) and dedupes a near-duplicate, against the store and within its own batch; the
  session hands the completed turn over; the observer is off when the tier is off.
  """
  use Trinity.SessionCase

  alias Trinity.{Factory, Receipts}
  alias Trinity.LLM.Providers.Fake
  alias Trinity.Memory.{AlwaysOn, Observer, Semantic}
  alias Trinity.Sessions.Session

  setup do
    old = Application.get_env(:trinity, :memory, [])
    Application.put_env(:trinity, :memory, Keyword.put(old, :observer, true))
    on_exit(fn -> Application.put_env(:trinity, :memory, old) end)
    persona = Factory.persona!()
    row = Factory.session!(%{persona_id: persona.id})
    {:ok, persona: persona, pscope: AlwaysOn.persona_scope(persona.id), row: row}
  end

  # The usage ledger (011) and the provenance column both reference real rows.
  defp turn(persona, row), do: %{session_id: row.id, persona_id: persona.id, model: nil}

  defp messages(row) do
    u =
      Factory.message!(row.id, %{
        role: "user",
        content: "I drink coffee every morning and I write Elixir."
      })

    a = Factory.message!(row.id, %{role: "assistant", content: "Noted."})
    Enum.map([u, a], &%{id: &1.id, role: &1.role, content: &1.content})
  end

  test "AC3: facts from a scripted turn become semantic rows with provenance, confidence and a log row; a near-duplicate of an existing memory is dropped",
       %{persona: persona, pscope: pscope, row: row} do
    {:ok, planted} =
      Semantic.add(
        %{
          persona_id: persona.id,
          scope: pscope,
          key: "coffee",
          body: "#near:coffee drinks coffee"
        },
        by: "test"
      )

    Fake.object(%{
      "memories" => [
        %{
          "kind" => "preference",
          "body" => "#near:coffee likes coffee in the morning",
          "confidence" => 0.9
        },
        %{"kind" => "fact", "body" => "Writes Elixir.", "confidence" => 0.8},
        %{"kind" => "fact", "body" => "  ", "confidence" => 0.1}
      ]
    })

    msgs = messages(row)
    assert {:ok, [entry]} = Observer.run(turn(persona, row), msgs)
    assert entry.tier == "semantic"
    assert entry.scope == pscope
    assert entry.body == "Writes Elixir."
    assert entry.confidence == 0.8
    assert entry.source_message_id == Enum.at(msgs, 1).id

    assert entry.key ==
             "writes-elixir-" <>
               String.slice(
                 :crypto.hash(:sha256, "Writes Elixir.") |> Base.encode16(case: :lower),
                 0,
                 6
               )

    assert entry.embedding_model == "fake:sha256-384"

    assert Enum.map(Semantic.entries(persona.id, [pscope]), & &1.id) |> Enum.sort() ==
             Enum.sort([planted.id, entry.id])

    [log | _] = AlwaysOn.changes(persona.id)
    assert {log.action, log.tier, log.key, log.by} == {"add", "semantic", entry.key, "observer"}

    # The same wording again meets :exists; a different wording of the same fact meets the dedupe.
    assert {:ok, []} = Observer.run(turn(persona, row), msgs)

    Fake.object(%{
      "memories" => [
        %{"kind" => "fact", "body" => "#near:coffee coffee, mornings", "confidence" => 1}
      ]
    })

    assert {:ok, []} = Observer.run(turn(persona, row), msgs)
    assert Semantic.count(persona.id) == 2
  end

  test "two near-duplicates in one answer keep only the first", %{persona: persona, row: row} do
    Fake.object(%{
      "memories" => [
        %{"kind" => "fact", "body" => "#near:pets has a dog", "confidence" => 0.7},
        %{"kind" => "fact", "body" => "#near:pets owns a dog named Rex", "confidence" => 0.7}
      ]
    })

    assert {:ok, [%{body: "#near:pets has a dog"}]} =
             Observer.run(turn(persona, row), messages(row))
  end

  test "the dedupe threshold is configuration", %{persona: persona, pscope: pscope, row: row} do
    {:ok, _} =
      Semantic.add(
        %{persona_id: persona.id, scope: pscope, key: "a", body: "#near:tea drinks tea"},
        by: "test"
      )

    Application.put_env(
      :trinity,
      :memory,
      Keyword.put(Application.get_env(:trinity, :memory), :dedupe_cosine, 1.01)
    )

    Fake.object(%{
      "memories" => [%{"kind" => "fact", "body" => "#near:tea likes tea", "confidence" => 0.7}]
    })

    assert {:ok, [_]} = Observer.run(turn(persona, row), messages(row))
  end

  test "an empty answer inserts nothing; a model error is returned, not raised", %{
    persona: persona,
    row: row
  } do
    Fake.object(%{"memories" => []})
    assert {:ok, []} = Observer.run(turn(persona, row), messages(row))
    Fake.object(%{"nothing" => "here"})
    assert {:error, {:no_memories, _}} = Observer.run(turn(persona, row), messages(row))
  end

  test "off without a persona, off by configuration, off when the tier is off: nothing is sent to any model",
       %{persona: persona, row: row} do
    Fake.object(%{
      "memories" => [%{"kind" => "fact", "body" => "never stored", "confidence" => 1}]
    })

    assert Observer.run(%{session_id: row.id, persona_id: nil, model: nil}, messages(row)) == :off

    assert Observer.observe(%{session_id: row.id, persona_id: nil, model: nil}, messages(row)) ==
             :off

    old = Application.get_env(:trinity, :memory)
    Application.put_env(:trinity, :memory, Keyword.put(old, :observer, false))
    assert Observer.run(turn(persona, row), messages(row)) == :off

    Application.put_env(
      :trinity,
      :memory,
      Keyword.merge(old,
        embedder: :local,
        model_cache_dir: no_models()
      )
    )

    refute Semantic.on?()
    assert Observer.run(turn(persona, row), messages(row)) == :off
    assert Semantic.count(persona.id) == 0
  end

  test "a completed session turn hands its messages to the observer, which runs off the session's path",
       %{persona: persona, pscope: pscope, row: row} do
    on_exit(fn -> Receipts.stop_writer(Receipts.session_scope(row.id)) end)

    Fake.object(%{
      "memories" => [%{"kind" => "fact", "body" => "Lives in Lisbon.", "confidence" => 0.9}]
    })

    Fake.script(script_deltas(1, "ok "))
    :ok = Trinity.Sessions.subscribe(row.id)

    {:ok, pid} = start_drained(row.id)
    {:ok, _} = Session.send_user_message(pid, "I live in Lisbon")
    _ = collect(row.id, &match?({:state, :idle}, &1))

    # Slice 050: the observer is a job on the memory queue, enqueued off the session's path;
    # the suite runs Oban manually, so the queue is drained here and the job runs in this
    # process (the 032 version waited for a task's row).
    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :memory, with_safety: false)
    entries = Semantic.entries(persona.id, [pscope])

    assert [%{body: "Lives in Lisbon.", by_session: nil} = e] =
             Enum.map(entries, &Map.put(&1, :by_session, nil))

    assert e.source_message_id != nil
    [log | _] = AlwaysOn.changes(persona.id)
    assert log.session_id == row.id and log.by == "observer"
  end

  defp no_models do
    cache = Path.join(System.tmp_dir!(), "no-models-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(cache) end)
    cache
  end
end
