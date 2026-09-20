# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Permissions do
  @moduledoc """
  The permission gate's door. Slice 020 ships the shape; slice 021 the policy, the grants, the
  approvals and the `approval_wait` path.

  `tier/1` is a function of the tool name alone (docs/07), read from a module attribute this
  module owns: the core tool names 022 adds carry their tiers here, and any other name, a
  namespaced dynamic tool included, is `:ask`. The map is code, not config, and it reads no
  registry, so nothing a caller passes and nothing registered at runtime can move a tier.
  `decide/3` consults the policy implementation in force (`config :trinity,
  :permissions_policy`, default `Trinity.Permissions.Policy.Default`, which allows everything
  until 021), and the runner calls it exactly once per tool call.
  """
  use Boundary, deps: [Trinity], exports: [Policy]

  # Core tool names and their tiers. Empty at slice 020: no core tool lives in lib/ yet; 022
  # adds fs_read, fs_write, web_fetch, shell and the rest here, beside their modules.
  @tiers %{}

  @type tier :: :read | :write | :exec | :network | :destructive | :ask
  @type decision :: :allow | :deny | :ask

  defmodule Policy do
    @moduledoc "What decides a call. Slice 021 implements the layered policy; the default allows."
    @callback decide(session_id :: String.t() | nil, tool :: String.t(), args :: map()) ::
                Trinity.Permissions.decision()

    defmodule Default do
      @moduledoc false
      @behaviour Trinity.Permissions.Policy
      @impl true
      def decide(_session_id, _tool, _args), do: :allow
    end
  end

  @doc "The risk tier for a name: a mapped core name's tier, else `:ask`."
  @spec tier(String.t()) :: tier()
  def tier(name) when is_binary(name), do: Map.get(tiers(), name, :ask)

  @doc "The mapped core names, for the census."
  @spec mapped_names() :: [String.t()]
  def mapped_names, do: Map.keys(tiers())

  # Through a function so an empty map at this slice reads as a map to the type checker,
  # not as a constant it can fold to :ask.
  defp tiers, do: Map.new(@tiers)

  @doc "The decision for one call, from the policy in force."
  @spec decide(String.t() | nil, String.t(), map()) :: decision()
  def decide(session_id, tool, args), do: impl().decide(session_id, tool, args)

  defp impl, do: Application.get_env(:trinity, :permissions_policy, Policy.Default)
end
