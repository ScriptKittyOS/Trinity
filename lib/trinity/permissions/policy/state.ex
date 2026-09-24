# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Permissions.Policy.State do
  @moduledoc """
  Context can make the gate stricter. It can never make it looser (slice 028).

  From the connectome research report's A7: hunger, arousal and the neuromodulators act as global
  gain on an insect's circuits. They change the threshold at which a behaviour fires; they do not
  rewire the circuit. The wiring is fixed and the gain is state.

  Trinity's wiring is the tier, which is a function of the tool's **name** alone, and this module is
  the gain. A state raises what a call requires. No state changes what the tool *is*, and no state
  can turn a refusal into a permission.

  ## Why the one-way constraint is the whole design

  A context input that can loosen is an input worth attacking. Every state this module names is
  derived from something an attacker may be able to influence: whether the turn has read untrusted
  content, whether a budget is exhausted, whether anyone is at the machine. If any of those could
  *widen* authority, the useful move for an attacker would be to arrange the state rather than to
  argue with the gate, and arranging state is quieter.

  So the constraint is in the types rather than in a review. `requires/1` returns `:ask` or `:deny` and
  has no clause that can return `:allow`, which means no state is ever a licence. `tighten/2` takes the
  strictest of the gate's own decision and every active state's floor, so adding a state to the list
  can only move the result one way. The property test is the criterion: an example test would pass on
  a modifier that happened to tighten for the cases someone thought of.

  ## Which states have a producer today

  `:over_budget` is measured in `Trinity.Tools.Runner` from the slice 090 cost ledger. The other
  three are defined and have no producer yet: `:receipts_degraded` would read
  `Trinity.Receipts.Alarm`, which is a boundary the runner does not depend on, and
  `:untrusted_context` and `:unattended` need a turn-scoped signal the session does not carry. They
  are named here rather than omitted because the set being closed is what makes an unknown atom a
  refusal, and because a gap stated is a gap someone can close.

  ## This module measures nothing

  It is pure, and the caller supplies the active states. That is deliberate twice over: a pure
  function is the thing you can prove monotone, and the signals live in boundaries this one does not
  reach. A caller that can see the cost ledger or the receipt alarm passes what it sees.

  ## Naming

  `SLICE.md` calls this `Trinity.Policy.State` at `lib/trinity/policy/state.ex`. The tree's policy
  seam is `Trinity.Permissions.Policy`, so it lives beside it; a second top-level `Trinity.Policy`
  would be a different thing with almost the same name.
  """
  # No `use Boundary` here: a module nested under `Trinity.Permissions` already belongs to that
  # boundary, and `classify_to:` is only for Mix tasks and protocol implementations.
  alias Trinity.Permissions

  @typedoc """
  The closed set of states. Each is derived from something the tree already measures:

  * `:untrusted_context` - this turn has consumed content from outside the machine (slice 060's
    tool results, slice 070's channels, a fetched page). The content is marked untrusted at the
    boundary already; this is that mark reaching the gate.
  * `:over_budget` - the cost ledger says a budget is exceeded (slice 090).
  * `:receipts_degraded` - the receipt chain's alarm is set, so an effect may not be recordable
    (slice 024). An effect that cannot be receipted is an effect nobody can reconstruct.
  * `:unattended` - nobody is at the machine to answer, so a call that would have asked should not
    silently proceed.
  """
  @type kind :: :untrusted_context | :over_budget | :receipts_degraded | :unattended

  @kinds [:untrusted_context, :over_budget, :receipts_degraded, :unattended]

  # Strictness order. `apply/2` takes the maximum, so the order is the whole mechanism.
  @strictness %{allow: 0, ask: 1, deny: 2}

  @doc "Every state kind. The set is closed: an atom outside it is a refusal, not a state."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  The weakest decision a state permits.

  There is no clause returning `:allow`, and that absence is the guarantee: a state can require a
  decision, so it cannot grant one.

  Named `requires/1` rather than `floor/1`: `Kernel.floor/1` exists, and `tighten/2` beside it says
  at every call site which direction this seam runs in.
  """
  @spec requires(kind()) :: :ask | :deny
  def requires(:untrusted_context), do: :ask
  def requires(:over_budget), do: :deny
  def requires(:receipts_degraded), do: :deny
  def requires(:unattended), do: :ask

  def requires(other) do
    raise ArgumentError,
          "#{inspect(other)} is not a state. The set is closed (#{inspect(@kinds)}) so that a " <>
            "state cannot be introduced at a call site without a requirement anyone can read. Add it " <>
            "to Trinity.Permissions.Policy.State with what it requires, or do not pass it."
  end

  @doc """
  The gate's decision, tightened by the active states.

  Returns the decision and the states that actually changed it, so the caller can record *why* a
  call needed more than its tier implies rather than recording that some state was present.
  """
  @spec tighten(Permissions.decision(), [kind()]) :: {Permissions.decision(), [kind()]}
  def tighten(decision, states) when decision in [:allow, :deny, :ask] and is_list(states) do
    Enum.reduce(states, {decision, []}, fn state, {current, applied} ->
      case strictest(current, requires(state)) do
        ^current -> {current, applied}
        tighter -> {tighter, applied ++ [state]}
      end
    end)
  end

  @doc "A basis string naming the states that tightened a decision, for the receipt and the approval."
  @spec basis(String.t(), [kind()]) :: String.t()
  def basis(policy_basis, []), do: policy_basis
  def basis(policy_basis, applied), do: policy_basis <> "+state:" <> Enum.join(applied, ",")

  defp strictest(a, b), do: if(@strictness[a] >= @strictness[b], do: a, else: b)
end
