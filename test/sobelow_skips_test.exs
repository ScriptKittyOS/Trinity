# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule SobelowSkipsTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Measured at slice 000: sobelow's skip file does NOT accept a trailing comment — appending one
  changes the line, the fingerprint stops matching and the finding reappears. So reasons live in
  `.sobelow-skips.reasons`, keyed by fingerprint, and this test makes a reasonless skip fail the
  gate.
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

  test "no skip entry carries an inline comment, because sobelow rejects them" do
    for line <- File.read!(@skips) |> String.split("\n", trim: true),
        not String.starts_with?(line, "#") do
      refute line =~ "#",
             "sobelow does not accept inline comments in #{@skips}; the fingerprint stops " <>
               "matching and the finding reappears. Put the reason in #{@reasons}."
    end
  end
end
