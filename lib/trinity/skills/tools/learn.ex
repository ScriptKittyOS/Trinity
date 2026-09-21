# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Skills.Tools.Learn do
  @moduledoc """
  `learn` (slice 041): a document (a file under the session's roots, a URL, or text) into a
  staged knowledge skill through `Trinity.Skills.Learn`, with the session's own model. Risk
  `:write`, effect `:artifact` like `skill_manage`; the staged change is decided on `/skills`.
  """
  @behaviour Trinity.Tools.Tool

  alias Trinity.Skills.{Learn, Manager}
  alias Trinity.Tools.{Context, Result}

  @impl true
  def name, do: "learn"

  @impl true
  def description,
    do:
      "Distils a document into a knowledge skill (a SKILL.md and a reference file) and stages it for the person's approval. Give one of file (a path in the project), url, or text."

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "file" => %{"type" => "string", "description" => "A file path under the project"},
        "url" => %{"type" => "string", "description" => "A web page"},
        "text" => %{"type" => "string", "description" => "The document itself"}
      },
      "additionalProperties" => false
    }

  @impl true
  def risk, do: :write

  @impl true
  def effect, do: :artifact

  @impl true
  def execute(args, %Context{session_id: sid, persona: persona} = ctx) do
    model = persona && Map.get(persona, :model)

    with {:ok, change} <- Learn.learn(args, ctx, model: model, session_id: sid),
         {:ok, change} <- Manager.auto(change, persona) do
      {:ok,
       Result.text(
         "Staged the learned skill #{change.skill_name} (change #{change.id}, severity #{change.severity}, status #{change.status}). The person decides on the skills page.",
         %{"change_id" => change.id, "skill" => change.skill_name, "status" => change.status}
       )}
    end
  end
end
