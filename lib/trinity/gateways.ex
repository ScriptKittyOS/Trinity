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

  Adapters are configured, not compiled in: `config :trinity, :gateways, adapters: [Module, …]`,
  or by name from the `available:` list (`TRINITY_GATEWAYS=telegram`, slice 071). `Console` ships
  here and is what the tests and `mix trinity.console` talk to; `Telegram` is the first platform,
  and `Mattermost` (slice 072) the second.
  `Trinity.Gateways.Supervisor` runs the router and the adapters in force, and nothing when there
  are none.
  """
  use Boundary,
    deps: [Trinity, Trinity.Sessions],
    exports: [
      Adapter,
      Cap,
      Console,
      Format,
      Identities,
      Identity,
      Mattermost,
      Router,
      Supervisor,
      Telegram
    ]

  @doc """
  The adapter modules in force: those named in `adapters:`, then those from `available:` whose
  name (`Trinity.Gateways.Adapter.name/1`) is in `enabled:`, each once.
  """
  @spec adapters() :: [module()]
  def adapters do
    config = Application.get_env(:trinity, :gateways, [])
    enabled = Keyword.get(config, :enabled, [])

    named =
      config
      |> Keyword.get(:available, [])
      |> Enum.filter(&(Trinity.Gateways.Adapter.name(&1) in enabled))

    Enum.uniq(Keyword.get(config, :adapters, []) ++ named)
  end

  @doc """
  The adapter in force whose name (`Trinity.Gateways.Adapter.name/1`) is `name`, or nil (slice
  072). This is how anything holding a name from outside (a callback URL) reaches an adapter: by
  looking it up among the ones in force, never by turning the outside value into a module.
  """
  @spec find(String.t()) :: module() | nil
  def find(name) when is_binary(name),
    do: Enum.find(adapters(), &(Trinity.Gateways.Adapter.name(&1) == name))

  @doc """
  An HTTP callback from a platform, handed to the adapter in force named `name` (slice 072). The
  web layer calls this and nothing more specific: it never learns which platforms exist. Answers
  `{:error, :not_found}` when no adapter in force has that name or the adapter takes no callbacks,
  so an unconfigured platform is indistinguishable from a path that does not exist.
  """
  @spec callback(String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, :not_found | :forbidden | :bad_request}
  def callback(name, kind, params) when is_binary(name) and is_binary(kind) and is_map(params) do
    with adapter when not is_nil(adapter) <- find(name),
         true <- Code.ensure_loaded?(adapter) and function_exported?(adapter, :callback, 2) do
      adapter.callback(kind, params)
    else
      _ -> {:error, :not_found}
    end
  end
end
