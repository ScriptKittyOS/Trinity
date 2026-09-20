# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Sessions.Sentinel do
  @moduledoc """
  A preflight over model output that can only tighten. Slice 012. Three families of finding,
  each a fixed pattern set stated here as a tripwire and not a classifier: a claim that
  something was already executed (the model asserting an effect it did not have); phrasing
  that asks to bypass a gate, a permission or prior instructions; and loop abuse, the same tool
  call repeated within one turn. A finding is recorded on the assistant message and marks the
  turn's outcome `hold`; nothing here ever removes a finding or loosens an outcome.
  """

  @type finding :: %{kind: :already_executed | :boundary_bypass | :loop_abuse, match: String.t()}

  @already_executed [
    ~r/\bI (have|'ve) (already |just )?(executed|run|deleted|sent|installed|removed|written)\b/i,
    ~r/\b(done|completed)[:,]? I (deleted|removed|sent|executed)\b/i
  ]

  @boundary_bypass [
    ~r/\bignore (the |all |any )?(previous|prior|above|system) (instructions|rules|prompt)\b/i,
    ~r/\b(bypass|skip|disable) (the )?(gate|permission|permissions|approval|approvals|sandbox)\b/i,
    ~r/\bwithout (asking|approval|permission)\b/i
  ]

  @doc "Findings over a completed assistant text."
  @spec preflight(String.t()) :: [finding()]
  def preflight(text) when is_binary(text) do
    scan(text, :already_executed, @already_executed) ++
      scan(text, :boundary_bypass, @boundary_bypass)
  end

  @doc "A loop-abuse finding when the same tool call (name and args) appears three or more times."
  @spec loop_abuse([%{name: String.t(), args: map()}]) :: [finding()]
  def loop_abuse(calls) do
    calls
    |> Enum.frequencies_by(&{&1.name, &1.args})
    |> Enum.filter(fn {_, n} -> n >= 3 end)
    |> Enum.map(fn {{name, _}, n} -> %{kind: :loop_abuse, match: "#{name} x#{n}"} end)
  end

  @doc "Merges new findings into existing ones. Findings are never removed."
  @spec merge([finding()], [finding()]) :: [finding()]
  def merge(existing, new), do: Enum.uniq(existing ++ new)

  @doc "The outcome findings impose: `:hold` when there are any, `:ok` when there are none."
  @spec outcome([finding()]) :: :ok | :hold
  def outcome([]), do: :ok
  def outcome(_), do: :hold

  defp scan(text, kind, patterns) do
    Enum.flat_map(patterns, fn re ->
      case Regex.run(re, text) do
        [match | _] -> [%{kind: kind, match: match}]
        nil -> []
      end
    end)
  end
end
