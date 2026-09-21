# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Context.SkillsIndex do
  @moduledoc """
  The skills index in the context tier (slice 040): the active skills for the session's
  project, rendered by `Trinity.Skills.Index` under the prompt cap. Read every turn like the
  AGENTS.md block beside it, so a skill added on disk is in the next turn.
  """

  alias Trinity.Skills.Index

  @doc "The block for a project root (`nil` for none): `\"\"` when no skill is active."
  @spec render(String.t() | nil) :: String.t()
  def render(project_root) do
    project_root
    |> then(&Trinity.Skills.active(project_root: &1))
    |> Index.render(Index.default_tokens())
  end
end
