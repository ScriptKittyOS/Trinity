# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.Boot do
  @moduledoc """
  Starts a client for every enabled server row when the application boots (slice 060). A
  database that cannot answer (no table yet: the postgres CI job boots the application
  before it migrates) is a warning, not a boot failure, as `Trinity.Permissions.Gate` treats
  its reload; the servers page starts the clients later. Set `config :trinity, :mcp_boot,
  false` to boot none (the test suite does: every test starts the clients it needs).
  """
  use Task, restart: :temporary

  require Logger

  alias Trinity.MCP.Servers

  @spec start_link(term()) :: {:ok, pid()}
  def start_link(_), do: Task.start_link(__MODULE__, :run, [])

  @doc false
  def run do
    if Application.get_env(:trinity, :mcp_boot, true) do
      try do
        for config <- Servers.list(enabled: true), do: Servers.start(config)
      rescue
        e -> Logger.warning("mcp boot: servers not started: #{Exception.message(e)}")
      end
    end

    :ok
  end
end
