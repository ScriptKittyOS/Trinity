# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.NetworkGuard do
  @moduledoc """
  docs/03-conventions.md: tests do not reach the network.

  The block applies to the **default** test run only. `docs/03-conventions.md`
  both define an opt-in path (`@tag :live`, run with `mix test --only live`) for tests that
  exist precisely to reach a real provider. Blocking those by construction would break the path
  the plan defines, so the guard opens when `TRINITY_LIVE=1` is set and the gate excludes
  `:live`.

  **Stated limit.** This is a chokepoint, not a sandbox: it constrains code that calls
  `connect/3`, and it cannot stop a library that opens its own socket. The census test that
  asserts this is the only outbound path belongs with the HTTP layer at slice 011.
  """

  @doc "Opens a TCP connection, or refuses when the default test run is in force."
  @spec connect(charlist() | :inet.ip_address(), :inet.port_number(), keyword()) ::
          {:ok, :inet.socket()} | {:error, term()}
  def connect(host, port, opts \\ []) do
    if allowed?() do
      :gen_tcp.connect(host, port, opts)
    else
      {:error, :network_blocked_in_test}
    end
  end

  @doc "True when the network is open: any environment but `:test`, or the live flag is set."
  @spec allowed?() :: boolean()
  def allowed?, do: Mix.env() != :test or System.get_env("TRINITY_LIVE") == "1"
end
