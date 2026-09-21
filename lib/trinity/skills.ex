# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Skills do
  @moduledoc """
  Procedural memory (slice 040, ADR-0006): skills are directories with a `SKILL.md` in the
  agentskills.io format, found under three roots in precedence order (a project's
  `.trinity/skills`, the data directory's `skills`, the bundled `priv/skills`), parsed into
  `Trinity.Skills.Skill`, indexed in the `skills` table and held by `Trinity.Skills.Registry`,
  and shown to the model by progressive disclosure: the index in the prompt, the body on
  `skill_view`, a reference file on `skill_file`. The filesystem is canonical; the table is
  an index a reindex rebuilds. Nothing here writes a skill: that is slice 041's.

  Depends on Tools because conditional activation asks the registry which tools and
  toolsets exist, and because the three skill tools implement `Trinity.Tools.Tool`; Tools
  never depends on Skills.
  """
  use Boundary,
    deps: [
      Trinity,
      Trinity.Tools,
      Trinity.Memory,
      Trinity.Permissions,
      Trinity.Receipts,
      Trinity.LLM
    ],
    exports: [
      Skill,
      Parser,
      Sources,
      Registry,
      Row,
      Index,
      Tools.List,
      Tools.View,
      Tools.File,
      Tools.Manage,
      Tools.Learn,
      Change,
      Staging,
      Promotion,
      Manager,
      Scanner,
      Diff,
      Learn
    ]

  alias Trinity.Skills.Registry

  @doc "The effective skills (one per name, by precedence); `project_root:` adds a project's."
  @spec list(keyword()) :: [Trinity.Skills.Skill.t()]
  defdelegate list(opts \\ []), to: Registry

  @doc "The skills the model may see now: active, and their requirements met."
  @spec active(keyword()) :: [Trinity.Skills.Skill.t()]
  defdelegate active(opts \\ []), to: Registry

  @doc "A skill by name, among the effective ones."
  @spec get(String.t(), keyword()) :: Trinity.Skills.Skill.t() | nil
  defdelegate get(name, opts \\ []), to: Registry

  @doc "Rescans every root and rewrites the index."
  @spec rescan() :: :ok
  defdelegate rescan(), to: Registry

  @doc "Enables or disables a skill by name and source; persisted in the index."
  @spec set_status(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  defdelegate set_status(name, source, status), to: Registry
end
