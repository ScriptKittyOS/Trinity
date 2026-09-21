# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Skills.Tools.List do
  @moduledoc """
  `skills_list` (slice 040): the index of the skills the model may use now, one line each,
  grouped by category, capped in tokens (`config :trinity, :skills, index_tokens:`, the
  same cap the prompt's index has; the tool takes `limit_tokens` up to four times that). A
  read: risk `:read`, effect `:none`, so it runs without asking and leaves a query receipt.
  The names and descriptions are skill authors' text and come back wrapped as untrusted.
  """
  @behaviour Trinity.Tools.Tool

  alias Trinity.Skills.Index
  alias Trinity.Tools.{Context, Untrusted}

  @impl true
  def name, do: "skills_list"

  @impl true
  def description,
    do:
      "Lists the skills available now: procedures for kinds of task, one line each with the name and what it is for, grouped by category. Call `skill_view` with a name to read one before doing a task it covers."

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "category" => %{"type" => "string", "description" => "Only this category"},
        "limit_tokens" => %{
          "type" => "integer",
          "minimum" => 50,
          "maximum" => 4 * Index.default_tokens(),
          "description" =>
            "Cut the list at about this many tokens (default #{Index.default_tokens()})"
        }
      },
      "additionalProperties" => false
    }

  @impl true
  def risk, do: :read

  @impl true
  def effect, do: :none

  @impl true
  def execute(args, %Context{cwd: cwd}) do
    skills = Trinity.Skills.active(project_root: cwd)

    skills =
      case args["category"] do
        c when is_binary(c) and c != "" ->
          Enum.filter(skills, &(&1.category == String.downcase(c)))

        _ ->
          skills
      end

    cap = args["limit_tokens"] || Index.default_tokens()

    text =
      if skills == [],
        do: "No skills are available.",
        else: Index.render(skills, cap, hint: false)

    meta = %{"skills" => length(skills), "limit_tokens" => cap}
    {:ok, Untrusted.result(text, tool: name(), source_ref: "skills:list", meta: meta)}
  end
end
