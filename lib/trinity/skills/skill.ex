# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Skills.Skill do
  @moduledoc """
  One skill as parsed from its directory (slice 040): the agentskills.io frontmatter, the
  Trinity extension keys, the body, the listings of `references/` and `scripts/`, the SHA-256
  of `SKILL.md` and a per-file digest manifest of the whole directory (the platform
  alignment's "what was audited is what is loaded"). `source` and `scope` are the root's
  (`bundled`/`global`, `user`/`account`, `project`/`project`); `status` is the index row's
  (`active` or `disabled`).
  """

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          category: String.t(),
          license: String.t() | nil,
          compatibility: String.t() | nil,
          metadata: %{String.t() => String.t()},
          allowed_tools: [String.t()],
          trinity: map(),
          body: String.t(),
          references: [String.t()],
          scripts: [String.t()],
          body_hash: String.t(),
          manifest: %{String.t() => String.t()},
          path: String.t(),
          source: String.t() | nil,
          scope: String.t() | nil,
          status: String.t(),
          version: pos_integer(),
          shadows: [String.t()]
        }

  defstruct name: nil,
            description: "",
            category: "general",
            license: nil,
            compatibility: nil,
            metadata: %{},
            allowed_tools: [],
            trinity: %{},
            body: "",
            references: [],
            scripts: [],
            body_hash: nil,
            manifest: %{},
            path: nil,
            source: nil,
            scope: nil,
            status: "active",
            version: 1,
            shadows: []

  @doc "The one-line description the index shows: the first sentence, at most 120 characters."
  @spec one_line(t()) :: String.t()
  def one_line(%__MODULE__{description: d}) do
    first =
      case Regex.run(~r/^(.+?[.!?])(\s|$)/s, String.trim(d)) do
        [_, sentence | _] -> sentence
        _ -> String.trim(d)
      end

    first = String.replace(first, ~r/\s+/, " ")
    if String.length(first) > 120, do: String.slice(first, 0, 117) <> "...", else: first
  end

  @doc "The tool names the skill needs (`trinity.requires_tools`)."
  @spec requires_tools(t()) :: [String.t()]
  def requires_tools(%__MODULE__{trinity: t}), do: strings(t["requires_tools"])

  @doc "The toolsets the skill needs (`trinity.requires_toolsets`), as atoms the registry knows."
  @spec requires_toolsets(t()) :: [String.t()]
  def requires_toolsets(%__MODULE__{trinity: t}), do: strings(t["requires_toolsets"])

  @doc "The toolsets whose absence this skill stands in for (`trinity.fallback_for_toolsets`)."
  @spec fallback_for_toolsets(t()) :: [String.t()]
  def fallback_for_toolsets(%__MODULE__{trinity: t}), do: strings(t["fallback_for_toolsets"])

  defp strings(nil), do: []
  defp strings(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp strings(one), do: [to_string(one)]
end
