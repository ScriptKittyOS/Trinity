# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.RetrieverTest do
  @moduledoc """
  Slice 032, AC4 and AC5: an FTS-only hit and a vector-only hit both in the fused result;
  recency decay demotes an old identical memory; the prompt carries a "Relevant memories"
  block bounded by its cap, the cut receipted; recall over a session's scope chain only (M6);
  the tier off leaves the full-text half working.
  """
  use Trinity.SessionCase

  alias Trinity.{Factory, Receipts}
  alias Trinity.LLM.Providers.Fake
  alias Trinity.Memory.{AlwaysOn, Retriever, Semantic}
  alias Trinity.Sessions.{Prompt, Session}

  @now ~U[2026-09-21 09:00:00.000000Z]

  setup do
    persona = Factory.persona!()
    {:ok, persona: persona, pscope: AlwaysOn.persona_scope(persona.id)}
  end

  defp remember!(persona, scope, key, body, attrs \\ %{}) do
    {:ok, e} =
      Semantic.add(%{persona_id: persona.id, scope: scope, key: key, body: body}, by: "test")

    if attrs == %{} do
      e
    else
      e |> Ecto.Changeset.change(attrs) |> Trinity.Repo.update!()
    end
  end

  test "AC4: an FTS-only hit (a past message) and a vector-only hit (a semantic memory) both appear, fused; the current session's own rows do not",
       %{persona: persona, pscope: pscope} do
    past = Factory.session!(%{persona_id: persona.id, title: "Trip"})
    # The fake embedder's `#near:q` prefix is two words to the full-text index ("near", "q"),
    # and 031's search wants every word: the past message carries them.
    Factory.message!(past.id, %{
      role: "user",
      content: "near q: the gallium arsenide wafer arrives Tuesday"
    })

    current = Factory.session!(%{persona_id: persona.id})

    Factory.message!(current.id, %{
      role: "user",
      content: "gallium arsenide again, in this session"
    })

    memory = remember!(persona, pscope, "wafer", "#near:q prefers the wafer supplier in Lisbon")

    hits = Retriever.relevant(persona.id, current.id, "#near:q gallium arsenide", now: @now)

    assert Enum.map(hits, &{&1.kind, &1.found_by}) |> Enum.sort() == [
             {:memory, [:vector]},
             {:message, [:fts]}
           ]

    assert Enum.find(hits, &(&1.kind == :memory)).id == memory.id
    assert Enum.find(hits, &(&1.kind == :message)).ref.session_id == past.id
    for h <- hits, do: assert_in_delta(h.score, Retriever.rrf(1), 1.0e-9)

    # The memory hit is marked used.
    assert Trinity.Repo.reload!(memory).last_used_at != nil

    block = Retriever.render(hits)
    assert block =~ "## Relevant memories"
    assert block =~ "(remembered 20"
    assert block =~ ~s|(user in "Trip", 20|
    assert block =~ "[gallium] [arsenide]"
    assert Retriever.render([]) == ""
  end

  test "AC4: recency decay demotes an old identical memory below the recent one", %{
    persona: persona,
    pscope: pscope
  } do
    old_at = DateTime.add(@now, -90 * 86_400, :second)

    old =
      remember!(persona, "global", "same", "#near:same the very same fact", %{
        last_used_at: old_at,
        inserted_at: old_at
      })

    recent =
      remember!(persona, pscope, "same", "#near:same the very same fact", %{last_used_at: @now})

    [first, second] =
      Retriever.relevant(persona.id, nil, "#near:same the very same fact",
        now: @now,
        touch: false
      )

    assert {first.id, second.id} == {recent.id, old.id}
    assert first.score > second.score

    assert_in_delta Retriever.decay(@now, @now), 1.0, 1.0e-9
    assert_in_delta Retriever.decay(DateTime.add(@now, -30 * 86_400, :second), @now), 0.75, 1.0e-9
    assert_in_delta Retriever.decay(old_at, @now), 0.5625, 1.0e-9
    assert Retriever.decay(DateTime.add(@now, -3_650 * 86_400, :second), @now) >= 0.5
  end

  test "a memory below the cosine floor is not a hit: a question about nothing recalls nothing",
       %{persona: persona, pscope: pscope} do
    remember!(persona, pscope, "a", "#near:a has a dog named Rex")
    assert Retriever.relevant(persona.id, nil, "zzz unrelated", touch: false) == []
    old = Application.get_env(:trinity, :memory, [])
    on_exit(fn -> Application.put_env(:trinity, :memory, old) end)
    Application.put_env(:trinity, :memory, Keyword.put(old, :recall_min_cosine, -1.0))
    assert [%{kind: :memory}] = Retriever.relevant(persona.id, nil, "zzz unrelated", touch: false)
  end

  test "recall runs over the session's scope chain only (M6)", %{persona: persona, pscope: pscope} do
    other = Factory.persona!()
    remember!(other, AlwaysOn.persona_scope(other.id), "x", "#near:x theirs")
    session_a = Factory.session!(%{persona_id: persona.id})
    session_b = Factory.session!(%{persona_id: persona.id})
    remember!(persona, AlwaysOn.session_scope(session_a.id), "x", "#near:x session a's own")
    mine = remember!(persona, pscope, "x", "#near:x mine")

    ids = fn session_id ->
      Retriever.relevant(persona.id, session_id, "#near:x", touch: false) |> Enum.map(& &1.id)
    end

    assert ids.(session_b.id) == [mine.id]
    assert length(ids.(session_a.id)) == 2
  end

  test "with the tier off, recall is the full-text half alone", %{
    persona: persona,
    pscope: pscope
  } do
    old = Application.get_env(:trinity, :memory, [])
    on_exit(fn -> Application.put_env(:trinity, :memory, old) end)
    past = Factory.session!(%{persona_id: persona.id})
    Factory.message!(past.id, %{role: "user", content: "near z zirconium"})
    remember!(persona, pscope, "z", "#near:z zirconium too")

    Application.put_env(
      :trinity,
      :memory,
      Keyword.merge(old,
        embedder: :local,
        model_cache_dir: no_models()
      )
    )

    refute Semantic.on?()

    assert [%{kind: :message, found_by: [:fts]}] =
             Retriever.relevant(persona.id, nil, "#near:z zirconium", touch: false)
  end

  test "AC5 (prompt half): the block sits in the volatile tier after the always-in-mind block and is cut at its own cap, reported as :recall",
       %{persona: persona} do
    session = Factory.session!(%{persona_id: persona.id, title: "T"})
    block = "## Relevant memories\n- (remembered 2026-09-01) Lives in Lisbon."

    {request, []} =
      Prompt.build_with_report(session, persona, [], [],
        memory: "## Always in mind\n- a: b",
        recall: block,
        now: @now
      )

    assert request.system =~
             "## Always in mind\n- a: b\n\n## Relevant memories\n- (remembered 2026-09-01) Lives in Lisbon.\n\nThe time now is"

    long =
      "## Relevant memories\n" <>
        Enum.map_join(
          1..200,
          "\n",
          &"- (remembered 2026-09-01) memory number #{&1} with some words to make it long"
        )

    {request, truncations} =
      Prompt.build_with_report(session, persona, [], [], recall: long, now: @now)

    assert [%{tier: :recall, dropped_tokens: dropped}] = truncations
    assert dropped > 0
    assert request.system =~ "## Relevant memories\n- (remembered 2026-09-01) memory number 1 "
    assert request.system =~ "[cut at the tier's budget]\n\nThe time now is"
    [_, recall_part] = String.split(request.system, "## Relevant memories\n")
    [recall_part | _] = String.split(recall_part, "\n[cut")
    assert Trinity.Memory.Tokens.estimate(recall_part) <= Prompt.recall_tokens()
    assert Prompt.recall_tokens() == 600
  end

  test "AC5: a session's turn carries the block for its latest user message; a cut writes the receipt",
       %{persona: persona, pscope: pscope} do
    past = Factory.session!(%{persona_id: persona.id, title: "Earlier"})
    Factory.message!(past.id, %{role: "user", content: "near dog: what is my dog called? Rex"})
    remember!(persona, pscope, "dog", "#near:dog has a dog named Rex")

    row = Factory.session!(%{persona_id: persona.id})
    scope = Receipts.session_scope(row.id)
    on_exit(fn -> Receipts.stop_writer(scope) end)
    :ok = Trinity.Sessions.subscribe(row.id)
    Fake.scripts([script_deltas(1, "ok "), script_deltas(1, "ok ")])
    {:ok, pid} = start_drained(row.id)
    {:ok, _} = Session.send_user_message(pid, "#near:dog what is my dog called")
    _ = collect(row.id, &match?({:state, :idle}, &1))

    system = Fake.last_request().system
    assert system =~ "## Relevant memories\n"
    assert system =~ "has a dog named Rex"
    assert system =~ ~s|(user in "Earlier"|
    assert system =~ "[dog]"

    assert Receipts.list(scope, kind: "query")
           |> Enum.filter(&(&1.subject["prompt_tier"] == "recall")) == []

    old = Application.get_env(:trinity, :memory, [])
    Application.put_env(:trinity, :memory, Keyword.put(old, :recall_tokens, 45))
    on_exit(fn -> Application.put_env(:trinity, :memory, old) end)
    {:ok, _} = Session.send_user_message(pid, "#near:dog what is my dog called")
    _ = collect(row.id, &match?({:state, :idle}, &1))

    [receipt] =
      Receipts.list(scope, kind: "query") |> Enum.filter(&(&1.subject["prompt_tier"] == "recall"))

    assert JSON.decode!(receipt.signed_payload)["decision"]["dropped_tokens"] > 0
    assert receipt.subject_ref == "prompt:#{row.id}:recall"

    # One hit line survives the cap (the two tie on rank and recency; which is first is the id's), the other is cut.
    assert Fake.last_request().system =~
             ~r/## Relevant memories\n- \(.*\n\[cut at the tier's budget\]\n\nThe time now/
  end

  defp no_models do
    cache = Path.join(System.tmp_dir!(), "no-models-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(cache) end)
    cache
  end
end
