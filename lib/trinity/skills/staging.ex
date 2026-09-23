# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Skills.Staging do
  @moduledoc """
  The proposer (slice 041): every change to a skill is staged as the whole target tree as it
  would be after the change, under `<data dir>/pending/skills/<name>/<change id>/`, with a
  unified diff against the skill as it is, the scanner's findings and a `skill_changes` row.
  Nothing here writes anywhere but the pending directory (the census, AC8, holds it to that),
  and the pending directory is outside every root the registry scans, so a staged skill
  never loads until `Trinity.Skills.Promotion` moves it, and only with an approval.

  Actions: `create` (a new skill: `SKILL.md` and optional `files`), `patch` (a unified diff or
  a whole-body replace of `SKILL.md`, the replace tagged destructive), `write_file` (one file
  under the skill, added or replaced), `remove_file`, `delete` (the whole skill: destructive).
  """

  import Ecto.Query

  alias Trinity.Repo
  alias Trinity.Skills.{Change, Diff, Parser, Scanner, Sources}

  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @delete_marker ".trinity-delete"

  @doc "The pending root in force (`config :trinity, :skills, pending_dir:`; the data directory's `pending/skills`)."
  @spec pending_dir() :: Path.t()
  def pending_dir do
    Application.get_env(:trinity, :skills, [])[:pending_dir] ||
      Path.join(Trinity.Paths.data_dir(), "pending/skills")
  end

  @doc "The marker file a staged delete carries."
  @spec delete_marker() :: String.t()
  def delete_marker, do: @delete_marker

  @doc """
  Stages a change. `args` by action: `create` needs `"skill_md"` and may carry `"files"`
  (a map of relative path to content); `patch` needs `"diff"` (a unified diff of `SKILL.md`)
  or `"skill_md"` (a replace); `write_file` needs `"path"` and `"content"`; `remove_file`
  needs `"path"`; `delete` needs nothing. `opts`: `rationale:`, `proposed_by:` (a session id).
  """
  @spec propose(String.t(), String.t(), map(), keyword()) :: {:ok, Change.t()} | {:error, term()}
  def propose(action, name, args, opts \\ [])
      when action in ~w(create patch write_file remove_file delete) do
    with :ok <- valid_name(name),
         :ok <- not_already_proposed(action, name),
         {:ok, current} <- current_tree(name, action),
         {:ok, tree, destructive?} <- next_tree(action, current, args),
         :ok <- valid_result(action, name, tree) do
      id = Trinity.UUID.generate()
      dir = Path.join([pending_dir(), name, id])
      write_tree!(dir, tree)
      findings = Scanner.scan_dir(dir)

      attrs = %{
        skill_name: name,
        action: action,
        source: "user",
        change_dir: dir,
        diff: render_diff(current, tree, name),
        rationale: to_string(Keyword.get(opts, :rationale, "")),
        destructive: destructive?,
        digest: digest(dir),
        status: "pending",
        severity: Scanner.severity(findings),
        findings: %{
          "findings" => Enum.map(findings, &Map.new(&1, fn {k, v} -> {Atom.to_string(k), v} end))
        },
        proposed_by: Keyword.get(opts, :proposed_by)
      }

      %Change{id: id} |> Change.changeset(attrs) |> Repo.insert()
    end
  end

  @doc "Pending changes, oldest first; `status:` for another status; `name:` for one skill."
  @spec list(keyword()) :: [Change.t()]
  def list(opts \\ []) do
    status = Keyword.get(opts, :status, "pending")

    from(c in Change, where: c.status == ^status, order_by: c.inserted_at)
    |> then(fn q -> if n = opts[:name], do: where(q, [c], c.skill_name == ^n), else: q end)
    |> Repo.all()
  end

  @doc "A change by id."
  @spec get(String.t()) :: Change.t() | nil
  def get(id), do: Repo.get(Change, id)

  @doc "The SHA-256 over a tree: every regular file's relative path and bytes, sorted; the promotion recomputes it."
  @spec digest(Path.t()) :: String.t()
  # sobelow_skip reason: Traversal.FileModule: the walk reads under the pending directory the
  # staging built (or a skill root the promotion checks); the paths are Path.wildcard's.
  @sobelow_skip ["Traversal.FileModule"]
  def digest(dir) do
    dir = Path.expand(dir)

    dir
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
    |> Enum.reduce(:crypto.hash_init(:sha256), fn path, acc ->
      rel = Path.relative_to(path, dir)

      acc
      |> :crypto.hash_update(rel <> "\0")
      |> :crypto.hash_update(File.read!(path))
      |> :crypto.hash_update("\0")
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  @doc "The staged tree of a change as a map of relative path to bytes (the delete marker included)."
  @spec read_tree(Path.t()) :: %{String.t() => binary()}
  # sobelow_skip reason: Traversal.FileModule: reads under a change directory the staging built.
  @sobelow_skip ["Traversal.FileModule"]
  def read_tree(dir) do
    dir = Path.expand(dir)

    dir
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Map.new(fn p ->
      {:ok, content} = Trinity.Vault.open(File.read!(p))
      {Path.relative_to(p, dir), content}
    end)
  end

  @doc "Removes a change's staged files (a rejection, or after a promotion)."
  @spec discard(Change.t()) :: :ok
  # sobelow_skip reason: Traversal.FileModule: the directory removed is the row's `change_dir`,
  # which this module wrote under the pending root, and it is checked to be under it first.
  @sobelow_skip ["Traversal.FileModule"]
  def discard(%Change{change_dir: dir}) do
    root = Path.expand(pending_dir())
    if String.starts_with?(Path.expand(dir), root <> "/"), do: File.rm_rf!(dir)
    :ok
  end

  ## The next tree

  # One pending create per name: a second proposal of the same new skill waits for the first.
  defp not_already_proposed("create", name) do
    if Enum.any?(list(name: name), &(&1.action == "create")),
      do: {:error, {:pending, name}},
      else: :ok
  end

  defp not_already_proposed(_action, _name), do: :ok

  defp valid_name(name) do
    if Regex.match?(~r/^[a-z0-9]+(-[a-z0-9]+)*$/, name) and String.length(name) <= 64,
      do: :ok,
      else: {:error, {:name, "lowercase a-z, 0-9 and single hyphens, at most 64"}}
  end

  # The skill as it is in the user root (the target), as a tree; `create` needs it absent.
  defp current_tree(name, action) do
    dir = Path.join(Sources.user_dir(), name)

    case {File.dir?(dir), action} do
      {true, "create"} -> {:error, {:exists, name}}
      {false, "create"} -> {:ok, %{}}
      {false, _} -> {:error, {:no_such_skill, name}}
      {true, _} -> {:ok, read_tree(dir)}
    end
  end

  defp next_tree("create", _current, %{"skill_md" => md} = args) when is_binary(md) do
    files =
      for {p, c} <- Map.get(args, "files", %{}), is_binary(p), is_binary(c), into: %{}, do: {p, c}

    with :ok <- valid_paths(Map.keys(files)), do: {:ok, Map.put(files, "SKILL.md", md), false}
  end

  defp next_tree("create", _, _), do: {:error, {:args, "create needs skill_md"}}

  defp next_tree("patch", current, %{"skill_md" => md}) when is_binary(md),
    do: {:ok, Map.put(current, "SKILL.md", md), true}

  defp next_tree("patch", current, %{"diff" => diff}) when is_binary(diff) do
    with {:ok, patched} <- apply_diff(Map.get(current, "SKILL.md", ""), diff),
         do: {:ok, Map.put(current, "SKILL.md", patched), false}
  end

  defp next_tree("patch", _, _), do: {:error, {:args, "patch needs diff or skill_md"}}

  defp next_tree("write_file", current, %{"path" => path, "content" => content})
       when is_binary(path) and is_binary(content) do
    with :ok <- valid_paths([path]),
         do: {:ok, Map.put(current, path, content), Map.has_key?(current, path)}
  end

  defp next_tree("write_file", _, _), do: {:error, {:args, "write_file needs path and content"}}

  defp next_tree("remove_file", current, %{"path" => path}) when is_binary(path) do
    cond do
      path == "SKILL.md" -> {:error, {:args, "SKILL.md cannot be removed; delete the skill"}}
      not Map.has_key?(current, path) -> {:error, {:no_such_file, path}}
      true -> {:ok, Map.delete(current, path), false}
    end
  end

  defp next_tree("remove_file", _, _), do: {:error, {:args, "remove_file needs path"}}
  defp next_tree("delete", _current, _), do: {:ok, %{@delete_marker => "delete\n"}, true}

  defp valid_paths(paths) do
    bad =
      Enum.find(paths, fn p ->
        p == "" or String.starts_with?(p, "/") or String.contains?(p, "..") or
          String.contains?(p, "\\") or String.starts_with?(p, ".trinity")
      end)

    if bad, do: {:error, {:path, bad}}, else: :ok
  end

  # The result must be a skill the parser accepts (a delete excepted), so a bad proposal is
  # refused here rather than at promotion.
  defp valid_result("delete", _name, _tree), do: :ok

  defp valid_result(_action, name, tree) do
    case Parser.parse(Map.get(tree, "SKILL.md", ""), name) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:invalid_skill, reason}}
    end
  end

  # A unified diff as `Trinity.Skills.Diff` writes it (or any with the same line marks), applied
  # to the current text; refused when a context or removed line is not where it says.
  defp apply_diff(current, diff) do
    lines = String.split(current, "\n")

    ops =
      diff
      |> String.split("\n")
      |> Enum.reject(
        &(String.starts_with?(&1, "---") or String.starts_with?(&1, "+++") or
            String.starts_with?(&1, "@@"))
      )
      |> Enum.map(fn
        " " <> l -> {:eq, l}
        "-" <> l -> {:del, l}
        "+" <> l -> {:add, l}
        "" -> {:eq, ""}
        other -> {:bad, other}
      end)

    case Enum.find(ops, &match?({:bad, _}, &1)) do
      {:bad, l} -> {:error, {:diff, "unreadable line: #{inspect(l)}"}}
      nil -> replay(ops, lines, [])
    end
  end

  defp replay([], rest, acc), do: {:ok, Enum.join(Enum.reverse(acc) ++ rest, "\n")}
  defp replay([{:add, l} | ops], rest, acc), do: replay(ops, rest, [l | acc])
  defp replay([{:eq, l} | ops], [l | rest], acc), do: replay(ops, rest, [l | acc])
  defp replay([{:del, l} | ops], [l | rest], acc), do: replay(ops, rest, acc)

  defp replay([{op, l} | _], _rest, _acc),
    do: {:error, {:diff, "#{op} of #{inspect(l)} does not match the skill as it is"}}

  ## Rendering and writing

  defp render_diff(current, tree, name) do
    paths = (Map.keys(current) ++ Map.keys(tree)) |> Enum.uniq() |> Enum.sort()

    Enum.map_join(paths, "\n", fn p ->
      a = Map.get(current, p, "")
      b = Map.get(tree, p, "")

      cond do
        a == b ->
          ""

        p == @delete_marker ->
          "--- #{name}/\n+++ (deleted)\n"

        not Diff.text?(a) or not Diff.text?(b) ->
          "--- #{name}/#{p}\n+++ #{name}/#{p}\n(replaced, #{byte_size(b)} bytes; not text or too large to diff)\n"

        true ->
          Diff.unified(a, b, "#{name}/#{p}", "#{name}/#{p}")
      end
    end)
    |> String.trim()
  end

  # sobelow_skip reason: Traversal.FileModule: the writes land under `dir`, a fresh directory
  # under the pending root with a generated id; the relative paths were checked by valid_paths/1.
  @sobelow_skip ["Traversal.FileModule"]
  defp write_tree!(dir, tree) do
    File.mkdir_p!(dir)

    for {rel, content} <- tree do
      path = Path.join(dir, rel)
      File.mkdir_p!(Path.dirname(path))
      # Slice 025: staged changes are one of the blob classes the vault can seal. Sealing is off
      # unless a deployment turns it on, and `read_tree/1` opens either kind, so this is the only
      # place that has to know.
      File.write!(path, Trinity.Vault.maybe_seal!(content, :staged_skills))
    end

    :ok
  end
end
