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

      server_side()
    end

    :ok
  end

  # Slice 061: the server side's files (the envelope key, the bearer token when no variable
  # sets it) and the export list's refusals, said once at boot rather than on a client's first
  # request.
  defp server_side do
    Trinity.MCP.Server.Envelope.ensure_key!()

    # Slice 062: the profile's configuration, and the personal profile's authorization server
    # when chosen (refused under an external authority adapter: the raise says why); the local
    # profile's token file when no variable sets the bearer.
    config = Trinity.MCP.AuthHost.reload()
    Trinity.MCP.AuthHost.boot()

    if config.profile == :local and System.get_env(config.token_env) in [nil, ""],
      do: Trinity.MCP.Auth.Local.ensure_token!(config.token_path)

    {entries, refusals} = Trinity.MCP.Server.Exports.resolve()

    for {name, reason} <- refusals,
        do: Logger.warning("mcp server: tool #{name} not exported: #{reason}")

    Logger.info("mcp server: exporting #{length(entries)} tools at /mcp")
  rescue
    e -> Logger.warning("mcp server: not prepared: #{Exception.message(e)}")
  end
end
