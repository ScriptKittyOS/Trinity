# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Permissions.Policy do
  @moduledoc """
  What decides a call. The implementation in force is `config :trinity, :permissions_policy`
  (`Trinity.Permissions.Policy.Layered` by default); `Default` allows everything and exists
  for tests that want no gate.
  """

  @doc "The decision for a call. `opts`: `persona:`, `cwd:`."
  @callback decide(
              session_id :: String.t() | nil,
              tool :: String.t(),
              args :: map(),
              opts :: keyword()
            ) :: Trinity.Permissions.decision()

  defmodule Default do
    @moduledoc "Allows everything. Slice 020's stub, kept for tests that want no gate."
    @behaviour Trinity.Permissions.Policy
    @impl true
    def decide(_session_id, _tool, _args, _opts), do: :allow
  end
end
