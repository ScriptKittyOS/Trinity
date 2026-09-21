# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Skills.Tools.View do
  @moduledoc """
  `skill_view` (slice 040): the body of one skill, its reference and script listings after
  it. A read, receipted; the body is the skill author's text and comes back wrapped as
  untrusted with the skill's digest as the source reference (docs/07: a skill is trusted to
  the degree its source is; a hub skill is not a core rule).
  """
  @behaviour Trinity.Tools.Tool

  alias Trinity.Tools.{Context, Untrusted}

  @impl true
  def name, do: "skill_view"

  @impl true
  def description,
    do:
      "Reads a skill's instructions by name (from `skills_list`). Returns the SKILL.md body and the names of its reference files, which `skill_file` can read."

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{"name" => %{"type" => "string", "description" => "The skill's name"}},
      "required" => ["name"],
      "additionalProperties" => false
    }

  @impl true
  def risk, do: :read

  @impl true
  def effect, do: :none

  @impl true
  def execute(%{"name" => name}, %Context{cwd: cwd}) do
    case Enum.find(Trinity.Skills.active(project_root: cwd), &(&1.name == name)) do
      nil ->
        {:error, {:no_such_skill, name}}

      skill ->
        listing =
          case skill.references ++ skill.scripts do
            [] -> ""
            files -> "\n\n## Files\n" <> Enum.map_join(files, "\n", &("- " <> &1))
          end

        text = "# #{skill.name} (#{skill.source})\n\n" <> skill.body <> listing

        meta = %{
          "name" => skill.name,
          "source" => skill.source,
          "body_hash" => skill.body_hash,
          "version" => skill.version
        }

        {:ok,
         Untrusted.result(text,
           tool: name(),
           source_ref: "skill:#{skill.name}@#{skill.body_hash}",
           meta: meta
         )}
    end
  end
end
