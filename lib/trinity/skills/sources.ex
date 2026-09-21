# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Skills.Sources do
  @moduledoc """
  Where skills come from (slice 040), in precedence order: a project's `.trinity/skills`
  (source `project`, scope `project`), the data directory's `skills` (source `user`, scope
  `account`) and the bundled `priv/skills` (source `bundled`, scope `global`). A same-named
  skill in two roots resolves to the earlier one; the later is listed as shadowed.

  `config :trinity, :skills` may name `user_dir:` and `bundled_dir:` (the suite points them
  at fixtures). A scan parses every subdirectory holding a `SKILL.md`, refuses one whose
  `.trinity-manifest.json` (slice 041's scanner writes it) does not match the files on disk,
  and returns the skills and the errors side by side: a bad skill never hides a good one.
  """

  alias Trinity.Skills.{Parser, Skill}

  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @manifest_file ".trinity-manifest.json"
  @precedence ["project", "user", "bundled"]

  @type root :: %{source: String.t(), scope: String.t(), dir: Path.t()}
  @type error :: %{dir: Path.t(), source: String.t(), reason: term()}

  @doc "The manifest file's name."
  @spec manifest_file() :: String.t()
  def manifest_file, do: @manifest_file

  @doc "Sources in precedence order."
  @spec precedence() :: [String.t()]
  def precedence, do: @precedence

  @doc "The rank of a source: lower wins."
  @spec rank(String.t()) :: non_neg_integer()
  def rank(source), do: Enum.find_index(@precedence, &(&1 == source)) || length(@precedence)

  @doc "The global roots (user, bundled), existing or not."
  @spec roots() :: [root()]
  def roots do
    [
      %{source: "user", scope: "account", dir: user_dir()},
      %{source: "bundled", scope: "global", dir: bundled_dir()}
    ]
  end

  @doc "A project's root for a project directory (`nil` for none)."
  @spec project_root(String.t() | nil) :: root() | nil
  def project_root(nil), do: nil

  def project_root(project_dir),
    do: %{
      source: "project",
      scope: "project",
      dir: Path.join(Path.expand(project_dir), ".trinity/skills")
    }

  @doc "The user root in force."
  @spec user_dir() :: Path.t()
  def user_dir, do: config(:user_dir) || Path.join(Trinity.Paths.data_dir(), "skills")

  @doc "The bundled root in force."
  @spec bundled_dir() :: Path.t()
  def bundled_dir,
    do: config(:bundled_dir) || Path.join(to_string(:code.priv_dir(:trinity)), "skills")

  @doc "Scans one root: every child directory with a SKILL.md, parsed and manifest-checked."
  @spec scan(root()) :: {[Skill.t()], [error()]}
  def scan(%{dir: dir} = root) do
    if File.dir?(dir) do
      dir
      |> File.ls!()
      |> Enum.sort()
      |> Enum.map(&Path.join(dir, &1))
      |> Enum.filter(&File.regular?(Path.join(&1, Parser.file_name())))
      |> Enum.reduce({[], []}, &scan_one(&1, root, &2))
      |> then(fn {s, e} -> {Enum.reverse(s), Enum.reverse(e)} end)
    else
      {[], []}
    end
  end

  defp scan_one(skill_dir, %{source: source, scope: scope}, {skills, errors}) do
    case load(skill_dir) do
      {:ok, skill} -> {[%{skill | source: source, scope: scope} | skills], errors}
      {:error, reason} -> {skills, [%{dir: skill_dir, source: source, reason: reason} | errors]}
    end
  end

  @doc "Parses one skill directory and checks its manifest when it carries one."
  @spec load(Path.t()) :: {:ok, Skill.t()} | {:error, term()}
  def load(skill_dir) do
    with {:ok, skill} <- Parser.parse_dir(skill_dir),
         :ok <- check_manifest(skill) do
      {:ok, skill}
    end
  end

  # sobelow_skip reason: Traversal.FileModule: the manifest read is `skill.path` (a directory the
  # scan found under a root) joined with a constant file name.
  @sobelow_skip ["Traversal.FileModule"]
  defp check_manifest(%Skill{path: dir, manifest: files}) do
    path = Path.join(dir, @manifest_file)

    case File.read(path) do
      {:error, :enoent} ->
        :ok

      {:ok, json} ->
        with {:ok, %{"files" => recorded}} <- decode(json), do: compare(recorded, files)

      {:error, reason} ->
        {:error, {:manifest_unreadable, reason}}
    end
  end

  defp compare(recorded, files) do
    actual = Map.delete(files, @manifest_file)
    bad = for {p, d} <- recorded, Map.get(actual, p) != d, do: p
    missing = for {p, _} <- actual, not Map.has_key?(recorded, p), do: p

    if bad == [] and missing == [],
      do: :ok,
      else:
        {:error, {:manifest_mismatch, %{changed: Enum.sort(bad), unrecorded: Enum.sort(missing)}}}
  end

  defp decode(json) do
    case JSON.decode(json) do
      {:ok, %{"files" => %{}} = m} -> {:ok, m}
      {:ok, _} -> {:error, {:manifest_shape, "a JSON object with a \"files\" map"}}
      {:error, reason} -> {:error, {:manifest_json, reason}}
    end
  end

  defp config(key), do: Application.get_env(:trinity, :skills, []) |> Keyword.get(key)
end
