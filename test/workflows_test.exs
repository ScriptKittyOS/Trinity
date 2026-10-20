# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule WorkflowsTest do
  @moduledoc """
  The continuous integration definitions are code, and they are checked like code.

  Four properties. Every workflow and the Dependabot configuration parse as YAML, so a malformed
  one fails here rather than silently not running: GitHub reports a broken workflow file on its
  own page and not on the pull request, which is the wrong place for it to be discovered. Every
  third-party action is pinned to a full commit hash rather than a tag, because a tag can be moved
  to point at different code after review; this is the OpenSSF Scorecard `Pinned-Dependencies`
  check, held here rather than waited for. And every workflow declares a top-level `permissions:`
  block granting no more than read, so that a job wanting to write has to say so itself: Scorecard's
  `Token-Permissions` check, which this repository scored **zero** on until 2026-09-23 because two
  workflows declared nothing at all and ran with whatever the repository default happened to be.
  And no step pipes the test suite or the gate into another command without `pipefail`, because the
  runner's default shell takes the last command's exit, so a red suite piped into `grep` passes.

  The third property is the one worth a sentence about why a test rather than a habit. A top-level
  write is granted to every job the workflow will ever have, including the ones nobody has written
  yet, and the cost of forgetting is invisible: nothing fails, the token is simply broader than the
  work needs. That is exactly the class of thing a build should hold rather than a reviewer.

  The population comes from the tree (`git ls-files .github`), so a workflow added without a
  thought for any of the three is caught by its own existence.
  """
  use ExUnit.Case, async: true

  @action_ref ~r{uses:\s*([A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+)@(\S+)}

  # Anything that is not one of these is a write, whatever it is called.
  @read_only ~w(read none)

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

  test "every workflow declares a top-level permissions block, and it grants no write" do
    for file <- yaml_files(), String.contains?(file, "/workflows/") do
      permissions = file |> read_yaml() |> Map.get("permissions")

      assert permissions != nil,
             "#{file} declares no top-level permissions, so its token is whatever the " <>
               "repository default happens to be. Declare `permissions: {contents: read}` and " <>
               "let any job that needs to write say so itself"

      for {scope, level} <- top_level_scopes(permissions) do
        assert level in @read_only,
               "#{file} grants `#{scope}: #{level}` at the top level, which grants it to every " <>
                 "job the workflow will ever have. Move it to the job that needs it"
      end
    end
  end

  # Added after slice 138 (its NOTES, follow-up): the fips job's coverage step ran
  # `mix test --cover | grep ...` under the runner's default `bash -e {0}`, which has no pipefail,
  # so the step's exit was grep's. On job 118381934625 the suite inside it was 1388/1389 and the
  # step and the job passed, with the failing test's name filtered out of the log. A step that runs
  # the suite or the gate must fail when they do.
  test "no step pipes the test suite or the gate into another command without pipefail" do
    offenders =
      for file <- yaml_files(),
          String.contains?(file, "/workflows/"),
          workflow = read_yaml(file),
          {job_id, job} <- Map.get(workflow, "jobs", %{}),
          {step, index} <- Enum.with_index(Map.get(job, "steps", [])),
          run = Map.get(step, "run"),
          is_binary(run),
          pipes_suite?(run),
          not pipefail?(step, job, workflow, run) do
        "#{file}: job #{job_id}, step #{Map.get(step, "name", "##{index}")}"
      end

    assert offenders == [],
           "these steps pipe `mix test` or `mix gate` into another command, so the step exits " <>
             "with that command's status and a red suite passes. Run them unpiped, or give the " <>
             "step `shell: bash` (which adds -o pipefail):\n" <> Enum.join(offenders, "\n")
  end

  # A line that runs `mix test` or `mix gate` and has a single `|` after it (not `||`).
  defp pipes_suite?(run) do
    run
    |> String.split("\n")
    |> Enum.any?(&Regex.match?(~r/\bmix\s+(test|gate)\b[^|]*\|(?!\|)/, &1))
  end

  defp pipefail?(step, job, workflow, run) do
    shell =
      Map.get(step, "shell") || get_in(job, ["defaults", "run", "shell"]) ||
        get_in(workflow, ["defaults", "run", "shell"])

    shell == "bash" or String.contains?(run, "set -o pipefail") or
      String.contains?(run, "set -eo pipefail")
  end

  # `permissions:` is either a map of scopes, or one of the shorthands `read-all`/`write-all`.
  defp top_level_scopes("read-all"), do: []
  defp top_level_scopes("write-all"), do: [{"(every scope)", "write"}]
  defp top_level_scopes(map) when is_map(map), do: map
  defp top_level_scopes(other), do: [{"(unrecognised)", inspect(other)}]

  defp read_yaml(file) do
    {json, 0} =
      System.cmd("python3", [
        "-c",
        "import sys,yaml,json; json.dump(yaml.safe_load(open(sys.argv[1])), sys.stdout)",
        file
      ])

    Jason.decode!(json)
  end
end
