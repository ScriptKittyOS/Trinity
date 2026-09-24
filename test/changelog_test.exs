# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule ChangelogTest do
  @moduledoc """
  `CHANGELOG.md` says of itself that it "is derived from the tags themselves
  (`git tag -l 'slice/*'`), not written from memory". This test is what makes that sentence true.

  It was not true when the test was written. Two tags, `slice/002` and `slice/025`, had no entry:
  both were merged on a day when two other things were also merged, and both were simply missed.
  Nothing failed, because nothing was checking. A public record of delivered work that is quietly
  incomplete is worse than one that admits a gap, because a reader has no way to tell which kind
  they are holding.

  **Why the empty case is a failure rather than a skip.** A checkout without tags - `actions/checkout`
  at its default depth of one - can run this test and find nothing to check, and a test that passes
  because it had nothing to look at is indistinguishable from one that passed because the tree was
  right. Every CI leg that runs the suite therefore checks out with `fetch-depth: 0`, and this test
  refuses to pass without tags rather than quietly agreeing.

  The direction is deliberate: every tag must have an entry, and an entry with no tag is fine. A
  slice's entry is written in the pull request that closes it, which lands before the tag exists.
  """
  use ExUnit.Case, async: true

  @changelog "CHANGELOG.md"

  defp tags do
    {out, 0} = System.cmd("git", ["tag", "-l", "slice/*"])
    out |> String.split("\n", trim: true) |> Enum.sort()
  end

  test "the checkout has the tags this test reads" do
    assert tags() != [],
           "`git tag -l 'slice/*'` found nothing, so this test cannot check anything. A CI job " <>
             "running the suite must check out with `fetch-depth: 0`; a local clone has the tags " <>
             "already. Passing here without tags would be a pass that measured nothing"
  end

  test "every slice tag has an entry in the changelog" do
    text = File.read!(@changelog)

    missing = Enum.reject(tags(), &String.contains?(text, "`#{&1}`"))

    assert missing == [],
           "#{@changelog} has no entry for #{Enum.join(missing, ", ")}. The file states it is " <>
             "derived from the tags; add the entry rather than the exception"
  end
end
