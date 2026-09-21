# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.ServersUnderTest do
  @moduledoc """
  Starting and waiting on the servers under test (slice 060): the HTTP server is beam_mcp's
  Plug behind Bandit on a random loopback port in the test VM; the stdio servers are child
  VMs (`Trinity.MCP.StdioServer`). `start!/3` writes the row through the context, which
  starts the client, and registers the teardown; `await/3` waits for a status.
  """

  alias Trinity.MCP.{Client, ServerConfig, Servers, StdioServer}

  @doc "Starts beam_mcp's HTTP transport over the test catalog on a random port; returns the URL."
  @spec http_server!() :: String.t()
  def http_server! do
    # Bandit calls the Plug's `init/1` itself.
    plug_opts = [
      catalog: Trinity.MCP.TestCatalog,
      dispatch: &Trinity.MCP.TestCatalog.dispatch/3,
      authorize: fn _conn -> :ok end,
      allowed_origins: :any,
      server_name: "trinity-test-http"
    ]

    {:ok, pid} =
      Bandit.start_link(
        plug: {BeamMCP.Transport.HTTP, plug_opts},
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)

    ExUnit.Callbacks.on_exit(fn ->
      try do
        GenServer.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    "http://127.0.0.1:#{port}/mcp"
  end

  @doc "A row for a server under test: `:modern`, `:legacy`, `:mrtr` (stdio) or `{:http, url}`."
  @spec attrs(String.t(), term(), map()) :: map()
  def attrs(name, {:http, url}, extra),
    do: Map.merge(%{name: name, transport: "http", url: url}, extra)

  def attrs(name, kind, extra), do: StdioServer.config(name, kind, extra)

  @doc "Creates the row (which starts the client), registers its teardown, and returns it."
  @spec start!(String.t(), term(), map()) :: ServerConfig.t()
  def start!(name, kind, extra \\ %{}) do
    {:ok, config} = Servers.create(attrs(name, kind, extra))
    ExUnit.Callbacks.on_exit(fn -> Trinity.MCP.Supervisor.stop_client(name) end)
    config
  end

  @doc "Waits until the client's status is `status` (or one of a list); returns its info."
  @spec await(String.t(), atom() | [atom()], pos_integer()) :: map()
  def await(name, status, timeout_ms \\ 10_000) do
    statuses = List.wrap(status)
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await(name, statuses, deadline)
  end

  defp do_await(name, statuses, deadline) do
    case Client.info(name) do
      {:ok, %{status: s} = info} ->
        if s in statuses, do: info, else: wait(name, statuses, deadline, {:ok, info})

      other ->
        wait(name, statuses, deadline, other)
    end
  end

  defp wait(name, statuses, deadline, other) do
    if System.monotonic_time(:millisecond) > deadline do
      raise "mcp #{name}: waited for #{inspect(statuses)}, last seen #{inspect(other)}"
    else
      Process.sleep(50)
      do_await(name, statuses, deadline)
    end
  end
end
