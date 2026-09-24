# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Telemetry.CostsTest do
  @moduledoc """
  Slice 090, AC2 (the totals half, retagged `[auto]`): the ledger's totals equal the sum of the
  rows, and a budget that is passed emits its warning.

  The SLICE made this criterion manual, to be checked by eye against a seeded dataset. A total is
  arithmetic, and arithmetic is the last thing that should be checked by looking at it, so the
  totals are asserted here and the manual queue keeps only the part that needs a person: the
  blocking behaviour and its message on screen.
  """
  use Trinity.DataCase, async: false

  alias Trinity.Repo
  alias Trinity.Sessions
  alias Trinity.Telemetry.Costs

  defp seed!(session_id, cost, opts \\ []) do
    Repo.insert_all("usage_events", [
      %{
        id: Trinity.UUID.generate(),
        model_id: Keyword.get(opts, :model, "fake:chat"),
        provider: "fake",
        kind: "stream",
        input_tokens: 10,
        output_tokens: 20,
        cached_tokens: 0,
        reasoning_tokens: 0,
        cost_usd: cost,
        session_id: session_id,
        # Encoded here rather than passed as a map: a schemaless insert has no schema to tell the
        # adapter this column is JSON, and SQLite refuses a bare map.
        provider_meta: JSON.encode!(%{}),
        inserted_at: Keyword.get(opts, :at, DateTime.utc_now() |> DateTime.truncate(:second))
      }
    ])
  end

  defp session!(opts \\ []) do
    {:ok, s} =
      Sessions.create_session(
        Enum.into(opts, %{persona_id: Sessions.default_persona().id, title: "t"})
      )

    s
  end

  setup do
    prior = Application.get_env(:trinity, :budgets)

    on_exit(fn ->
      if prior,
        do: Application.put_env(:trinity, :budgets, prior),
        else: Application.delete_env(:trinity, :budgets)
    end)

    :ok
  end

  describe "totals equal the sum of the rows" do
    test "across everything, and per session" do
      a = session!()
      b = session!()

      seed!(a.id, 1.50)
      seed!(a.id, 0.25)
      seed!(b.id, 2.00)

      assert_in_delta Costs.total(), 3.75, 0.0001
      assert_in_delta Costs.for_session(a.id), 1.75, 0.0001
      assert_in_delta Costs.for_session(b.id), 2.00, 0.0001
    end

    test "per persona, summed across that persona's sessions" do
      {:ok, persona} = Trinity.Personas.create(%{name: "auditor", soul: "careful"})
      mine = session!(persona_id: persona.id)
      theirs = session!()

      seed!(mine.id, 3.00)
      seed!(theirs.id, 9.99)

      assert_in_delta Costs.for_persona(persona.id), 3.00, 0.0001
    end

    test "by model, largest first, with the call count" do
      s = session!()
      seed!(s.id, 0.10, model: "cheap")
      seed!(s.id, 0.10, model: "cheap")
      seed!(s.id, 5.00, model: "dear")

      assert [{"dear", dear, 1}, {"cheap", cheap, 2}] = Costs.by_model()
      assert_in_delta dear, 5.00, 0.0001
      assert_in_delta cheap, 0.20, 0.0001
    end

    test "an empty ledger is zero, not nil" do
      # sum() over no rows is NULL, and a nil reaching a template renders as nothing rather than
      # as a number, which reads as "no data" when it means "no spend".
      assert Costs.total() == 0.0
      assert Costs.for_session(session!().id) == 0.0
      assert Costs.by_day() == []
    end
  end

  describe "budgets" do
    test "an unconfigured budget is not a budget of zero" do
      Application.delete_env(:trinity, :budgets)
      s = session!()
      seed!(s.id, 1_000.0)

      # The alternative silently blocks every call on a fresh install.
      assert Costs.budget(:day) == nil
      assert Costs.check(:day) == :ok
      assert Costs.check(:session, s.id) == :ok
    end

    test "passing a budget answers with what was spent and what the limit was" do
      Application.put_env(:trinity, :budgets, session: 1.0)
      s = session!()
      seed!(s.id, 2.50)

      assert {:over, spent, limit} = Costs.check(:session, s.id)
      assert_in_delta spent, 2.50, 0.0001
      assert limit == 1.0
    end

    test "passing a budget emits the warning event, whether or not anything blocks on it" do
      Application.put_env(:trinity, :budgets, day: 0.5)
      s = session!()
      seed!(s.id, 0.75)

      ref = make_ref()
      me = self()
      handler = "budget-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:trinity, :budget, :exceeded],
        fn _, m, md, _ ->
          send(me, {ref, m, md})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:over, _, _} = Costs.check(:day)
      assert_receive {^ref, %{spent_usd: _, limit_usd: 0.5}, %{scope: :day}}
    end

    test "blocking is off unless configured, and separate from warning" do
      Application.put_env(:trinity, :budgets, day: 0.01)
      refute Costs.blocking?()

      Application.put_env(:trinity, :budgets, day: 0.01, block_when_over: true)
      assert Costs.blocking?()
    end

    test "over/2 reports every configured scope that is past its limit" do
      {:ok, persona} = Trinity.Personas.create(%{name: "spender", soul: "eager"})
      s = session!(persona_id: persona.id)
      seed!(s.id, 4.00)

      Application.put_env(:trinity, :budgets, day: 1.0, session: 10.0, persona: 2.0)

      scopes = Costs.over(s.id, persona.id) |> Enum.map(&elem(&1, 0)) |> Enum.sort()
      assert scopes == [:day, :persona]
    end
  end

  test "the columns this module reads still exist" do
    # The queries are schemaless, so the column names are the contract with slice 011's schema and
    # nothing else checks them. A rename there should fail here rather than in a dashboard.
    {:ok, %{columns: columns}} =
      Repo.query("SELECT * FROM usage_events LIMIT 0")

    for column <- ~w(cost_usd session_id model_id inserted_at id) do
      assert column in columns, "usage_events lost the #{column} column this ledger reads"
    end
  end
end
