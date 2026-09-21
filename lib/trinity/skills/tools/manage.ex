# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Skills.Tools.Manage do
  @moduledoc """
  `skill_manage` (slice 041): the agent proposes a skill or a change to one. Every action is
  staged by `Trinity.Skills.Staging` (never applied), answers with the change id, the
  scanner's severity and where the owner decides (`/skills`), and then the persona's
  auto-approval is tried (`Trinity.Skills.Manager.auto/2`: off by default; `high` never).
  Risk `:write`, effect `:artifact`, as `fs_write` is: the call is receipted through the
  membrane, and under the default policy it asks; an "always allow" on it makes proposing
  free while the promotion stays gated, which is the point of staging.
  """
  @behaviour Trinity.Tools.Tool

  alias Trinity.Skills.{Manager, Staging}
  alias Trinity.Tools.{Context, Result}

  @impl true
  def name, do: "skill_manage"

  @impl true
  def description,
    do:
      "Proposes a new skill or a change to one. Nothing is applied: the proposal is staged with a diff and scanned, and the person approves it on the skills page. Actions: create (skill_md, optional files), patch (a unified diff of SKILL.md, or skill_md to replace it), write_file (path, content), remove_file (path), delete. Give a rationale."

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => ["create", "patch", "write_file", "remove_file", "delete"]
        },
        "name" => %{
          "type" => "string",
          "description" => "The skill's name: lowercase, digits, hyphens; the directory name"
        },
        "rationale" => %{
          "type" => "string",
          "description" => "Why this change, for the person deciding"
        },
        "skill_md" => %{
          "type" => "string",
          "description" => "create or patch: the whole SKILL.md (frontmatter and body)"
        },
        "diff" => %{"type" => "string", "description" => "patch: a unified diff of SKILL.md"},
        "files" => %{
          "type" => "object",
          "additionalProperties" => %{"type" => "string"},
          "description" => "create: relative path to content, for references/"
        },
        "path" => %{
          "type" => "string",
          "description" => "write_file or remove_file: a path relative to the skill"
        },
        "content" => %{"type" => "string", "description" => "write_file: the file's content"}
      },
      "required" => ["action", "name", "rationale"],
      "additionalProperties" => false
    }

  @impl true
  def risk, do: :write

  @impl true
  def effect, do: :artifact

  @impl true
  def execute(%{"action" => action, "name" => name} = args, %Context{
        session_id: sid,
        persona: persona
      }) do
    with {:ok, change} <-
           Staging.propose(action, name, args, rationale: args["rationale"], proposed_by: sid),
         {:ok, change} <- Manager.auto(change, persona) do
      {:ok,
       Result.text(answer(change), %{
         "change_id" => change.id,
         "severity" => change.severity,
         "status" => change.status
       })}
    end
  end

  defp answer(%{status: "applied"} = c),
    do:
      "Applied: #{c.action} of #{c.skill_name} was auto-approved (severity #{c.severity}); it is live at version #{c.applied_version || "none"}."

  defp answer(c),
    do:
      "Staged: #{c.action} of #{c.skill_name} (change #{c.id}, severity #{c.severity}#{if c.destructive, do: ", destructive", else: ""}). It is not applied: the person decides on the skills page. Do not retry."
end
