# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.Supervisor do
  @moduledoc """
  The MCP clients (slice 060): one `Trinity.MCP.Client` per enabled server row, started at
  boot by `Trinity.MCP.Boot` and by the servers context when a row is added or enabled,
  stopped when it is disabled or removed. A client that stops on its own (a refused
  revision) is not restarted: its status is on the page and the owner acts.
  """
  use DynamicSupervisor

  alias Trinity.MCP.{Client, ServerConfig}

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts),
    do: DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 10, max_seconds: 60)

  @doc "Starts the client for a row (a running one is left as it is)."
  @spec start_client(ServerConfig.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_client(%ServerConfig{} = config, opts \\ []) do
    case DynamicSupervisor.start_child(__MODULE__, {Client, {config, client_opts(opts)}}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, _} = error -> error
    end
  end

  @doc "Stops the client for a server name, if one runs."
  @spec stop_client(String.t()) :: :ok
  def stop_client(name) do
    case Client.whereis(name) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(__MODULE__, pid)
    end
  end

  @doc "The running clients' names."
  @spec running() :: [String.t()]
  def running do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(__MODULE__),
        is_pid(pid),
        {:ok, %{name: name}} <- [Client.info(pid)],
        do: name
  end

  defp client_opts(opts), do: Keyword.merge(Application.get_env(:trinity, :mcp_client, []), opts)
end
