# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.Supervisor do
  @moduledoc """
  The gateways in the application's tree (slice 071): the router, then each adapter in force
  (`Trinity.Gateways.adapters/0`), one for one.

  Until this slice nothing in the application started a gateway; 070's router and console ran
  under the suite, `mix trinity.console` and a script. A platform adapter has to run in the
  application itself, so this is where it does. With no adapter configured it starts no child at
  all, so a desktop that uses no gateway runs exactly what it ran before, and the suite (which
  starts its own router per test) is unaffected.

  The router comes first because an adapter's first act on an inbound message is to call it.
  """
  use Supervisor

  alias Trinity.Gateways
  alias Trinity.Gateways.Router

  @doc "Starts the gateways' supervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl Supervisor
  def init(_opts), do: Supervisor.init(children(Gateways.adapters()), strategy: :one_for_one)

  @doc "The children for a list of adapters: none for none, else the router and each adapter."
  @spec children([module()]) :: [Supervisor.child_spec() | {module(), term()} | module()]
  def children([]), do: []
  def children(adapters), do: [Router | Enum.map(adapters, &{&1, []})]
end
