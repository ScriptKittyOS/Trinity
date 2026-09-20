# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Tools.FS.Read do
  @moduledoc "`fs_read`: a file's text, by line range, capped. Outside the roots it asks. Slice 022."
  @behaviour Trinity.Tools.Tool

  alias Trinity.Tools.{Context, FS, Untrusted}

  @max_bytes 256 * 1024

  # Sobelow reads `@sobelow_skip` from the source; the compiler would call it unused (the
  # measure `Trinity.Paths` takes).
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @impl true
  def name, do: "fs_read"
  @impl true
  def description,
    do:
      "Reads a text file. Returns numbered lines from `offset` (1-based, default 1), at most `limit` lines (default 500). Large files are cut at 256 KB."

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" => "Absolute, or relative to the working directory"
        },
        "offset" => %{"type" => "integer", "minimum" => 1},
        "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 5000}
      },
      "required" => ["path"],
      "additionalProperties" => false
    }

  @impl true
  def risk, do: :read
  @impl true
  def effect, do: :none

  @impl true
  def escalate(%{"path" => path}, %Context{cwd: cwd}) do
    case FS.resolve(path, cwd) do
      {:ok, _, :inside} -> nil
      {:ok, _, :outside} -> :ask
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
  def execute(%{"path" => path} = args, %Context{cwd: cwd}) do
    {:ok, real, _} = FS.resolve(path, cwd)
    offset = Map.get(args, "offset", 1)
    limit = Map.get(args, "limit", 500)

    case File.read(real) do
      {:ok, bytes} ->
        {text, cut?} = cap(bytes)

        lines =
          text
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.drop(offset - 1)
          |> Enum.take(limit)
          |> Enum.map_join("\n", fn {l, n} -> "#{n}\t#{l}" end)

        meta = %{"path" => real, "bytes" => byte_size(bytes), "cut_at_256kb" => cut?}
        {:ok, Untrusted.result(lines, tool: "fs_read", source_ref: real, meta: meta)}

      {:error, reason} ->
        {:error, {:file, reason, real}}
    end
  end

  defp cap(bytes) when byte_size(bytes) > @max_bytes,
    do: {binary_part(bytes, 0, @max_bytes) |> String.chunk(:valid) |> Enum.join(), true}

  defp cap(bytes), do: {bytes, false}
end
