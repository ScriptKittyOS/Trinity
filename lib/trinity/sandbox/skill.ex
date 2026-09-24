# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Sandbox.Skill do
  @moduledoc """
  Running a skill's script in the sandbox (slice 110 AC5).

  A skill declares `trinity.lua_entry` in its front matter, which slice 040's parser has carried
  since the skills system existed and nothing has been able to run until now. The entry names a file
  under the skill's own `scripts/` directory; this reads it, runs it under the same limits and the
  same host surface as any other sandbox run, and maps what the script declares onto a tool result.

  ## The path is resolved, not trusted

  `lua_entry` comes from a skill's front matter, and a skill can be proposed by the agent. A value of
  `../../../etc/passwd` must not read that file, so the resolved path is checked to be inside the
  skill's own directory before anything opens it. Skills are staged and approved (slice 041), which
  is a control on *what gets installed*; this is the control on what an installed one can reach, and
  the two are different questions.
  """

  alias Trinity.Sandbox
  alias Trinity.Skills.{Registry, Skill}
  alias Trinity.Tools.Context

  @type outcome :: {:ok, term(), map()} | {:error, term()}

  @doc "Runs the named skill's `lua_entry`, with `args` bound to the Lua global `args`."
  @spec run(String.t(), map(), Context.t(), keyword()) :: outcome()
  def run(name, args, %Context{} = ctx, opts \\ []) do
    with {:ok, skill} <- fetch(name),
         {:ok, entry} <- entry(skill),
         {:ok, path} <- script_path(skill, entry),
         {:ok, source} <- read(path) do
      Sandbox.run(preamble(args) <> source, Keyword.merge([context: ctx], opts))
    end
  end

  defp fetch(name) do
    case Registry.get(name) do
      %Skill{} = skill -> {:ok, skill}
      nil -> {:error, {:unknown_skill, name}}
    end
  end

  defp entry(%Skill{trinity: trinity, name: name}) do
    case Map.get(trinity, "lua_entry") do
      entry when is_binary(entry) and entry != "" -> {:ok, entry}
      _ -> {:error, {:no_lua_entry, name}}
    end
  end

  @doc """
  Where a skill's `lua_entry` resolves to, or a refusal.

  Public because it is the check that matters and a test of a copy of it would prove nothing.
  `Path.expand/2` resolves `..` before the comparison, so a traversal is caught by where it *lands*
  rather than by what it looks like, which is the only way that holds: a pattern match on ".." is
  defeated by symlinks and by encoding, and a resolved path is not.
  """
  @spec script_path(Skill.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def script_path(%Skill{path: nil, name: name}, _entry), do: {:error, {:skill_has_no_path, name}}

  def script_path(%Skill{path: dir}, entry) do
    root = Path.expand(Path.join(dir, "scripts"))
    resolved = Path.expand(Path.join(root, entry))

    if String.starts_with?(resolved, root <> "/") or resolved == root do
      {:ok, resolved}
    else
      {:error, {:script_outside_skill, entry}}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, source} -> {:ok, source}
      {:error, reason} -> {:error, {:script_unreadable, path, reason}}
    end
  end

  # `args` arrives as a Lua table literal rather than through the host API, so a script reads it the
  # way a Lua programmer expects and an empty call still binds the name. Encoded through Jason and
  # decoded by the sandbox's own `json`, so there is one encoder rather than a second hand-rolled
  # one that will disagree with it.
  defp preamble(args) when args == %{} or args == nil, do: "local args = {}\n"

  defp preamble(args) do
    "local args = json.decode(" <> inspect(Jason.encode!(args)) <> ")\n"
  end
end
