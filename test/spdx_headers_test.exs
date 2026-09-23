# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule SpdxHeadersTest do
  @moduledoc """
  Every source file this project wrote carries a copyright line and a licence line.

  These are the OpenSSF Best Practices criteria `copyright_per_file` and `license_per_file`, both
  MUST at the gold level. They are held here rather than checked by hand for the reason every
  population rule in this tree is held by a test: the count only stays right if adding a file that
  breaks it fails something. When this test was written the tree was five files short of both
  criteria, and none of the five was noticed by anyone reading the tree.

  The population is `git ls-files`, so a new source file is in scope by existing. The comment
  syntax differs by language and the marker does not: SPDX defines the tag, not the comment it
  sits in, which is why this checks for the tag rather than for a particular line.
  """
  use ExUnit.Case, async: true

  @copyright "SPDX-FileCopyrightText"
  @license "SPDX-License-Identifier"

  # How many lines from the top the tags must appear within. HEEx templates and Rust files both
  # carry them first; an Elixir file may sit below a shebang or a moduledoc-free comment.
  @window 6

  defp sources do
    {out, 0} = System.cmd("git", ["ls-files", "*.ex", "*.exs", "*.heex", "*.rs"])
    String.split(out, "\n", trim: true)
  end

  defp head(file), do: file |> File.read!() |> String.split("\n") |> Enum.take(@window)

  test "the population is the tree's own source files, and it is not small" do
    files = sources()
    assert length(files) > 400, "expected the whole tree, got #{length(files)} files"
  end

  test "every source file carries a copyright statement" do
    missing = for f <- sources(), not Enum.any?(head(f), &String.contains?(&1, @copyright)), do: f

    assert missing == [],
           "these files carry no #{@copyright} line in their first #{@window} lines"
  end

  test "every source file carries a licence statement" do
    missing = for f <- sources(), not Enum.any?(head(f), &String.contains?(&1, @license)), do: f

    assert missing == [],
           "these files carry no #{@license} line in their first #{@window} lines"
  end

  test "the licence named in each file is the one the project is under" do
    for f <- sources(), line <- head(f), String.contains?(line, @license) do
      assert line =~ "Apache-2.0",
             "#{f} names a licence that is not the project's: #{String.trim(line)}"
    end
  end
end
