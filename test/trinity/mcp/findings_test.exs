# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.FindingsTest do
  @moduledoc """
  Slice 059, AC1 to AC3 over `FINDINGS.md`: fifteen rows, each with a path and line at the
  pinned beam_mcp commit and the command that derived it; the two conflicts named against
  the slice lines they collide with; the seam probe's diff size and the census test it
  touches, and no code from the probe in this tree.
  """
  use ExUnit.Case, async: true

  @findings "slices/059-mcp-library-spike/FINDINGS.md"

  defp rows do
    @findings
    |> File.read!()
    |> String.split("\n")
    |> Enum.filter(&Regex.match?(~r/^\| \d+ \| /, &1))
    |> Enum.map(fn line ->
      [n, item, status, what, derived] =
        line
        |> String.trim_leading("| ")
        |> String.trim_trailing(" |")
        |> String.split(" | ", parts: 5)

      %{n: String.to_integer(n), item: item, status: status, what: what, derived: derived}
    end)
  end

  test "AC1: fifteen rows, numbered 1 to 15, each naming the pinned commit's paths with a line and a deriving command" do
    rows = rows()
    assert Enum.map(rows, & &1.n) == Enum.to_list(1..15)
    assert File.read!(@findings) =~ "`cfa706b`"

    for r <- rows do
      assert Regex.match?(
               ~r/`(lib|docs|test|README)[\w\/.-]*(\.ex|\.exs|\.md|\.txt)?:\d+/,
               r.what
             ) or
               Regex.match?(~r/`(lib|docs|test)[\w\/.-]*\.(ex|exs|md|txt)`/, r.what),
             "row #{r.n} names no path"

      assert Regex.match?(~r/`(grep|sed|find|git|curl)\b/, r.derived),
             "row #{r.n} names no deriving command"

      assert Regex.match?(~r/\*\*(ships|carries|refuses|open)\*\*/, r.status),
             "row #{r.n} has no status"
    end
  end

  test "AC2: the two conflicts are stated against the slice lines" do
    text = File.read!(@findings)
    [_, conflicts] = String.split(text, "## The two conflicts")
    assert conflicts =~ "entry 12" and conflicts =~ "061" and conflicts =~ "input_required"

    assert conflicts =~ "Entries 9" and conflicts =~ "8" and conflicts =~ "060" and
             conflicts =~ "062"
  end

  test "AC3: the probe reports its diff size and the one census test it touches, and none of it is here" do
    text = File.read!(@findings)
    [_, probe] = String.split(text, "## The seam probe")
    assert probe =~ "1 file changed, 3 insertions(+), 2 deletions(-)"
    assert probe =~ "test/beam_mcp/boundary/no_catalog_test.exs:102"
    assert probe =~ "180 tests, 1 failure" and probe =~ "705 tests, 1 failure"
    assert probe =~ "Deleted branch probe/server-option"
    # No beam_mcp source in this tree: the dependency is fetched, never vendored or patched.
    refute File.exists?("lib/beam_mcp")
    refute File.read!("mix.exs") =~ ~r/beam_mcp.*(path:|git:)/
  end
end
