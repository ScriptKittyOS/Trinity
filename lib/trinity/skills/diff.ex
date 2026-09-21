# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Skills.Diff do
  @moduledoc """
  A unified diff of two texts (slice 041), line based, from a longest-common-subsequence over
  the lines: enough for a SKILL.md and its references, which is all a change carries. A file
  that is not text (not valid UTF-8, or over the size limit) is not diffed: the caller says
  "replaced, N bytes" instead (SLICE.md's risk line).
  """

  @max_bytes 262_144

  @doc "The size over which a file is described, not diffed."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc "True when both sides can be diffed as text."
  @spec text?(binary()) :: boolean()
  def text?(bin), do: is_binary(bin) and byte_size(bin) <= @max_bytes and String.valid?(bin)

  @doc "A unified diff with the two paths in its header; `\"\"` when the texts are equal."
  @spec unified(String.t(), String.t(), String.t(), String.t()) :: String.t()
  def unified(a, b, path_a \\ "a", path_b \\ "b")
  def unified(same, same, _pa, _pb), do: ""

  def unified(a, b, path_a, path_b) do
    la = String.split(a, "\n")
    lb = String.split(b, "\n")

    body =
      la
      |> lcs_diff(lb)
      |> Enum.map_join("\n", fn
        {:eq, l} -> " " <> l
        {:del, l} -> "-" <> l
        {:add, l} -> "+" <> l
      end)

    "--- #{path_a}\n+++ #{path_b}\n@@ -1,#{length(la)} +1,#{length(lb)} @@\n" <> body
  end

  @doc "The edit script: `{:eq | :del | :add, line}` in order."
  @spec lcs_diff([String.t()], [String.t()]) :: [{:eq | :del | :add, String.t()}]
  def lcs_diff(a, b) do
    ta = List.to_tuple(a)
    tb = List.to_tuple(b)
    n = tuple_size(ta)
    m = tuple_size(tb)
    # lengths[i][j] = LCS length of a[i..] and b[j..], filled from the end.
    table =
      for i <- (n - 1)..0//-1, j <- (m - 1)..0//-1, reduce: %{} do
        acc -> Map.put(acc, {i, j}, lcs_at(ta, tb, i, j, acc))
      end

    walk(ta, tb, 0, 0, n, m, table, [])
  end

  defp lcs_at(ta, tb, i, j, acc) do
    if elem(ta, i) == elem(tb, j),
      do: 1 + Map.get(acc, {i + 1, j + 1}, 0),
      else: max(Map.get(acc, {i + 1, j}, 0), Map.get(acc, {i, j + 1}, 0))
  end

  defp walk(ta, tb, i, j, n, m, table, acc) do
    cond do
      i < n and j < m and elem(ta, i) == elem(tb, j) ->
        walk(ta, tb, i + 1, j + 1, n, m, table, [{:eq, elem(ta, i)} | acc])

      i < n and (j >= m or Map.get(table, {i + 1, j}, 0) >= Map.get(table, {i, j + 1}, 0)) ->
        walk(ta, tb, i + 1, j, n, m, table, [{:del, elem(ta, i)} | acc])

      j < m ->
        walk(ta, tb, i, j + 1, n, m, table, [{:add, elem(tb, j)} | acc])

      true ->
        Enum.reverse(acc)
    end
  end
end
