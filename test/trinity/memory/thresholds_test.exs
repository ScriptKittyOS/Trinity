# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.ThresholdsTest do
  @moduledoc """
  Slice 133, AC11: thresholds are the space's own (`thresholds/0`), not a constant.

  The static model is a bag of words: a decision and its negation share every word but one, and
  measure a cosine of 0.9703 (NOTES). MiniLM's dedupe value, 0.92, would call them the same
  memory and drop the second, so the person's later decision would never be remembered. The
  static space's own dedupe value keeps both, and still merges a true restatement.
  """
  use Trinity.SessionCase

  alias Trinity.Factory
  alias Trinity.LLM.Providers.Fake
  alias Trinity.Memory.{AlwaysOn, Observer, Semantic}
  alias Trinity.StaticWeights

  @moduletag :static_weights

  setup do
    previous = StaticWeights.use_static!()
    memory = Application.get_env(:trinity, :memory, [])
    Application.put_env(:trinity, :memory, Keyword.put(memory, :observer, true))
    on_exit(fn -> StaticWeights.restore!(previous) end)
    persona = Factory.persona!()
    row = Factory.session!(%{persona_id: persona.id})
    {:ok, persona: persona, pscope: AlwaysOn.persona_scope(persona.id), row: row}
  end

  defp run_observer(persona, row, bodies) do
    u = Factory.message!(row.id, %{role: "user", content: "about the project database"})
    a = Factory.message!(row.id, %{role: "assistant", content: "Noted."})

    Fake.object(%{
      "memories" => Enum.map(bodies, &%{"kind" => "decision", "body" => &1, "confidence" => 0.9})
    })

    Observer.run(
      %{session_id: row.id, persona_id: persona.id, model: nil},
      Enum.map([u, a], &%{id: &1.id, role: &1.role, content: &1.content})
    )
  end

  test "AC11: a decision and its negation stay two memories in the static space; a restatement merges",
       %{persona: persona, pscope: pscope, row: row} do
    {:ok, _} =
      Semantic.add(
        %{
          persona_id: persona.id,
          scope: pscope,
          key: "postgres",
          body: "The person decided to use Postgres for the project."
        },
        by: "test"
      )

    assert {:ok, kept} =
             run_observer(persona, row, [
               "The person decided not to use Postgres for the project.",
               "The person has decided to use Postgres for the project."
             ])

    bodies = Enum.map(kept, & &1.body)
    assert "The person decided not to use Postgres for the project." in bodies

    refute "The person has decided to use Postgres for the project." in bodies,
           "a restatement of an existing memory was kept as a new one"
  end
end
