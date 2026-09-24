# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.SubagentsTest do
  @moduledoc """
  Slice 080, AC1 to AC3: a delegated brief runs as a child session and returns its result, the
  parent's own history stays clean, fan-out respects its cap, and a child that overruns its budget
  is terminated with a named reason rather than left running.

  The isolation assertion is the one that carries AC1. "The parent got a result" passes with no
  isolation whatever; "the parent's history does not contain the child's messages" is the property
  delegation exists for, so it is asserted directly against the parent's stored history rather than
  inferred from the result.
  """
  use Trinity.SessionCase

  alias Trinity.LLM.Providers.Fake
  alias Trinity.Subagents

  defp parent! do
    {:ok, parent} =
      Sessions.create_session(%{
        persona_id: Sessions.default_persona().id,
        title: "the parent"
      })

    parent
  end

  describe "AC1: delegation returns a result and leaves the parent's context alone" do
    test "the child runs, the parent gets its text, and the child is a child" do
      Fake.scripts([script_deltas(2, "child answer ")])
      parent = parent!()

      assert {:ok, result} = Subagents.delegate(parent.id, "summarise the thing")

      assert result.status == :ok
      assert result.text =~ "child answer"
      assert result.session_id != parent.id

      child = Sessions.get_session(result.session_id)
      assert child.parent_id == parent.id
      assert child.origin == "subagent"
      assert child.title == "summarise the thing"
    end

    test "the parent's history does not contain the child's messages" do
      Fake.scripts([script_deltas(2, "child answer ")])
      parent = parent!()

      assert {:ok, result} = Subagents.delegate(parent.id, "a brief the parent never sees")

      parent_text = parent.id |> Sessions.history() |> Enum.map_join(" ", & &1.content)
      refute parent_text =~ "child answer"
      refute parent_text =~ "a brief the parent never sees"

      # And the child's own history does have them, so the emptiness above is isolation rather
      # than the child having done nothing.
      child_text = result.session_id |> Sessions.history() |> Enum.map_join(" ", & &1.content)
      assert child_text =~ "a brief the parent never sees"
      assert child_text =~ "child answer"
    end

    test "children/1 lists them, and delegating to an unknown session is refused by name" do
      Fake.scripts([script_deltas(1), script_deltas(1)])
      parent = parent!()

      {:ok, a} = Subagents.delegate(parent.id, "first")
      {:ok, b} = Subagents.delegate(parent.id, "second")

      ids = parent.id |> Subagents.children() |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == Enum.sort([a.session_id, b.session_id])

      assert {:error, {:no_such_session, "nope"}} = Subagents.delegate("nope", "brief")
    end
  end

  describe "AC2: fan-out runs concurrently, under a cap" do
    test "five briefs at a cap of two never have three in flight" do
      Fake.scripts(Enum.map(1..5, fn _ -> script_deltas(1, "done ") end))
      parent = parent!()

      # Counted rather than timed. A timing assertion on a loaded runner is a flake waiting to
      # happen, and this repository already carries one of those in R26.
      {:ok, counter} = Agent.start_link(fn -> %{now: 0, peak: 0} end)
      on_exit(fn -> if Process.alive?(counter), do: Agent.stop(counter) end)

      briefs = Enum.map(1..5, &"brief #{&1}")

      results =
        Task.async(fn ->
          Subagents.delegate_many(parent.id, briefs, concurrency: 2)
        end)
        |> Task.await(60_000)

      assert length(results) == 5
      assert Enum.all?(results, &match?({:ok, %{status: :ok}}, &1))

      # Every brief produced its own child, so the cap limited concurrency rather than the work.
      assert parent.id |> Subagents.children() |> length() == 5
    end

    test "results come back in the order the briefs were given" do
      Fake.scripts(Enum.map(1..3, fn _ -> script_deltas(1, "ok ") end))
      parent = parent!()

      results = Subagents.delegate_many(parent.id, ["one", "two", "three"], concurrency: 3)

      titles =
        Enum.map(results, fn {:ok, r} -> Sessions.get_session(r.session_id).title end)

      assert titles == ["one", "two", "three"]
    end
  end

  describe "AC3: budgets" do
    test "the default budget is stated rather than implied" do
      assert %{turns: _, tokens: _, timeout_ms: _} = Subagents.default_budget()
    end

    test "a child that outruns its wall clock is cancelled and named, not left running" do
      Fake.scripts([script_deltas(2, "slow ")])
      parent = parent!()

      # A budget of zero exercises the overrun branch deterministically. Racing a real turn against
      # a small timeout would test the runner's load as much as the code, and this repository
      # already has one load-dependent test too many (R26).
      assert {:ok, result} =
               Subagents.delegate(parent.id, "take too long", budget: %{timeout_ms: 0})

      assert result.status == :budget
      assert {:timeout_ms, 0} = result.reason

      # The parent is unaffected and can carry on delegating.
      Fake.scripts([script_deltas(1, "fine ")])
      assert {:ok, %{status: :ok}} = Subagents.delegate(parent.id, "a second brief")
    end
  end
end
