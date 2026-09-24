# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule DcoTest do
  @moduledoc """
  Slice 120 AC4: every commit in the whole history carries a Developer Certificate of Origin
  sign-off (ADR-0012).

  A hook checks the commit being written and the CI workflow checks the range a pull request
  proposes. Neither looks backwards, so neither can answer the question a donation review asks,
  which is about the repository rather than about a change: *is every commit signed off?* The
  answer has to be derived from the whole history, and it is derived here rather than asserted in
  a document.

  `git log --all` and not `HEAD`: a signed-off history with an unsigned commit on a branch is not
  a signed-off repository, and the branch is what someone would find.

  **Merge commits are excluded, and the reason is what the certificate is for.** A sign-off certifies
  that the person had the right to submit the *work*. A merge commit produced by the forge's merge
  button introduces no work: it has two parents, both of them already signed off, and it is authored
  by whoever pressed the button rather than by anyone who wrote anything. The standard DCO tooling
  skips merges for this reason, and measuring it here showed why: every unsigned commit in this
  repository is one, six of them made by GitHub itself when a pull request was merged. Requiring a
  sign-off on them would mean either abandoning the merge button or signing a certificate about
  work nobody did.

  **This test needs the full history.** A shallow checkout cannot answer the question, so it fails
  rather than passing over three commits. Every CI leg that runs the suite checks out with
  `fetch-depth: 0`.
  """
  use ExUnit.Case, async: true

  # `--no-merges` for the reason in the moduledoc. Everything else in the history is a commit that
  # carried work, and every one of those must be signed off.
  @log ["log", "--all", "--no-merges"]

  defp commits do
    {out, 0} = System.cmd("git", @log ++ ["--format=%H"])
    String.split(out, "\n", trim: true)
  end

  test "the checkout has enough history for this to mean anything" do
    assert length(commits()) > 50,
           "only #{length(commits())} commits are reachable, which is a shallow clone. This test " <>
             "cannot answer a question about the repository from a slice of it; check out with " <>
             "fetch-depth: 0"
  end

  test "every commit in the history carries a Signed-off-by line" do
    {out, 0} =
      System.cmd("git", @log ++ ["--format=%H%x09%(trailers:key=Signed-off-by,valueonly)"])

    unsigned =
      out
      |> String.split("\n", trim: true)
      |> Enum.map(&String.split(&1, "\t"))
      |> Enum.filter(fn
        [_sha, trailer] -> String.trim(trailer) == ""
        [_sha] -> true
        _ -> false
      end)
      |> Enum.map(&hd/1)

    assert unsigned == [],
           "#{length(unsigned)} non-merge commit(s) carry no Signed-off-by: " <>
             Enum.join(Enum.take(unsigned, 5), ", ")
  end
end
