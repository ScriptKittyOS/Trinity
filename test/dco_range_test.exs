# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule DcoRangeTest do
  @moduledoc """
  Slice 128: the workflow's range check says "every commit" and checks "at least one".

  `.github/workflows/gate.yml` carries a step named **DCO sign-off present on every commit** whose
  body concatenates every message in the range and greps for one `Signed-off-by:` anywhere:

      git log --format=%B BASE..HEAD | grep -q '^Signed-off-by: '

  A range of five commits where one is signed passes it. `test/dco_test.exs` does check every
  non-merge commit, over the whole history, on every leg, so the practical exposure is small. The
  defect is that a step's name is a claim, and this one is false: a reader of the workflow, or of a
  donation review, is told something the file does not do.

  This test is about the logic rather than about the workflow's YAML, so it runs the same shape
  against a range it builds itself.
  """
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  # The shape the workflow uses today, extracted so it can be run against a known range.
  defp concatenated_grep(dir, range) do
    {out, _} = System.cmd("git", ["log", "--format=%B", range], cd: dir)
    if String.match?(out, ~r/^Signed-off-by: /m), do: :pass, else: :fail
  end

  # What the name promises: every commit in the range, individually.
  defp every_commit(dir, range) do
    {out, 0} =
      System.cmd(
        "git",
        ["log", "--no-merges", "--format=%H%x09%(trailers:key=Signed-off-by,valueonly)", range],
        cd: dir
      )

    unsigned =
      out
      |> String.split("\n", trim: true)
      |> Enum.filter(fn line ->
        case String.split(line, "\t") do
          [_sha, trailer] -> String.trim(trailer) == ""
          [_sha] -> true
          _ -> false
        end
      end)

    if unsigned == [], do: :pass, else: :fail
  end

  defp git(dir, args), do: {_, 0} = System.cmd("git", args, cd: dir)

  defp repo_with_one_signed_one_not(dir) do
    git(dir, ["init", "-q"])
    git(dir, ["config", "user.name", "Test"])
    git(dir, ["config", "user.email", "test@example.com"])
    # This machine signs commits globally; a scratch repository has no key and would fail at 128.
    git(dir, ["config", "commit.gpgsign", "false"])

    git(dir, [
      "commit",
      "-q",
      "--allow-empty",
      "-m",
      "base\n\nSigned-off-by: Test <test@example.com>"
    ])

    base = String.trim(elem(System.cmd("git", ["rev-parse", "HEAD"], cd: dir), 0))

    git(dir, [
      "commit",
      "-q",
      "--allow-empty",
      "-m",
      "signed\n\nSigned-off-by: Test <test@example.com>"
    ])

    git(dir, ["commit", "-q", "--allow-empty", "-m", "unsigned, no trailer at all"])
    base
  end

  test "AC1: the step's current logic accepts a range containing an unsigned commit", %{
    tmp_dir: dir
  } do
    base = repo_with_one_signed_one_not(dir)

    assert concatenated_grep(dir, "#{base}..HEAD") == :pass,
           "the concatenating grep rejected this range, so the premise of this slice is wrong"

    assert every_commit(dir, "#{base}..HEAD") == :fail,
           "a per-commit check should reject a range with an unsigned commit"
  end

  test "AC2: the workflow step now checks every commit, and both copies agree" do
    yaml = File.read!(".github/workflows/gate.yml")

    steps =
      yaml
      |> String.split("\n")
      |> Enum.chunk_every(12, 1, :discard)
      |> Enum.filter(fn chunk -> String.contains?(hd(chunk), "DCO sign-off") end)

    assert length(steps) == 2,
           "expected the DCO step in two legs, found #{length(steps)}"

    for chunk <- steps do
      body = Enum.join(chunk, "\n")

      refute body =~ "grep -q '^Signed-off-by: '",
             """
             the step still concatenates the range and greps for one sign-off anywhere, which is \
             not what its name says:

             #{body}
             """
    end
  end

  describe "AC5: a pull request description is checked too" do
    test "the workflow carries the step, in both legs, and passes the body through env" do
      yaml = File.read!(".github/workflows/gate.yml")

      assert length(
               String.split(yaml, "No assistant attribution in the pull request description")
             ) - 1 == 2,
             "the PR-description check is not present in both legs"

      assert yaml =~ "PR_BODY: ${{ github.event.pull_request.body }}",
             "the body is not passed through env, which means it is interpolated into a shell " <>
               "command; a pull request description is attacker-controlled text"

      refute yaml =~ ~r/grep -qiE '[^']*'\s*<<<\s*"\$\{\{/,
             "the body is interpolated directly into the script"
    end

    test "the pattern it uses catches the shapes that were found in the wild" do
      # The seven descriptions on #99 to #105 carried the first of these. The others are the
      # trailers the commit hook already strips, included so one check knows every shape.
      pattern = ~r/Co-Authored-By: Claude|Claude-Session:|Generated with \[Claude/i

      for body <- [
            "some text\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)\n",
            "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>",
            "Claude-Session: abc123",
            "GENERATED WITH [CLAUDE CODE]"
          ] do
        assert Regex.match?(pattern, body), "the pattern misses: #{inspect(body)}"
      end

      for body <- [
            "a normal description mentioning claude in prose",
            "Signed-off-by: Ayla Croft <aylacroft@proton.me>",
            "This slice was generated from a template"
          ] do
        refute Regex.match?(pattern, body), "the pattern over-matches: #{inspect(body)}"
      end
    end
  end
end
