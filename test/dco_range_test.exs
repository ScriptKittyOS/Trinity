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
    git(dir, ["commit", "-q", "--allow-empty", "-m", "base\n\nSigned-off-by: Test <test@example.com>"])
    base = String.trim(elem(System.cmd("git", ["rev-parse", "HEAD"], cd: dir), 0))
    git(dir, ["commit", "-q", "--allow-empty", "-m", "signed\n\nSigned-off-by: Test <test@example.com>"])
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
end
