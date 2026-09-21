# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Context do
  @moduledoc """
  What a session's project tells the prompt (slice 033): the context tier's repository
  content, read from the project root every turn, untrusted by provenance. `AgentsMd` is the
  first source; slice 040's skills index joins it in the same tier.
  """
  use Boundary, deps: [Trinity, Trinity.Skills], exports: [AgentsMd, SkillsIndex]
end
