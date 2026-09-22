# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.Server.Stdio do
  @moduledoc """
  Trinity's MCP server over stdio (slice 061): beam_mcp's stdio transport with
  `Trinity.MCP.Server` above the core, dual-era (the core serves 2026-07-28 and 2025-11-25 on
  stdio; the HTTP transport serves the modern revision alone). Whoever can write to this
  process's standard input already has the host's privileges, which is why there is no bearer
  here, as the core's own page says. `run/1` blocks until end of input.
  """

  alias Trinity.MCP.Server.Catalog

  @doc "Runs the loop on standard input and output until end of input; the VM's log is moved to standard error first."
  @spec run(keyword()) :: :ok
  def run(opts \\ []) do
    log_to_stderr()
    config = Application.get_env(:trinity, :mcp_server, [])

    BeamMCP.Transport.Stdio.run(
      Keyword.merge(
        [
          server: Trinity.MCP.Server,
          catalog: Catalog,
          server_name: Keyword.get(config, :server_name, "trinity"),
          tools_ttl_ms: Keyword.get(config, :tools_ttl_ms, 60_000),
          tools_cache_scope: Keyword.get(config, :tools_cache_scope, "private")
        ],
        opts
      )
    )
  end

  # The default log handler writes to standard output, which is the wire here (a logged line
  # is an undecodable message to the client); it is replaced after the application started,
  # since the logger application installs it again on start. Idempotent.
  @doc false
  def log_to_stderr do
    # The logger application would install its default handler again on start; told not to.
    Application.put_env(:logger, :default_handler, false)
    _ = :logger.remove_handler(:default)
    _ = :logger.remove_handler(:stderr)
    :logger.add_handler(:stderr, :logger_std_h, %{config: %{type: :standard_error}})
    :ok
  end
end
