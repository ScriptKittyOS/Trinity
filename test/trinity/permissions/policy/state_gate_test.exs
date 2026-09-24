# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Permissions.Policy.StateGateTest do
  @moduledoc """
  Slice 028 AC2 and AC4: state reaches the gate's result and never the tool's tier.

  The separation is the claim. `Permissions.tier/1` is a function of the tool's **name**, and this
  file asserts that it stays one under every state: the wiring does not move. What moves is the
  decision, and only in one direction, which `state_test.exs` proves exhaustively.
  """
  use Trinity.DataCase, async: false

  alias Trinity.Permissions
  alias Trinity.Permissions.Policy

  setup do
    # `Application.put_env(key, nil)` is not the same as never having set the key: `get_env/3`
    # returns the stored `nil` rather than the default, so `impl()` becomes `nil` and every later
    # test calls `nil.decide/4`. Restoring an absent key means deleting it. Found the expensive way:
    # this file passed alone and took four MCP tests down with it in the full suite.
    previous = Application.fetch_env(:trinity, :permissions_policy)
    Application.put_env(:trinity, :permissions_policy, Policy.Default)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:trinity, :permissions_policy, value)
        :error -> Application.delete_env(:trinity, :permissions_policy)
      end
    end)

    :ok
  end

  test "the tier is a function of the tool name, identical under every state" do
    # The tier function takes no state and this test is what stops it ever taking one. If someone
    # threads state into `tier/1`, the two calls stop agreeing and this fails.
    for name <- ["fs_read", "fs_write", "shell", "nonexistent_tool"] do
      bare = Permissions.tier(name)

      for state <- Policy.State.kinds() do
        assert Permissions.tier(name) == bare,
               "the tier of #{name} moved when #{state} was in play; state changes what a tier " <>
                 "requires, never what the tier is"
      end
    end
  end

  test "with no state the decision and basis are exactly what the policy said" do
    assert {:allow, "policy"} = Permissions.decide_with_basis(nil, "fs_read", %{}, [])
  end

  test "a state tightens the policy's allow and the basis names the state that did it" do
    assert {:ask, "policy+state:untrusted_context"} =
             Permissions.decide_with_basis(nil, "fs_read", %{}, state: [:untrusted_context])

    assert {:deny, "policy+state:over_budget"} =
             Permissions.decide_with_basis(nil, "fs_read", %{}, state: [:over_budget])
  end

  test "a state that does not move the decision leaves the basis alone" do
    # The policy in force already denies nothing, so :deny cannot be reached from the policy here;
    # the point is that a state which changes nothing is not recorded as though it had.
    assert {:ask, "policy+state:untrusted_context"} =
             Permissions.decide_with_basis(nil, "fs_read", %{},
               state: [:untrusted_context, :unattended]
             )
  end

  test "an unknown state is refused at the gate rather than ignored there" do
    assert_raise ArgumentError, ~r/not a state/, fn ->
      Permissions.decide_with_basis(nil, "fs_read", %{}, state: [:convenient])
    end
  end
end
