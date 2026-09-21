# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP do
  @moduledoc """
  The MCP boundary (slice 059, ADR-0007 decisions 4 and 5): the one place in Trinity that may
  import `BeamMCP`. The boundary compiler checks every call into the `beam_mcp` application
  (`boundary: [default: [check: [apps: [:beam_mcp]]]]` in mix.exs), and this boundary alone
  lists `BeamMCP.*` modules among its deps, so a `BeamMCP.*` reference anywhere else is a
  compile error under `--warnings-as-errors`. Slice 060 puts the client driver here
  (`Trinity.MCP.Client`), 061 the server (`Trinity.MCP.Server`); at 059 the boundary holds the
  facts the FINDINGS table measured and nothing that serves.
  """
  # beam_mcp defines no boundaries and no `BeamMCP` root module, so each of its modules this
  # boundary reaches is named as its own implicit boundary (the boundary library's rule for
  # external apps); 060 and 061 extend the list as they reach more of the core.
  #
  # A top-level boundary (as `Trinity.Smoke` is), not a sub-boundary of `Trinity`: the
  # library lets a nested boundary depend on an external module only when an ancestor does,
  # and `Trinity` must never list `BeamMCP` (that would open the core to it).
  use Boundary, top_level?: true, deps: [Trinity, BeamMCP.JSON], exports: []

  @doc "The core's version, from its application spec."
  @spec core_version() :: String.t()
  def core_version, do: to_string(Application.spec(:beam_mcp, :vsn))

  @doc "The JSON nesting depth the core's decoder accepts: the first fact 060's driver builds on."
  @spec json_max_depth() :: pos_integer()
  def json_max_depth, do: BeamMCP.JSON.max_depth()

  @doc "The core's telemetry events (`[:beam_mcp, :dispatch, :start | :stop | :exception]`), for slice 090's catalogue."
  @spec core_events() :: [[atom()]]
  def core_events,
    do: [
      [:beam_mcp, :dispatch, :start],
      [:beam_mcp, :dispatch, :stop],
      [:beam_mcp, :dispatch, :exception]
    ]
end
