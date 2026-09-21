# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Skills.Index do
  @moduledoc """
  The skills index as text (slice 040): the names and one-line descriptions grouped by
  category, under a token cap. The prompt's copy (`Trinity.Context.SkillsIndex`) uses the
  cap `config :trinity, :skills, index_tokens:` (338: the reserve slice 033 left in the
  context tier beside the AGENTS.md cap); over it, the index falls back to the category
  names with their counts and a hint to call `skills_list`, so the tier never spends what
  AGENTS.md needs. The estimator is 023's (`Trinity.Memory.Tokens`, bytes over three).
  """

  alias Trinity.Memory.Tokens
  alias Trinity.Skills.Skill

  @default_tokens 338
  @heading "## Skills"
  @hint "The list was cut at its budget: call `skills_list` for the rest, and `skill_view` with a name to read one."

  @doc "The prompt's cap in tokens."
  @spec default_tokens() :: pos_integer()
  def default_tokens,
    do: Application.get_env(:trinity, :skills, []) |> Keyword.get(:index_tokens, @default_tokens)

  @doc """
  The index for these skills under `cap` tokens. `hint: true` (the default) appends the hint
  when the list was cut; the full list when it fits, else as many whole lines as fit, else
  the categories alone.
  """
  @spec render([Skill.t()], pos_integer(), keyword()) :: String.t()
  def render(skills, cap, opts \\ [])
  def render([], _cap, _opts), do: ""
  # A cap of 0 is the index switched off (a test that measures the prompt's size sets it).
  def render(_skills, 0, _opts), do: ""

  def render(skills, cap, opts) do
    hint? = Keyword.get(opts, :hint, true)
    full = @heading <> "\n" <> lines(skills)

    if Tokens.estimate(full) <= cap do
      full
    else
      cut = cut_lines(full, cap - if(hint?, do: Tokens.estimate(@hint) + 1, else: 0))
      text = if cut == @heading, do: @heading <> "\n" <> categories(skills), else: cut
      if hint?, do: text <> "\n" <> @hint, else: text
    end
  end

  @doc "The lines: a category heading then `- name: description` per skill, alphabetical within."
  @spec lines([Skill.t()]) :: String.t()
  def lines(skills) do
    skills
    |> Enum.group_by(& &1.category)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join("\n", fn {cat, list} ->
      "#{cat}:\n" <>
        Enum.map_join(Enum.sort_by(list, & &1.name), "\n", &"- #{&1.name}: #{Skill.one_line(&1)}")
    end)
  end

  @doc "The category names with their counts, one line."
  @spec categories([Skill.t()]) :: String.t()
  def categories(skills) do
    skills
    |> Enum.group_by(& &1.category)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join(", ", fn {cat, list} -> "#{cat} (#{length(list)})" end)
    |> then(&("categories: " <> &1))
  end

  defp cut_lines(text, budget) do
    max_bytes = max(budget, 0) * 3

    text
    |> String.split("\n")
    |> Enum.reduce_while({[], 0}, fn line, {acc, size} ->
      next = size + byte_size(line) + 1

      if next > max_bytes and acc != [],
        do: {:halt, {acc, size}},
        else: {:cont, {[line | acc], next}}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join("\n")
  end
end
