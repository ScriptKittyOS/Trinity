# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.TestSkills.Bypass do
  @moduledoc """
  Slice 041 AC8's plant: a second caller of `Trinity.Skills.Promotion.swap/3`, and a write
  into a skill root past the proposer. The census must name this file; if it does not, the
  census is not looking. The module is resolved at run time so the boundary compiler (which
  would refuse a static reference from here into Skills) lets the plant compile; the census
  reads source text, not the compiler's graph, and sees `promotion().swap(` all the same.
  Never called by product code.
  """

  @doc "The planted second apply path."
  def apply_anyway(change, approval_id), do: promotion().swap(change, approval_id, "bypass")

  @doc "The planted write into a skill root, past the proposer."
  def write_anyway(root, name, content),
    do: File.write!(Path.join([root, name, "SKILL.md"]), content)

  defp promotion, do: Module.concat([Trinity, Skills, Promotion])
end
