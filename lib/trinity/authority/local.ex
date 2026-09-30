# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Authority.Local do
  @moduledoc """
  The authority this tree ships (ADR-0008 decision 2): the permission gate's decision is the
  decision, and the receipt is local.

  **It is not an executor.** Under the owner's ruling of 2026-09-30 the tool runs in
  `Trinity.Effects`, in this VM, after a `decide/3` allow, whichever authority is in force. This
  module used to be the one place in the tree that called a tool's `execute/2`; that call now
  lives in the membrane, and the census test in test/trinity/effects/census_test.exs holds the
  new shape. `execute/3` here answers `{:error, :not_the_effect_path}`: it is on no path, and a
  caller that reaches it has gone somewhere that no longer exists.
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
  def execute(%Staged{}, _decision, _ctx), do: {:error, :not_the_effect_path}

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
