# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Tools.FS.Edit do
  @moduledoc """
  `fs_edit`: replaces one unique occurrence of `search` with `replace` in a file, atomically,
  after a backup, and returns a unified diff. Slice 022. A search string found twice or not at
  all is refused; the placeholder hook applies to the replacement.
  """
  @behaviour Trinity.Tools.Tool

  alias Trinity.Tools.{Context, FS, Result}
  alias Trinity.Tools.FS.Placeholders

  # Sobelow reads `@sobelow_skip` from the source; the compiler would call it unused (the
  # measure `Trinity.Paths` takes).
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @impl true
  def name, do: "fs_edit"
  @impl true
  def description,
    do:
      "Edits a file by replacing exactly one occurrence of `search` with `replace`. The search text must be unique in the file; include enough surrounding lines to make it so. Returns a diff."

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string"},
        "search" => %{"type" => "string", "minLength" => 1},
        "replace" => %{"type" => "string"}
      },
      "required" => ["path", "search", "replace"],
      "additionalProperties" => false
    }

  @impl true
  def risk, do: :write
  @impl true
  def effect, do: :artifact

  @impl true
  def escalate(%{"path" => path}, %Context{cwd: cwd}) do
    case FS.resolve(path, cwd) do
      {:ok, _, :outside} -> :ask
      _ -> nil
    end
  end

  # sobelow_skip reason: Traversal.FileModule fires on every File call whose path is a variable,
  # and a filesystem tool's path is the model's argument by design. The control is not the
  # path's shape but the gate: `Trinity.Tools.FS.resolve/2` judges every path after symlink
  # resolution against the roots and the tools escalate anything outside to `:ask` (docs/07,
  # filesystem; slice 022 AC1), and a write is atomic with a backup. Scoped to the function
  # rather than .sobelow-skips, which keys on file and line.
  @sobelow_skip ["Traversal.FileModule"]
  @impl true
  def execute(%{"path" => path, "search" => search, "replace" => replace}, %Context{cwd: cwd}) do
    {:ok, real, _} = FS.resolve(path, cwd)

    with {:ok, before} <- File.read(real),
         :ok <- placeholders(replace),
         {:ok, after_text} <- replace_once(before, search, replace),
         {:ok, backup} <- FS.backup(real),
         :ok <- FS.atomic_write(real, after_text) do
      diff = unified_diff(real, before, after_text)

      {:ok,
       %Result{
         content: diff,
         artifacts: [%{"kind" => "backup", "path" => backup}],
         meta: %{
           "path" => real,
           "bytes_before" => byte_size(before),
           "bytes_after" => byte_size(after_text)
         }
       }}
    else
      {:error, :not_found} ->
        {:error, {:edit, "the search text was not found in #{real}"}}

      {:error, {:ambiguous, n}} ->
        {:error, {:edit, "the search text occurs #{n} times in #{real}; make it unique"}}

      {:error, {:placeholders, found}} ->
        {:error,
         {:placeholders,
          "refused: the replacement looks truncated at " <>
            Enum.map_join(found, "; ", fn {n, l} -> "line #{n}: #{l}" end)}}

      {:error, reason} when is_atom(reason) ->
        {:error, {:file, reason, real}}

      {:error, other} ->
        {:error, other}
    end
  end

  defp placeholders(replace) do
    case Placeholders.find(replace) do
      [] -> :ok
      found -> {:error, {:placeholders, found}}
    end
  end

  @doc "The text with the one occurrence replaced; refused when absent or ambiguous."
  @spec replace_once(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :not_found | {:ambiguous, pos_integer()}}
  def replace_once(text, search, replace) do
    case length(String.split(text, search)) - 1 do
      0 -> {:error, :not_found}
      1 -> {:ok, String.replace(text, search, replace, global: false)}
      n -> {:error, {:ambiguous, n}}
    end
  end

  @doc "A unified diff, computed line by line with `List.myers_difference/2`."
  @spec unified_diff(String.t(), String.t(), String.t()) :: String.t()
  def unified_diff(path, before, after_text) do
    edits = List.myers_difference(String.split(before, "\n"), String.split(after_text, "\n"))

    body =
      Enum.flat_map(edits, fn
        {:eq, lines} -> Enum.map(lines, &(" " <> &1))
        {:del, lines} -> Enum.map(lines, &("-" <> &1))
        {:ins, lines} -> Enum.map(lines, &("+" <> &1))
      end)

    ("--- #{path}\n+++ #{path}\n" <> Enum.join(trim_context(body), "\n"))
    |> String.trim_trailing()
  end

  # Three lines of context around each change, the rest elided.
  defp trim_context(lines) do
    changed = for {l, i} <- Enum.with_index(lines), not String.starts_with?(l, " "), do: i
    keep = MapSet.new(Enum.flat_map(changed, &Enum.to_list((&1 - 3)..(&1 + 3))))

    lines
    |> Enum.with_index()
    |> Enum.chunk_by(fn {_, i} -> MapSet.member?(keep, i) end)
    |> Enum.flat_map(fn chunk ->
      {_, i} = hd(chunk)

      if MapSet.member?(keep, i),
        do: Enum.map(chunk, &elem(&1, 0)),
        else: ["@@ #{length(chunk)} lines unchanged @@"]
    end)
  end
end
