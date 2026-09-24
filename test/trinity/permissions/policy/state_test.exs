# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Permissions.Policy.StateTest do
  @moduledoc """
  Slice 028: context tightens and never loosens.

  The first test is the criterion. Everything below it is an illustration, and an illustration is
  what a modifier that happened to tighten for the cases someone thought of would also pass.
  """
  use ExUnit.Case, async: true

  alias Trinity.Permissions.Policy.State

  @decisions [:allow, :ask, :deny]
  @strictness %{allow: 0, ask: 1, deny: 2}

  describe "the property" do
    test "no decision and no set of states produces a result weaker than the decision alone" do
      # Every decision against every subset of the closed state set, in every order. The set is
      # small enough that this is exhaustive rather than sampled, which is better than a property
      # test: there is no seed and nothing to be unlucky with.
      for decision <- @decisions,
          states <- permutations_of_subsets(State.kinds()) do
        {result, applied} = State.tighten(decision, states)

        assert @strictness[result] >= @strictness[decision],
               "#{decision} with #{inspect(states)} produced #{result}, which is weaker"

        assert Enum.all?(applied, &(&1 in states)),
               "#{inspect(applied)} names a state that was not active"

        if result == decision do
          assert applied == [],
                 "nothing changed the decision but #{inspect(applied)} was recorded"
        end
      end
    end

    test "adding a state to the list can only tighten, never relax, whatever is already there" do
      for decision <- @decisions,
          states <- permutations_of_subsets(State.kinds()),
          extra <- State.kinds() do
        {before, _} = State.tighten(decision, states)
        {after_, _} = State.tighten(decision, states ++ [extra])
        assert @strictness[after_] >= @strictness[before]
      end
    end

    test "no state requires only :allow, which is why none of them can be a licence" do
      for kind <- State.kinds(), do: assert(State.requires(kind) in [:ask, :deny])
    end
  end

  describe "the closed set" do
    test "a state outside the set is refused by name rather than ignored" do
      assert_raise ArgumentError, ~r/:please_allow is not a state/, fn ->
        State.requires(:please_allow)
      end

      assert_raise ArgumentError, ~r/not a state/, fn ->
        State.tighten(:deny, [:please_allow])
      end
    end

    test "the refusal says what to do about it, because the reflex is to pass the atom anyway" do
      message =
        assert_raise(ArgumentError, fn -> State.requires(:invented) end)
        |> Map.fetch!(:message)

      assert message =~ "Add it to Trinity.Permissions.Policy.State with what it requires"
    end
  end

  describe "what it records" do
    test "a deny is unchanged by any state, and records nothing as having changed it" do
      assert {:deny, []} = State.tighten(:deny, State.kinds())
    end

    test "an allow under untrusted context becomes an ask, and says which state did it" do
      assert {:ask, [:untrusted_context]} = State.tighten(:allow, [:untrusted_context])
    end

    test "only the states that actually moved the decision are recorded" do
      # :unattended would raise an allow to :ask, but :over_budget has already taken it to :deny.
      assert {:deny, [:over_budget]} = State.tighten(:allow, [:over_budget, :unattended])
    end

    test "the basis names the states that tightened, and is untouched when none did" do
      assert State.basis("session_grant", []) == "session_grant"
      assert State.basis("persona", [:over_budget]) == "persona+state:over_budget"
    end
  end

  # Every subset of `kinds`, and every ordering of each subset: order must not matter, and the only
  # honest way to assert that is to try them.
  defp permutations_of_subsets(kinds) do
    for n <- 0..length(kinds), subset <- combinations(kinds, n), p <- permutations(subset), do: p
  end

  defp combinations(_, 0), do: [[]]
  defp combinations([], _), do: []

  defp combinations([h | t], n),
    do: Enum.map(combinations(t, n - 1), &[h | &1]) ++ combinations(t, n)

  defp permutations([]), do: [[]]
  defp permutations(list), do: for(h <- list, t <- permutations(list -- [h]), do: [h | t])
end
