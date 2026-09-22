# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Mix.Tasks.Trinity.Mcp.Stdio do
  @shortdoc "Serves Trinity as an MCP server over stdio (dual-era: 2026-07-28 and 2025-11-25)"
  @moduledoc """
  Slice 061. Starts the application and runs beam_mcp's stdio transport with Trinity's server
  above the core, for a client that launches its servers as child processes (the common
  configuration of Claude Code and its peers) and for a 2025-11-25 client, which the HTTP
  route does not serve (the core's transport is 2026-07-28 alone by design).

      mix trinity.mcp.stdio

  Two things a client's configuration must know. This is a whole Trinity, and the data
  directory admits one at a time (`Trinity.DataDir.Lock`): it runs when the desktop or the
  headless server does not, or against its own data directory (`TRINITY_DATA_DIR`). And the
  VM's log goes to standard error here, never to standard output, which is the wire.
  """
  # Classified into the MCP boundary, the one that may reach the server (the other tasks are
  # `Trinity`'s, which never names `Trinity.MCP`).
  use Boundary, classify_to: Trinity.MCP
  use Mix.Task

  @impl Mix.Task
  def run(_argv) do
    # Before the application starts (what boots logs too), and again inside `run/1`.
    Trinity.MCP.Server.Stdio.log_to_stderr()
    Mix.Task.run("app.start")
    Trinity.MCP.Server.Stdio.run()
  end
end
