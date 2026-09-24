# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Permissions.Policy.StateBudgetTest do
  @moduledoc """
  Slice 028 AC4, end to end: a real budget, exceeded by real ledger rows, tightens a real call, and
  the basis the gate returns names the state that did it.

  The unit tests prove the mechanism cannot loosen. This one proves the mechanism is *connected*:
  that a state kind with no producer is a state kind that does nothing, and `:over_budget` has one.
  """
  use Trinity.DataCase, async: false

  alias Trinity.Repo
  alias Trinity.Tools.{Context, Runner}

  setup do
    previous = Application.fetch_env(:trinity, :budgets)
    Application.put_env(:trinity, :budgets, day: 0.01)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:trinity, :budgets, value)
        :error -> Application.delete_env(:trinity, :budgets)
      end
    end)

    :ok
  end

  defp spend!(amount) do
    Repo.insert!(%Trinity.LLM.Usage{
      model_id: "fake:chat",
      provider: "fake",
      kind: "stream",
      input_tokens: 10,
      output_tokens: 20,
      cached_tokens: 0,
      reasoning_tokens: 0,
      cost_usd: amount,
      session_id: nil,
      provider_meta: %{},
      inserted_at: DateTime.utc_now()
    })
  end

  # `decide/3` answers a three-tuple for allow and deny and a four-tuple for ask, the extra element
  # being what to ask with. The basis is last either way.
  defp basis_of(result), do: result |> Tuple.to_list() |> List.last()

  test "under the budget the call decides as it always did, with no state in the basis" do
    {:ok, entry} = Trinity.Tools.lookup("fs_read")
    basis = basis_of(Runner.decide(entry, %{"path" => "/tmp/x"}, %Context{}))

    refute basis =~ "state:",
           "no budget is exceeded, so nothing should have tightened this call: #{basis}"
  end

  test "over the day budget the same call is denied, and the basis names the budget" do
    spend!(0.05)

    {:ok, entry} = Trinity.Tools.lookup("fs_read")

    assert {:deny, _fp, basis} = Runner.decide(entry, %{"path" => "/tmp/x"}, %Context{})

    assert basis =~ "state:over_budget",
           "the call was denied but the basis does not say the budget did it: #{basis}. A refusal " <>
             "whose reason is not recorded is a refusal the owner cannot act on"
  end

  test "the tier of the tool did not move, only what the call required" do
    spend!(0.05)
    assert Trinity.Permissions.tier("fs_read") == :read
  end
end
