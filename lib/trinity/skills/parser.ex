# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Skills.Parser do
  @moduledoc """
  A skill directory into a `Trinity.Skills.Skill` (slice 040). `SKILL.md` is YAML frontmatter
  between `---` lines and a Markdown body; the frontmatter is held to the agentskills.io
  specification (read 2026-09-21): `name` 1 to 64 characters of lowercase `a-z0-9` and single
  hyphens, not at either end, equal to the directory's name; `description` 1 to 1,024
  characters; `compatibility` at most 500; `metadata` a map of string to string;
  `allowed-tools` a string. Unknown keys are kept in `metadata`-less form: they are ignored,
  not refused, so a skill written for another agent parses (ADR-0006). Trinity's keys live
  under `trinity:` (`requires_tools`, `requires_toolsets`, `fallback_for_toolsets`, `risk`,
  `lua_entry`, `category`); the category may also come from `metadata.category`.

  Every refusal is `{:error, {reason, detail}}` naming what was wrong, and the whole
  directory's regular files are digested into the manifest.
  """

  alias Trinity.Skills.Skill

  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @file_name "SKILL.md"
  @name_re ~r/^[a-z0-9]+(-[a-z0-9]+)*$/
  @trinity_keys ~w(requires_tools requires_toolsets fallback_for_toolsets risk lua_entry category)

  @doc "The skill file's name."
  @spec file_name() :: String.t()
  def file_name, do: @file_name

  @doc "Parses the directory at `dir`."
  @spec parse_dir(Path.t()) :: {:ok, Skill.t()} | {:error, {atom(), term()}}
  # sobelow_skip reason: Traversal.FileModule: `dir` is a directory under one of the three
  # skill roots the registry scans (`Trinity.Skills.Sources`), never a request's path.
  @sobelow_skip ["Traversal.FileModule"]
  def parse_dir(dir) do
    dir = Path.expand(dir)
    path = Path.join(dir, @file_name)

    with {:ok, content} <- read(path),
         {:ok, skill} <- parse(content, Path.basename(dir)) do
      {:ok,
       %{
         skill
         | path: dir,
           references: listing(dir, "references"),
           scripts: listing(dir, "scripts"),
           manifest: manifest(dir)
       }}
    end
  end

  @doc "Parses `SKILL.md` content; `dir_name` is what `name` must equal."
  @spec parse(String.t(), String.t()) :: {:ok, Skill.t()} | {:error, {atom(), term()}}
  def parse(content, dir_name) do
    with {:ok, yaml, body} <- split(content),
         {:ok, fm} <- decode(yaml),
         {:ok, name} <- name(fm["name"], dir_name),
         {:ok, description} <- bounded(fm["description"], :description, 1, 1_024),
         {:ok, compatibility} <- optional_bounded(fm["compatibility"], :compatibility, 500),
         {:ok, metadata} <- metadata(fm["metadata"]),
         {:ok, allowed} <- allowed_tools(fm["allowed-tools"]),
         {:ok, trinity} <- trinity(fm["trinity"]) do
      {:ok,
       %Skill{
         name: name,
         description: description,
         category: category(trinity, metadata),
         license: string_or_nil(fm["license"]),
         compatibility: compatibility,
         metadata: metadata,
         allowed_tools: allowed,
         trinity: trinity,
         body: body,
         body_hash: digest(content)
       }}
    end
  end

  @doc "SHA-256, lowercase hex."
  @spec digest(binary()) :: String.t()
  def digest(bin), do: :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower)

  @doc "Every regular file under the directory, relative path to its digest (symlinks are not followed)."
  @spec manifest(Path.t()) :: %{String.t() => String.t()}
  # sobelow_skip reason: Traversal.FileModule: the walk starts at the skill directory the
  # registry handed in and reads only what `Path.wildcard` found under it.
  @sobelow_skip ["Traversal.FileModule"]
  def manifest(dir) do
    dir = Path.expand(dir)

    dir
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&regular_not_link?/1)
    |> Map.new(fn p -> {Path.relative_to(p, dir), digest(File.read!(p))} end)
  end

  defp regular_not_link?(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} -> true
      _ -> false
    end
  end

  # sobelow_skip reason: Traversal.FileModule: `path` is `parse_dir/1`'s, the skill directory
  # under a scanned root joined with the constant file name.
  @sobelow_skip ["Traversal.FileModule"]
  defp read(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, {:no_skill_md, {path, reason}}}
    end
  end

  defp split(content) do
    case Regex.run(~r/\A---[ \t]*\r?\n(.*?)\r?\n---[ \t]*(?:\r?\n|\z)(.*)\z/s, content) do
      [_, yaml, body] -> {:ok, yaml, String.trim_leading(body, "\n")}
      _ -> {:error, {:no_frontmatter, "SKILL.md must open with a --- YAML block closed by ---"}}
    end
  end

  defp decode(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, %{} = map} -> {:ok, map}
      {:ok, other} -> {:error, {:frontmatter_not_a_map, inspect(other)}}
      {:error, %{message: m}} -> {:error, {:yaml, m}}
      {:error, reason} -> {:error, {:yaml, inspect(reason)}}
    end
  end

  defp name(nil, _), do: {:error, {:name, "missing"}}

  defp name(name, dir_name) when is_binary(name) do
    cond do
      String.length(name) > 64 ->
        {:error, {:name, "longer than 64 characters"}}

      not Regex.match?(@name_re, name) ->
        {:error,
         {:name, "#{inspect(name)}: lowercase a-z, 0-9 and single hyphens, not at either end"}}

      name != dir_name ->
        {:error, {:name, "#{inspect(name)} does not match its directory #{inspect(dir_name)}"}}

      true ->
        {:ok, name}
    end
  end

  defp name(other, _), do: {:error, {:name, "not a string: #{inspect(other)}"}}

  defp bounded(nil, key, _min, _max), do: {:error, {key, "missing"}}

  defp bounded(v, key, min, max) when is_binary(v) do
    n = String.length(String.trim(v))

    cond do
      n < min -> {:error, {key, "empty"}}
      n > max -> {:error, {key, "longer than #{max} characters"}}
      true -> {:ok, String.trim(v)}
    end
  end

  defp bounded(v, key, _, _), do: {:error, {key, "not a string: #{inspect(v)}"}}

  defp optional_bounded(nil, _key, _max), do: {:ok, nil}
  defp optional_bounded(v, key, max), do: bounded(v, key, 1, max)

  defp metadata(nil), do: {:ok, %{}}

  defp metadata(%{} = map) do
    if Enum.all?(map, fn {k, v} ->
         is_binary(k) and (is_binary(v) or is_number(v) or is_boolean(v))
       end),
       do: {:ok, Map.new(map, fn {k, v} -> {k, to_string(v)} end)},
       else: {:error, {:metadata, "a map of string keys to string values"}}
  end

  defp metadata(other), do: {:error, {:metadata, "not a map: #{inspect(other)}"}}

  defp allowed_tools(nil), do: {:ok, []}
  defp allowed_tools(s) when is_binary(s), do: {:ok, String.split(s, ~r/\s+/, trim: true)}
  defp allowed_tools(other), do: {:error, {:allowed_tools, "not a string: #{inspect(other)}"}}

  defp trinity(nil), do: {:ok, %{}}

  defp trinity(%{} = map) do
    known = Map.take(map, @trinity_keys)

    with :ok <- list_of_strings(known, "requires_tools"),
         :ok <- list_of_strings(known, "requires_toolsets"),
         :ok <- list_of_strings(known, "fallback_for_toolsets"),
         :ok <- risk(known["risk"]) do
      {:ok, known}
    end
  end

  defp trinity(other), do: {:error, {:trinity, "not a map: #{inspect(other)}"}}

  # The keys are this module's constants, so the atoms exist (the sobelow check reads a
  # variable and cannot see that; the atoms are named here rather than made from strings).
  defp list_of_strings(map, key) do
    case map[key] do
      nil ->
        :ok

      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1),
          do: :ok,
          else: {:error, {key_atom(key), "a list of strings"}}

      one when is_binary(one) ->
        :ok

      other ->
        {:error, {key_atom(key), "a list of strings, got #{inspect(other)}"}}
    end
  end

  defp key_atom("requires_tools"), do: :requires_tools
  defp key_atom("requires_toolsets"), do: :requires_toolsets
  defp key_atom("fallback_for_toolsets"), do: :fallback_for_toolsets

  defp risk(nil), do: :ok
  defp risk(r) when r in ["read", "write", "execute", "network"], do: :ok

  defp risk(other),
    do: {:error, {:risk, "one of read, write, execute, network; got #{inspect(other)}"}}

  defp category(trinity, metadata) do
    case trinity["category"] || metadata["category"] do
      c when is_binary(c) and c != "" -> c |> String.downcase() |> String.trim()
      _ -> "general"
    end
  end

  defp string_or_nil(v) when is_binary(v), do: v
  defp string_or_nil(_), do: nil

  defp listing(dir, sub) do
    base = Path.join(dir, sub)

    if File.dir?(base) do
      base
      |> Path.join("**")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.relative_to(&1, dir))
      |> Enum.sort()
    else
      []
    end
  end
end
