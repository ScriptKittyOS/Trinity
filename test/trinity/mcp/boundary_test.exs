# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.BoundaryTest do
  @moduledoc """
  Slice 059 AC4: `beam_mcp` is in the lock, its VERSIONS row reads in mix.lock, the boundary
  compiler checks calls into it everywhere and only `Trinity.MCP` may make them. The
  compile-time refusal of a planted `BeamMCP` reference outside `Trinity.MCP` is pasted in
  PROOF.md from the command (a test cannot run the project's own compiler over a planted file
  without changing the tree it runs in); what this test holds is the configuration that makes
  the refusal, and the source census: no `BeamMCP` reference under `lib/` outside
  `lib/trinity/mcp.ex` and `lib/trinity/mcp/`.
  """
  use ExUnit.Case, async: true

  # Slice 061 bumped the pin to 0.9.0 (the :server seam); the row and the lock moved together.
  test "beam_mcp is in mix.lock at 0.9.0 and the VERSIONS row reads in mix.lock" do
    lock = Mix.Dep.Lock.read()
    assert {:hex, :beam_mcp, "0.9.0", _, _, _, _, _} = lock[:beam_mcp]
    assert File.read!("VERSIONS.md") =~ ~r/`beam_mcp` \| ~> 0\.9 \| ✅ in `mix\.lock`/
    assert Trinity.MCP.core_version() == "0.9.0"
  end

  test "the boundary compiler checks calls into beam_mcp everywhere, and Trinity.MCP is the boundary that lists it" do
    assert get_in(Mix.Project.config(), [:boundary, :default, :check, :apps]) == [:beam_mcp]
    assert Trinity.MCP.json_max_depth() > 0

    {out, 0} = System.cmd("git", ["ls-files", "lib/*.ex"])
    files = String.split(out, "\n", trim: true)
    assert length(files) > 100

    referrers = for f <- files, File.read!(f) =~ ~r/\bBeamMCP\./, do: f
    # Slice 060: the wire builder is the second referrer, under the same boundary; nothing
    # outside `lib/trinity/mcp.ex` and `lib/trinity/mcp/` names the core.
    assert Enum.sort(referrers) == ["lib/trinity/mcp.ex", "lib/trinity/mcp/client/wire.ex"]

    for f <- referrers,
        do: assert(f == "lib/trinity/mcp.ex" or String.starts_with?(f, "lib/trinity/mcp/"))
  end

  test "the planted reference is a real reference: the file the proof compiles names BeamMCP outside Trinity.MCP" do
    plant = File.read!("test/support/mcp/planted_reference.ex.txt")
    assert plant =~ "defmodule Trinity.PlantedBeamMcp"
    assert plant =~ "BeamMCP.JSON.max_depth()"
  end
end
