# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Skills.Tools.File do
  @moduledoc """
  `skill_file` (slice 040): one file under a skill's directory, by the relative path
  `skill_view` listed. The path is jailed: joined to the skill's directory, every symlink
  resolved, and refused unless the result is still under that directory (`..`, an absolute
  path and a link out are all `{:error, {:outside_skill, path}}`). At most 64 KB comes back;
  a read, receipted, untrusted like the body.
  """
  @behaviour Trinity.Tools.Tool

  alias Trinity.Tools.{Context, Untrusted}

  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @max_bytes 65_536

  @impl true
  def name, do: "skill_file"

  @impl true
  def description,
    do:
      "Reads one reference or script file of a skill by the relative path `skill_view` listed (for example `references/forms.md`). Paths outside the skill's directory are refused."

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string", "description" => "The skill's name"},
        "path" => %{
          "type" => "string",
          "description" => "A path relative to the skill's directory"
        }
      },
      "required" => ["name", "path"],
      "additionalProperties" => false
    }

  @impl true
  def risk, do: :read

  @impl true
  def effect, do: :none

  @impl true
  # sobelow_skip reason: Traversal.FileModule: the read is `resolve/2`'s result, the real path
  # of the request's relative path under the skill's directory, refused unless it stayed
  # under it (the test plants `../secrets` and a symlink out).
  @sobelow_skip ["Traversal.FileModule"]
  def execute(%{"name" => name, "path" => rel}, %Context{cwd: cwd}) do
    with %{} = skill <-
           Enum.find(Trinity.Skills.active(project_root: cwd), &(&1.name == name)) ||
             {:error, {:no_such_skill, name}},
         {:ok, path} <- resolve(skill.path, rel),
         {:ok, content} <- File.read(path) do
      {text, truncated} =
        if byte_size(content) > @max_bytes,
          do: {binary_part(content, 0, @max_bytes) <> "\n[cut at #{@max_bytes} bytes]", true},
          else: {content, false}

      meta = %{
        "name" => skill.name,
        "path" => rel,
        "bytes" => byte_size(content),
        "truncated" => truncated
      }

      {:ok,
       Untrusted.result(text, tool: name(), source_ref: "skill:#{skill.name}/#{rel}", meta: meta)}
    else
      {:error, :enoent} -> {:error, {:no_such_file, rel}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "The real path of `rel` under `dir`, or `{:error, {:outside_skill, rel}}`."
  @spec resolve(Path.t(), String.t()) :: {:ok, Path.t()} | {:error, term()}
  def resolve(dir, rel) do
    dir = real(Path.expand(dir))
    candidate = real(Path.expand(rel, dir))

    if candidate == dir or String.starts_with?(candidate, dir <> "/"),
      do: {:ok, candidate},
      else: {:error, {:outside_skill, rel}}
  end

  # Every symlink along the path followed (a bounded number of times), missing tails kept as
  # written so a plain missing file is `:enoent` and not a jail refusal.
  defp real(path), do: real(Path.split(path), "/", 0)

  defp real([], acc, _), do: acc
  defp real(_, acc, n) when n > 64, do: acc

  defp real([seg | rest], acc, n) do
    next = Path.join(acc, seg)

    case File.read_link(next) do
      {:ok, target} -> real(Path.split(Path.expand(target, acc)) ++ rest, "/", n + 1)
      _ -> real(rest, next, n)
    end
  end
end
