# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule WorkflowsTest do
  @moduledoc """
  The continuous integration definitions are code, and they are checked like code.

  Two properties. Every workflow and the Dependabot configuration parse as YAML, so a malformed
  one fails here rather than silently not running: GitHub reports a broken workflow file on its
  own page and not on the pull request, which is the wrong place for it to be discovered. And
  every third-party action is pinned to a full commit hash rather than a tag, because a tag can
  be moved to point at different code after review; this is the OpenSSF Scorecard
  `Pinned-Dependencies` check, held here rather than waited for.

  The population comes from the tree (`git ls-files .github`), so a workflow added without a
  thought for either property is caught by its own existence.
  """
  use ExUnit.Case, async: true

  @action_ref ~r{uses:\s*([A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+)@(\S+)}

  defp yaml_files do
    {out, 0} = System.cmd("git", ["ls-files", ".github"])

    out
    |> String.split("\n", trim: true)
    |> Enum.filter(&(String.ends_with?(&1, ".yml") or String.ends_with?(&1, ".yaml")))
  end

  test "the population is not empty and holds the workflows this project runs" do
    files = yaml_files()
    assert length(files) >= 4

    for expected <- ~w(gate.yml package.yml fips-image.yml scorecard.yml) do
      assert Enum.any?(files, &String.ends_with?(&1, expected)), "#{expected} is missing"
    end
  end

  test "every workflow and the Dependabot configuration parse as YAML" do
    for file <- yaml_files() do
      {out, status} =
        System.cmd("python3", ["-c", "import sys,yaml; yaml.safe_load(open(sys.argv[1]))", file],
          stderr_to_stdout: true
        )

      assert status == 0, "#{file} does not parse as YAML:\n#{out}"
    end
  end

  test "every third-party action is pinned to a full commit hash, not a movable tag" do
    for file <- yaml_files(),
        [_, action, ref] <- Regex.scan(@action_ref, File.read!(file)) do
      assert ref =~ ~r/^[0-9a-f]{40}$/,
             "#{file} uses #{action}@#{ref}: pin the action to a full commit hash, because a " <>
               "tag can be moved to point at different code after it was reviewed"
    end
  end
end
