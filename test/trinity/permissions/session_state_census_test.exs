# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Permissions.SessionStateCensusTest do
  @moduledoc """
  Slice 027 AC2: the decision path never reads session or task state.

  The connectome research report's A5 is the reason this is a test and not a convention. The fly's
  central complex holds one heading at a time and the heading informs behaviour, but the heading is
  not a motor command: the descending neurons are. Trinity's equivalent claim is that a session's
  conversational state can inform what the assistant *proposes* and can never be an input to what
  the gate *decides*.

  **Why it matters more here than the analogy suggests.** Every message in a session is a place an
  injected instruction can sit. A gate that reads conversation state is a gate an attacker can
  argue with, and the argument does not even have to be convincing to a person: it has to move one
  boolean. Keeping the decision blind to the conversation is what makes prompt injection a
  proposal problem rather than an authorization problem.

  **What is allowed, and the distinction is the whole test.** The session *id* is a scope key: a
  grant is stored as `session:<id>` and an approval belongs to a session row, and both are
  identity, not state. What is forbidden is reading what the session has been *doing*: its history,
  its row, its list. Identity narrows a grant; state would steer a decision.

  The population is the decision path from `git ls-files`, plus one planted reader that must be
  found or this census is not looking.
  """
  use ExUnit.Case, async: true

  # Reading any of these from the decision path means the decision can move with the conversation.
  @state_calls ~w(history get_session list_sessions state)

  @globs ~w(lib/trinity/permissions lib/trinity/effects lib/trinity/authority)
  @membrane "lib/trinity/effects.ex"
  @planted "test/support/permissions/session_state_reader.ex"

  defp population do
    {out, 0} = System.cmd("git", ["ls-files" | @globs ++ [@membrane, @planted]])
    out |> String.split("\n", trim: true) |> Enum.filter(&String.ends_with?(&1, ".ex"))
  end

  # A call into the Sessions context for one of the state-bearing functions. Both `Sessions.history(`
  # and the fully qualified `Trinity.Sessions.history(` match, which is why the lookbehind excludes
  # a word character and not a dot: the first version of this excluded a dot too, and so could not
  # see the fully qualified call that the planted reader actually makes. The planted file caught
  # that, which is what it is for. `belongs_to :session, Trinity.Sessions.SessionRow` does not
  # match: it is a schema association and carries no call.
  defp reads_state?(source) do
    Enum.any?(@state_calls, fn call ->
      Regex.match?(~r/(?<!\w)Sessions\.#{call}\(/, source)
    end)
  end

  test "the population is the decision path and it is not empty" do
    files = population()

    assert length(files) >= 8,
           "the census is looking at #{length(files)} files: #{inspect(files)}"

    assert @membrane in files
    assert @planted in files
  end

  test "only the planted reader reads session state from the decision path" do
    readers = for f <- population(), reads_state?(File.read!(f)), do: f

    assert readers == [@planted],
           "a module on the decision path reads session state: #{inspect(readers -- [@planted])}. " <>
             "The session id is a scope key and is allowed; what the session has been saying is " <>
             "not an input to a decision. If this is deliberate, it needs an ADR, not a passing test"
  end

  test "the planted reader really does decide from the conversation, or this census proves nothing" do
    source = File.read!(@planted)
    assert reads_state?(source)
    assert source =~ "def lenient?"
  end
end
