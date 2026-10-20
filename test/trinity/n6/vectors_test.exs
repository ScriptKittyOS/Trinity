# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.N6.VectorsTest do
  @moduledoc """
  Slice 138: the checked-in vector set is exactly what `scripts/n6_vectors.exs` writes, and its
  `SHA384SUMS` lists every file, so the set a reader is offered is the set the suite tests.
  """

  use ExUnit.Case, async: true

  alias Trinity.TestSupport.N6Vectors

  test "SHA384SUMS lists every file of the set, with its digest" do
    root = N6Vectors.root()

    listed =
      Path.join(root, "SHA384SUMS")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Map.new(fn line ->
        [hex, path] = String.split(line, "  ", parts: 2)
        {path, hex}
      end)

    files =
      Path.join(root, "**")
      |> Path.wildcard(match_dot: true)
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.relative_to(&1, root))
      |> Enum.reject(&(&1 == "SHA384SUMS"))

    assert Enum.sort(Map.keys(listed)) == Enum.sort(files)

    for path <- files do
      digest =
        :crypto.hash(:sha384, File.read!(Path.join(root, path))) |> Base.encode16(case: :lower)

      assert listed[path] == digest, path
    end
  end

  @tag :tmp_dir
  test "the generator writes the checked-in set byte for byte", %{tmp_dir: tmp} do
    out = Path.join(tmp, "n6")

    {output, status} =
      System.cmd("elixir", ["scripts/n6_vectors.exs", out], stderr_to_stdout: true)

    assert status == 0, output

    assert File.read!(Path.join(out, "SHA384SUMS")) ==
             File.read!(Path.join(N6Vectors.root(), "SHA384SUMS"))
  end
end
