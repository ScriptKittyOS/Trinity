# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
#
# Slice 060: the stdio server under test, beam_mcp's own transport over the test catalog,
# run as a child VM by `Trinity.MCP.StdioServer.command/1`:
#   elixir -pa <ebins> test/support/mcp/stdio_server.exs [legacy]
# With `legacy` the server advertises 2025-11-25 alone, so the driver takes the initialize
# path. Everything the VM prints on its own goes to stderr; stdout is the wire.
# The VM's default log handler writes to standard output, which is the wire here: a logged
# error would be an undecodable line to the client. Logging goes to standard error instead.
:logger.remove_handler(:default)
:logger.add_handler(:stderr, :logger_std_h, %{config: %{type: :standard_error}})

versions =
  case System.argv() do
    ["legacy" | _] -> ["2025-11-25"]
    _ -> ["2026-07-28", "2025-11-25"]
  end

BeamMCP.Transport.Stdio.run(
  catalog: Trinity.MCP.TestCatalog,
  dispatch: &Trinity.MCP.TestCatalog.dispatch/3,
  server_name: "trinity-test-stdio",
  supported_versions: versions
)
