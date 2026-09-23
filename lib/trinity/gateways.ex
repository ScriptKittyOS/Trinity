# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways do
  @moduledoc """
  Trinity reached from somewhere other than the desktop (slice 070): a chat channel, a terminal,
  later a messaging platform. A gateway is an adapter process plus `Router`, and the rule that
  makes the layer safe to extend is that an adapter carries text and nothing else: it never calls
  the LLM, never touches a session, and never decides an approval. Whether an effect happens is
  the permission gate's answer, as it is for the desktop, and what an approval arriving from a
  channel may authorise is capped besides (`Cap`, docs/07 "Gateways").

  Adapters are configured, not compiled in: `config :trinity, :gateways, adapters: [Module, …]`.
  `Console` ships here and is what the tests and `mix trinity.console` talk to.
  """
  use Boundary,
    deps: [Trinity, Trinity.Sessions],
    exports: [Adapter, Cap, Console, Format, Identities, Identity, Router]

  @doc "The adapter modules in force."
  @spec adapters() :: [module()]
  def adapters, do: Application.get_env(:trinity, :gateways, []) |> Keyword.get(:adapters, [])
end
