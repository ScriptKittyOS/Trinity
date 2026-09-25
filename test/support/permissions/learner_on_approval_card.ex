# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.TestPermissions.LearnerOnApprovalCard do
  @moduledoc """
  A planted violation for slice 042 AC2, and a realistic one.

  It does the tempting thing: takes a pending approval and annotates it with what the learner knows,
  so the card could show "you have allowed this 11 times". That is the feature the connectome report
  asked for and the research forbids, because a recommendation shown before a person forms their own
  assessment moves the decision, and Trinity's permission model rests on that decision being
  independent of what the agent wants.

  It reaches the learner through `Trinity.Permissions.proposals/1`, the public facade, because that
  is the realistic mistake: `Trinity.Permissions.Learner` is not exported from its boundary, so a
  direct reference to it does not compile and the boundary compiler is the first line here. The
  census below is the second, for the way in that *is* legitimate.

  It is never called. Its only job is to be found by
  `test/trinity/permissions/learner_census_test.exs`. If the census stops naming this file, the
  census has stopped working.
  """

  alias Trinity.Permissions

  @doc "Annotates a pending approval with the learner's view, which is the thing that must not exist."
  @spec hint(Trinity.Permissions.Approval.t()) :: String.t() | nil
  def hint(%{tool: tool}) do
    case Enum.find(Permissions.proposals(), &(&1.tool == tool)) do
      nil -> nil
      %{count: n, decision: d} -> "you have chosen to #{d} this #{n} times"
    end
  end
end
