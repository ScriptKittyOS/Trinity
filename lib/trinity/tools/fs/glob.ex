# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Tools.FS.Glob do
  @moduledoc "`fs_glob`: paths matching a pattern under a directory. Outside the roots it asks. Slice 022."
  @behaviour Trinity.Tools.Tool

  alias Trinity.Tools.{Context, FS, Untrusted}

  @max_matches 1_000

  @impl true
  def name, do: "fs_glob"
  @impl true
  def description,
    do:
      "Finds files by glob under a directory, e.g. `**/*.ex`. At most 1,000 paths, relative to the directory."

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "pattern" => %{"type" => "string"},
        "path" => %{
          "type" => "string",
          "description" => "The directory; default the working directory"
        }
      },
      "required" => ["pattern"],
      "additionalProperties" => false
    }

  @impl true
  def risk, do: :read
  @impl true
  def effect, do: :none

  @impl true
  def escalate(args, %Context{cwd: cwd}) do
    case FS.resolve(Map.get(args, "path", "."), cwd) do
      {:ok, _, :inside} -> nil
      {:ok, _, :outside} -> :ask
    end
  end

  @impl true
  def execute(%{"pattern" => pattern} = args, %Context{cwd: cwd}) do
    {:ok, real, _} = FS.resolve(Map.get(args, "path", "."), cwd)

    matches =
      real
      |> Path.join(pattern)
      |> Path.wildcard(match_dot: true)
      |> Enum.map(&Path.relative_to(&1, real))
      |> Enum.sort()

    lines = matches |> Enum.take(@max_matches) |> Enum.join("\n")

    meta = %{
      "path" => real,
      "matches" => length(matches),
      "shown" => min(length(matches), @max_matches)
    }

    {:ok, Untrusted.result(lines, tool: "fs_glob", source_ref: real, meta: meta)}
  end
end
