# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Tools.FS.Placeholders do
  @moduledoc """
  The write-validation hook (docs/07): a write whose content carries a truncation marker is
  the placeholder-overwrite class of data loss, and it is refused unless the caller says
  `allow_placeholders: true`, which the tool escalates to `:destructive`. Slice 022.
  """

  @patterns [
    ~r{/\*\s*\.\.\.\s*\*/},
    ~r{//\s*\.\.\.(\s|$)},
    ~r{//\s*\.\.\.\s*rest},
    ~r{#\s*\.\.\.\s*(rest|unchanged|remaining)},
    ~r{<!--\s*\.\.\.\s*-->},
    ~r{^\s*\.\.\.\s*$}m,
    ~r{\[\s*\.\.\.\s*\]},
    ~r{(rest|remainder) of (the )?(file|code|content) (unchanged|omitted|remains|as before)}i,
    ~r{existing code (here|unchanged|remains)}i,
    ~r{\(unchanged\)}i
  ]

  @doc "The lines (1-based) that carry a truncation marker; empty for a complete file."
  @spec find(String.t()) :: [{pos_integer(), String.t()}]
  def find(content) when is_binary(content) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _} -> Enum.any?(@patterns, &Regex.match?(&1, line)) end)
    |> Enum.map(fn {line, n} -> {n, String.trim(line)} end)
  end
end
