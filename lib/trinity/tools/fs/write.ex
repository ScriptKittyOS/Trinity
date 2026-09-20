# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Tools.FS.Write do
  @moduledoc """
  `fs_write`: writes a whole file atomically, backing up what was there. Slice 022. Content
  carrying a truncation marker is refused (the write-validation hook, docs/07) unless
  `allow_placeholders` is true, which raises the call to `:destructive`; a path outside the
  roots asks.
  """
  @behaviour Trinity.Tools.Tool

  alias Trinity.Tools.{Context, FS, Result}
  alias Trinity.Tools.FS.Placeholders

  @impl true
  def name, do: "fs_write"
  @impl true
  def description,
    do:
      "Writes the whole content to a file (creating it, or replacing it after a backup). The content must be the complete file: a truncation marker such as `// ... rest of file` is refused."

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string"},
        "content" => %{"type" => "string"},
        "allow_placeholders" => %{
          "type" => "boolean",
          "description" => "Only when the file is meant to contain a marker"
        }
      },
      "required" => ["path", "content"],
      "additionalProperties" => false
    }

  @impl true
  def risk, do: :write
  @impl true
  def effect, do: :artifact

  @impl true
  def escalate(%{"path" => path} = args, %Context{cwd: cwd}) do
    cond do
      Map.get(args, "allow_placeholders", false) -> :destructive
      match?({:ok, _, :outside}, FS.resolve(path, cwd)) -> :ask
      true -> nil
    end
  end

  @impl true
  def execute(%{"path" => path, "content" => content} = args, %Context{cwd: cwd}) do
    {:ok, real, _} = FS.resolve(path, cwd)
    new? = not File.exists?(real)

    with :ok <- validate(content, new?, Map.get(args, "allow_placeholders", false)),
         {:ok, backup} <- FS.backup(real),
         :ok <- FS.atomic_write(real, content) do
      {:ok,
       %Result{
         content:
           "wrote #{byte_size(content)} bytes to #{real}" <> if(new?, do: " (new file)", else: ""),
         artifacts: Enum.reject([%{"kind" => "backup", "path" => backup}], &is_nil(&1["path"])),
         meta: %{"path" => real, "bytes" => byte_size(content), "new" => new?}
       }}
    else
      {:error, {:placeholders, found}} ->
        {:error,
         {:placeholders,
          "refused: the content looks truncated at " <>
            Enum.map_join(found, "; ", fn {n, l} -> "line #{n}: #{l}" end) <>
            ". Write the complete file, or pass allow_placeholders: true if the marker is intended (that asks for approval)."}}

      {:error, reason} ->
        {:error, {:file, reason, real}}
    end
  end

  defp validate(_content, _new?, true), do: :ok

  defp validate(content, _new?, false) do
    case Placeholders.find(content) do
      [] -> :ok
      found -> {:error, {:placeholders, found}}
    end
  end
end
