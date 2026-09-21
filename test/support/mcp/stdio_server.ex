# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.StdioServer do
  @moduledoc """
  How a test launches the stdio servers (slice 060): a child `elixir` VM with this build's
  `ebin` directories on its path, running `test/support/mcp/stdio_server.exs` (beam_mcp's
  transport over the test catalog) or `test/support/mcp/mrtr_server.exs` (Trinity's double
  for the multi-round-trip wire). The command is what a `mcp_servers` row would hold.
  """

  @doc "The row attributes for a stdio server under test: `:modern`, `:legacy`, `:mrtr` or `:future` (a revision nobody speaks)."
  @spec config(String.t(), :modern | :legacy | :mrtr | :future, map()) :: map()
  def config(name, kind, extra \\ %{}) do
    {script, args} =
      case kind do
        :modern -> {"test/support/mcp/stdio_server.exs", []}
        :legacy -> {"test/support/mcp/stdio_server.exs", ["legacy"]}
        :mrtr -> {"test/support/mcp/mrtr_server.exs", []}
        :future -> {"test/support/mcp/mrtr_server.exs", ["future"]}
      end

    Map.merge(
      %{
        name: name,
        transport: "stdio",
        command: "elixir",
        args: paths() ++ [Path.expand(script)] ++ args
      },
      extra
    )
  end

  # The child needs beam_mcp and what it calls (jason, telemetry) and this application's own
  # beams (the catalog lives in test/support, compiled into the trinity ebin).
  defp paths do
    Enum.flat_map([:beam_mcp, :jason, :telemetry, :trinity], fn app ->
      ["-pa", Path.expand(:code.lib_dir(app) |> to_string() |> Path.join("ebin"))]
    end)
  end
end
