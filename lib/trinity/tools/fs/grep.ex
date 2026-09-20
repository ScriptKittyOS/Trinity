# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Tools.FS.Grep do
  @moduledoc "`fs_grep`: lines matching a regular expression under a directory, with caps. Outside the roots it asks. Slice 022."
  @behaviour Trinity.Tools.Tool

  alias Trinity.Tools.{Context, FS, Untrusted}

  @max_files 5_000
  @max_matches 500
  @max_file_bytes 2 * 1024 * 1024

  # Sobelow reads `@sobelow_skip` from the source; the compiler would call it unused (the
  # measure `Trinity.Paths` takes).
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @impl true
  def name, do: "fs_grep"
  @impl true
  def description,
    do:
      "Searches files under a directory for a regular expression; `glob` narrows the files (default `**/*`). Returns `path:line: text`, at most 500 matches."

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "pattern" => %{"type" => "string", "minLength" => 1},
        "path" => %{"type" => "string"},
        "glob" => %{"type" => "string"}
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

    case Regex.compile(pattern) do
      {:ok, regex} ->
        files =
          real
          |> Path.join(Map.get(args, "glob", "**/*"))
          |> Path.wildcard(match_dot: true)
          |> Enum.filter(&File.regular?/1)
          |> Enum.take(@max_files)

        {lines, count} = collect(files, regex, real)
        text = Enum.join(lines, "\n")

        meta = %{
          "path" => real,
          "files" => length(files),
          "matches" => count,
          "capped" => count >= @max_matches
        }

        {:ok, Untrusted.result(text, tool: "fs_grep", source_ref: real, meta: meta)}

      {:error, {reason, _}} ->
        {:error, {:regex, "invalid pattern: #{reason}"}}
    end
  end

  # Matches across the files, stopping at the cap.
  defp collect(files, regex, root) do
    Enum.reduce_while(files, {[], 0}, fn file, {acc, n} ->
      hits = grep_file(file, regex, root)
      room = @max_matches - n

      cond do
        hits == [] -> {:cont, {acc, n}}
        length(hits) >= room -> {:halt, {acc ++ Enum.take(hits, room), @max_matches}}
        true -> {:cont, {acc ++ hits, n + length(hits)}}
      end
    end)
  end

  # sobelow_skip reason: Traversal.FileModule fires on every File call whose path is a variable,
  # and a filesystem tool's path is the model's argument by design. The control is not the
  # path's shape but the gate: `Trinity.Tools.FS.resolve/2` judges every path after symlink
  # resolution against the roots and the tools escalate anything outside to `:ask` (docs/07,
  # filesystem; slice 022 AC1), and a write is atomic with a backup. Scoped to the function
  # rather than .sobelow-skips, which keys on file and line.
  @sobelow_skip ["Traversal.FileModule"]
  defp grep_file(file, regex, root) do
    with {:ok, %{size: size}} when size <= @max_file_bytes <- File.stat(file),
         {:ok, bytes} <- File.read(file),
         true <- String.valid?(bytes) do
      bytes
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.filter(fn {l, _} -> Regex.match?(regex, l) end)
      |> Enum.map(fn {l, n} ->
        "#{Path.relative_to(file, root)}:#{n}: #{String.slice(l, 0, 300)}"
      end)
    else
      _ -> []
    end
  end
end
