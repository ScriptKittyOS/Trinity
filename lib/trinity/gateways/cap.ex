# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.Cap do
  @moduledoc """
  What an approval arriving from a channel may authorise (slice 070; docs/07 "Gateways", the
  channel trust cap).

  The allowlist, the pairing and the rate limit control *who may talk to Trinity*. They say
  nothing about *what an approval from that channel may allow to happen*, and an approval surface
  is exactly as trustworthy as the account behind it: a messaging account is a password reset and
  a phone number away from someone else's hands, and the desktop is not. So a tier ceiling is
  applied to every decision arriving through a gateway, **after** the permission gate has made its
  own decision and never instead of it: the gate can still refuse what the cap would have allowed.

  The default ceiling is `:write`, so `:read`, `:network` and `:write` are answerable from a
  paired channel and `:exec` and `:destructive` are not. A capped request is answered, not
  dropped: the conversation is told where the decision has to be made, and the refusal is
  receipted like any other, because a silent refusal teaches a person that the bot is broken.

  The ceiling is per adapter (`config :trinity, :gateways, caps: %{"console" => :write}`) so a
  deployment can raise or lower one channel without touching the others. `Console` is capped like
  any other adapter and not exempted: docs/07 was written before this slice and reads "desktop or
  console only", meaning the machine's own surfaces; an in-process adapter is still a channel, and
  making it the one channel that may approve a destructive effect would be a hole shaped exactly
  like the thing the cap exists for.
  """

  alias Trinity.Gateways.Adapter

  @order [:read, :network, :write, :exec, :destructive]
  @default_ceiling :write

  @doc "The tiers, weakest first."
  @spec order() :: [atom()]
  def order, do: @order

  @doc "The ceiling in force for an adapter."
  @spec ceiling(module() | String.t()) :: atom()
  def ceiling(adapter) when is_atom(adapter) and not is_nil(adapter),
    do: adapter |> Adapter.name() |> ceiling()

  def ceiling(adapter_name) when is_binary(adapter_name) do
    :trinity
    |> Application.get_env(:gateways, [])
    |> Keyword.get(:caps, %{})
    |> Map.get(adapter_name, @default_ceiling)
  end

  @doc """
  Whether a decision on a request of this tier may be made from this channel. An unknown tier is
  refused: a tier this module does not know is not a tier it may wave through.
  """
  @spec allows?(module() | String.t(), atom() | String.t() | nil) :: boolean()
  def allows?(adapter, tier) do
    with {:ok, tier} <- normalise(tier),
         {:ok, ceiling} <- normalise(ceiling(adapter)) do
      index(tier) <= index(ceiling)
    else
      :error -> false
    end
  end

  @doc "Why a request was capped, in words a person in the channel can act on."
  @spec refusal(module() | String.t(), atom() | String.t() | nil) :: String.t()
  def refusal(adapter, tier) do
    "That is a #{tier} request, and this channel may approve up to #{ceiling(adapter)}. " <>
      "Decide it on the desktop, on the permissions page."
  end

  defp normalise(tier) when is_atom(tier) and not is_nil(tier),
    do: normalise(Atom.to_string(tier))

  defp normalise(tier) when is_binary(tier) do
    case Enum.find(@order, &(Atom.to_string(&1) == tier)) do
      nil -> :error
      found -> {:ok, found}
    end
  end

  defp normalise(_other), do: :error

  defp index(tier), do: Enum.find_index(@order, &(&1 == tier))
end
