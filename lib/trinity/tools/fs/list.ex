# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Tools.FS.List do
  @moduledoc "`fs_list`: a directory's entries with kind and size. Outside the roots it asks. Slice 022."
  @behaviour Trinity.Tools.Tool

  alias Trinity.Tools.{Context, FS, Untrusted}

  @max_entries 2_000

  @impl true
  def name, do: "fs_list"
  @impl true
  def description,
    do:
      "Lists a directory: one entry per line as `kind size name` (kind d or f). Hidden entries included; at most 2,000."

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string", "description" => "Default: the working directory"}
      },
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
  def execute(args, %Context{cwd: cwd}) do
    {:ok, real, _} = FS.resolve(Map.get(args, "path", "."), cwd)

    case File.ls(real) do
      {:ok, names} ->
        lines =
          names |> Enum.sort() |> Enum.take(@max_entries) |> Enum.map_join("\n", &entry(real, &1))

        meta = %{"path" => real, "entries" => min(length(names), @max_entries)}
        {:ok, Untrusted.result(lines, tool: "fs_list", source_ref: real, meta: meta)}

      {:error, reason} ->
        {:error, {:file, reason, real}}
    end
  end

  defp entry(dir, name) do
    case File.stat(Path.join(dir, name)) do
      {:ok, %{type: :directory}} -> "d\t-\t#{name}/"
      {:ok, %{size: size}} -> "f\t#{size}\t#{name}"
      _ -> "?\t-\t#{name}"
    end
  end
end
