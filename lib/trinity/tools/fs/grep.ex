# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Tools.FS.Grep do
  @moduledoc "`fs_grep`: lines matching a regular expression under a directory, with caps. Outside the roots it asks. Slice 022."
  @behaviour Trinity.Tools.Tool

  alias Trinity.Tools.{Context, FS, Taint, Untrusted}
  alias Trinity.Tools.FS.Guard

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
  def escalate(args, %Context{cwd: cwd}), do: FS.escalation(Map.get(args, "path", "."), cwd, :dir)

  @impl true
  def fs_paths(args, _ctx), do: [{Map.get(args, "path", "."), :dir}]

  @impl true
  def execute(%{"pattern" => pattern} = args, %Context{cwd: cwd} = ctx) do
    with {:ok, real, where} <- FS.resolve(Map.get(args, "path", "."), cwd, :dir) do
      # Slice 135: a search outside the roots (approved) reads from a path tagged sensitive.
      if where == :outside,
        do: Taint.note_read(%{decision: :ask, canonical: real}, ctx.session_id)

      grep(real, pattern, args, cwd)
    end
  end

  defp grep(real, pattern, args, cwd) do
    case Regex.compile(pattern) do
      {:ok, regex} ->
        files =
          real
          |> Path.join(Map.get(args, "glob", "**/*"))
          |> Path.wildcard(match_dot: true)
          |> Enum.filter(&File.regular?/1)
          |> Enum.take(@max_files)

        # Slice 135: every file is opened by the guard (one scope for the call), so a link, a hard
        # link or a protected inode met on the way is refused per file and named in the receipt.
        scope = Guard.scope(cwd)
        {lines, count, refused} = collect(files, regex, real, cwd, scope)
        text = Enum.join(lines, "\n")

        meta = %{
          "path" => real,
          "files" => length(files),
          "matches" => count,
          "capped" => count >= @max_matches,
          "fs_refused" => refused
        }

        {:ok, Untrusted.result(text, tool: "fs_grep", source_ref: real, meta: meta)}

      {:error, {reason, _}} ->
        {:error, {:regex, "invalid pattern: #{reason}"}}
    end
  end

  # Matches across the files, stopping at the cap; the guard's refusals beside them.
  defp collect(files, regex, root, cwd, scope) do
    {lines, n, refused} =
      Enum.reduce_while(files, {[], 0, []}, fn file, acc ->
        file |> grep_file(regex, root, cwd, scope) |> add(acc)
      end)

    {lines, n, Enum.reverse(refused)}
  end

  defp add({:refused, verdict}, {acc, n, refused}), do: {:cont, {acc, n, [verdict | refused]}}
  defp add([], acc), do: {:cont, acc}

  defp add(hits, {acc, n, refused}) do
    room = @max_matches - n

    if length(hits) >= room,
      do: {:halt, {acc ++ Enum.take(hits, room), @max_matches, refused}},
      else: {:cont, {acc ++ hits, n + length(hits), refused}}
  end

  # sobelow_skip reason: Traversal.FileModule fires on every File call whose path is a variable,
  # and a filesystem tool's path is the model's argument by design. The control is not the
  # path's shape but the gate: `Trinity.Tools.FS.Guard` judges every path (no symlink
  # followed, protected directories and inodes refused) against the roots and the tools
  # escalate anything outside to `:ask` (docs/07, filesystem; slice 022 AC1), and a write is
  # atomic with a backup. Scoped to the function rather than .sobelow-skips, which keys on file
  # and line.
  @sobelow_skip ["Traversal.FileModule"]
  defp grep_file(file, regex, root, cwd, scope) do
    with {:ok, %{size: size}} when size <= @max_file_bytes <- File.lstat(file),
         {:ok, bytes} <- guarded_read(file, cwd, scope),
         true <- String.valid?(bytes) do
      bytes
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.filter(fn {l, _} -> Regex.match?(regex, l) end)
      |> Enum.map(fn {l, n} ->
        "#{Path.relative_to(file, root)}:#{n}: #{String.slice(l, 0, 300)}"
      end)
    else
      {:refused, _} = refused -> refused
      _ -> []
    end
  end

  defp guarded_read(file, cwd, scope) do
    case Guard.read(file, cwd, scope: scope) do
      {:ok, bytes, _verdict} -> {:ok, bytes}
      {:error, {:fs_denied, verdict}} -> {:refused, verdict}
      {:error, _} = error -> error
    end
  end
end
