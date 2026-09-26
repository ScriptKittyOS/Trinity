# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Authority.Local do
  @moduledoc """
  The authority this tree ships (ADR-0008 decision 2): the permission gate's decision is the
  decision, the effect runs here, the receipt is local. `execute/3` is the one place in the
  tree that calls a tool's `execute/2` for an effectful tool; the census test in
  test/trinity/effects/census_test.exs holds that, and when an external adapter is in force
  this module is not the one selected, so Trinity keeps no executor for the effects that
  adapter governs (decision 5).
  """
  @behaviour Trinity.Authority

  alias Trinity.Authority.Staged

  @impl true
  def stage(%Staged{} = staged, _ctx), do: {:ok, %{staged | staged_at: DateTime.utc_now()}}

  @impl true
  def decide(%Staged{}, :allow, _ctx), do: {:ok, :allow, %{"by" => "gate"}}
  def decide(%Staged{}, :deny, _ctx), do: {:ok, :deny, %{"by" => "gate"}}
  def decide(%Staged{}, :ask, _ctx), do: {:ok, :deny, %{"by" => "gate", "reason" => "undecided"}}

  @impl true
  def execute(%Staged{module: module, args: args}, :allow, ctx) do
    module.execute(args, ctx)
  rescue
    e -> {:error, {:crash, {e, __STACKTRACE__}}}
  end

  def execute(%Staged{}, :deny, _ctx), do: {:error, :denied}

  @impl true
  def receipt(kind, attrs) when is_binary(kind) and is_map(attrs) do
    scope = Map.fetch!(attrs, :scope)
    Trinity.Receipts.append(scope, Map.put(attrs, :kind, kind))
  end

  @doc """
  Acknowledges a queued envelope (slice 026).

  Standalone, there is no far side and nothing to send to, so this acknowledges immediately. It is
  not a stub: it is what makes the local authority exercise the same queue-and-acknowledge path an
  adapter does, so the mode is proven without one. A receipt still passes through the queue, is
  still acknowledged in order, and the bound still applies.
  """
  @impl true
  def forward_receipt(envelope, _meta) when is_map(envelope), do: :ok
end
