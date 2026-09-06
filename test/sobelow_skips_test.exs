# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule SobelowSkipsTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Measured at slice 000: sobelow's skip file does NOT accept a trailing comment — appending one
  changes the line, the fingerprint stops matching and the finding reappears. So reasons live in
  `.sobelow-skips.reasons`, keyed by fingerprint, and this test makes a reasonless skip fail the
  gate.

  Extended at slice 001 line 4. Sobelow has a **second** skip mechanism the tests above did not
  see: an `@sobelow_skip` module attribute in the source. A skip taken that way carried no
  reason and still passed the gate, which is the hole "a named exception with a reason is an
  enforcer" was written to close. Every `@sobelow_skip` in the tree must now be immediately
  preceded by a `# sobelow_skip reason:` comment, and the population is derived from
  `git ls-files`, not listed here.
  """

  @skips ".sobelow-skips"
  @reasons ".sobelow-skips.reasons"

  defp fingerprints do
    case File.read(@skips) do
      {:ok, body} ->
        body
        |> String.split("\n", trim: true)
        |> Enum.reject(&String.starts_with?(&1, "#"))
        |> Enum.map(&(&1 |> String.split(",") |> List.last() |> String.trim()))

      _ ->
        []
    end
  end

  defp reasoned do
    case File.read(@reasons) do
      {:ok, body} ->
        body
        |> String.split("\n", trim: true)
        |> Enum.reject(&String.starts_with?(&1, "#"))
        |> Enum.map(&(&1 |> String.split("\t") |> List.first() |> String.trim()))
        |> MapSet.new()

      _ ->
        MapSet.new()
    end
  end

  test "every skipped sobelow finding carries a reason" do
    missing = Enum.reject(fingerprints(), &MapSet.member?(reasoned(), &1))

    assert missing == [],
           "these sobelow skips have no reason in #{@reasons}: #{inspect(missing)}. " <>
             "A named exception with a reason is an enforcer; a bare skip is a weakening."
  end

  describe "inline @sobelow_skip attributes" do
    defp sources do
      {out, 0} = System.cmd("git", ["ls-files", "-z", "--", "*.ex", "*.exs"])
      String.split(out, <<0>>, trim: true)
    end

    defp inline_skips do
      for path <- sources(),
          {line, idx} <- File.read!(path) |> String.split("\n") |> Enum.with_index(),
          # An attribute DEFINITION, anchored at the start of the line. `String.contains?`
          # matched this file's own moduledoc and assertion strings on the first run — the
          # check was wrong about what a skip is, so the check is what changed.
          Regex.match?(~r/^\s*@sobelow_skip\s+\[/, line),
          do: {path, idx}
    end

    # The reason is the contiguous comment block directly above the attribute, not one line.
    # A one-line rule was the first version and it rejected a real, correctly written reason
    # for spanning six lines, so the rule was wrong rather than the reason.
    defp reason_above?(lines, idx) do
      idx
      |> then(&Enum.take(lines, &1))
      |> Enum.reverse()
      |> Enum.take_while(&String.starts_with?(String.trim_leading(&1), "#"))
      |> Enum.any?(&String.contains?(&1, "sobelow_skip reason:"))
    end

    test "every inline skip is preceded by its reason" do
      unreasoned =
        for {path, idx} <- inline_skips(),
            lines = File.read!(path) |> String.split("\n"),
            not reason_above?(lines, idx),
            do: "#{path}:#{idx + 1}"

      assert unreasoned == [],
             "these @sobelow_skip attributes carry no `# sobelow_skip reason:` line above " <>
               "them: #{inspect(unreasoned)}. A named exception with a reason is an " <>
               "enforcer; a bare skip is a weakening."
    end
  end

  test "no skip entry carries an inline comment, because sobelow rejects them" do
    for line <- File.read!(@skips) |> String.split("\n", trim: true),
        not String.starts_with?(line, "#") do
      refute line =~ "#",
             "sobelow does not accept inline comments in #{@skips}; the fingerprint stops " <>
               "matching and the finding reappears. Put the reason in #{@reasons}."
    end
  end
end
