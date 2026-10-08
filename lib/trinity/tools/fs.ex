# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Tools.FS do
  @moduledoc """
  What the filesystem tools share (docs/07, filesystem). Slice 022.

  **Roots.** A path is inside the allowlist when it is under one of `config :trinity, :fs,
  roots:` or the folders chosen in Settings, or under the session's working directory. A read
  outside the roots is not a failure but an `:ask` (022 AC1): the tool escalates and the gate
  decides. A write outside the roots asks the same way. Since slice 135 the data directory is not a
  root, and `Trinity.Tools.FS.Guard` judges every path first: a symlink, `/proc`, `/dev`, the data
  or secrets directory, a protected inode, a hard link and the deny-list are refused outright.

  **Backups.** Before a write or an edit, the file's current bytes go to
  `<data dir>/backups/<sha256 of the path>/<utc stamp>` and the ring keeps the last five;
  `restore/2` puts a backup back through the same atomic write.

  **Atomic writes.** A temporary file beside the target, then `File.rename/2`.
  """

  alias Trinity.Tools.FS.Guard

  @backup_ring 5

  # Sobelow reads `@sobelow_skip` from the source; the compiler would call it unused (the
  # measure `Trinity.Paths` takes).
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @doc """
  The roots in force, canonical: `config :trinity, :fs, roots:` and the folders the owner chose in
  Settings (slice 100, `:fs_roots`). Since slice 135 the data directory is not one, and a root that
  is, contains or sits inside the data or secrets directory is not one either
  (`Trinity.Tools.FS.Guard`).
  """
  @spec roots() :: [String.t()]
  def roots, do: Guard.roots()

  @doc """
  The canonical path for `path` (relative to `cwd`) used as `mode`, and whether it lies inside the
  roots or `cwd`; or the guard's refusal (`Trinity.Tools.FS.Guard.check/4`). A path that does not
  exist yet is judged through its nearest existing ancestor, so a new file's directory decides.
  """
  @spec resolve(String.t(), String.t() | nil, Guard.mode()) ::
          {:ok, String.t(), :inside | :outside} | {:error, {:fs_denied, Guard.verdict()}}
  def resolve(path, cwd, mode \\ :read) do
    case Guard.check(path, cwd, mode) do
      %{decision: :deny} = v -> {:error, {:fs_denied, v}}
      %{decision: :allow, canonical: c} -> {:ok, c, :inside}
      %{decision: :ask, canonical: c} -> {:ok, c, :outside}
    end
  end

  @doc """
  The escalation a path-taking tool asks for (slice 022): none inside the roots, `:ask` outside
  them. A refused path asks too, which never matters: the runner denies a refused path before the
  policy is consulted (`Trinity.Tools.Runner.decide/3`), and so does the tool at execution.
  """
  @spec escalation(String.t(), String.t() | nil, Guard.mode()) :: :ask | nil
  def escalation(path, cwd, mode \\ :read) do
    case resolve(path, cwd, mode) do
      {:ok, _, :inside} -> nil
      _ -> :ask
    end
  end

  @doc "True when `path` is `root` or under it."
  @spec under?(String.t(), String.t()) :: boolean()
  defdelegate under?(path, root), to: Guard

  # sobelow_skip reason: Traversal.FileModule fires on every File call whose path is a variable,
  # and a filesystem tool's path is the model's argument by design. The control is not the
  # path's shape but the gate: `Trinity.Tools.FS.Guard` judges every path (no symlink
  # followed, protected directories and inodes refused) against the roots and the tools
  # escalate anything outside to `:ask` (docs/07, filesystem; slice 022 AC1), and a write is
  # atomic with a backup. Scoped to the function rather than .sobelow-skips, which keys on file
  # and line.
  @sobelow_skip ["Traversal.FileModule"]
  @doc "Writes `content` to `path` atomically: a temporary file beside it, then a rename."
  @spec atomic_write(String.t(), binary()) :: :ok | {:error, File.posix()}
  def atomic_write(path, content) do
    dir = Path.dirname(path)
    tmp = Path.join(dir, ".#{Path.basename(path)}.#{System.unique_integer([:positive])}.tmp")

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(tmp, content),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, reason}
    end
  end

  @doc "The directory holding a file's backups."
  @spec backup_dir(String.t()) :: String.t()
  def backup_dir(path) do
    Path.join([
      Trinity.Paths.data_dir(),
      "backups",
      :crypto.hash(:sha256, path) |> Base.encode16(case: :lower)
    ])
  end

  # sobelow_skip reason: Traversal.FileModule fires on every File call whose path is a variable,
  # and a filesystem tool's path is the model's argument by design. The control is not the
  # path's shape but the gate: `Trinity.Tools.FS.Guard` judges every path (no symlink
  # followed, protected directories and inodes refused) against the roots and the tools
  # escalate anything outside to `:ask` (docs/07, filesystem; slice 022 AC1), and a write is
  # atomic with a backup. Scoped to the function rather than .sobelow-skips, which keys on file
  # and line.
  @sobelow_skip ["Traversal.FileModule"]
  @doc "Copies the file's current bytes into its ring, keeping the last five; nothing for a new file."
  @spec backup(String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def backup(path) do
    if File.regular?(path) do
      dir = backup_dir(path)

      stamp =
        DateTime.utc_now() |> DateTime.to_iso8601(:basic) |> String.replace(~r/[^0-9TZ]/, "")

      target =
        Path.join(dir, stamp <> "-" <> Integer.to_string(System.unique_integer([:positive])))

      with :ok <- File.mkdir_p(dir),
           {:ok, _} <- File.copy(path, target) do
        prune(dir)
        {:ok, target}
      end
    else
      {:ok, nil}
    end
  end

  @doc "The file's backups, newest first."
  @spec backups(String.t()) :: [String.t()]
  def backups(path) do
    dir = backup_dir(path)

    case File.ls(dir) do
      {:ok, names} -> names |> Enum.sort(:desc) |> Enum.map(&Path.join(dir, &1))
      _ -> []
    end
  end

  @doc "Restores the newest backup (or the one at `which`, 0 the newest) through an atomic write, backing up the current file first."
  @spec restore(String.t(), non_neg_integer()) ::
          {:ok, String.t()} | {:error, :no_backup | term()}
  # sobelow_skip reason: Traversal.FileModule fires on every File call whose path is a variable,
  # and a filesystem tool's path is the model's argument by design. The control is not the
  # path's shape but the gate: `Trinity.Tools.FS.Guard` judges every path (no symlink
  # followed, protected directories and inodes refused) against the roots and the tools
  # escalate anything outside to `:ask` (docs/07, filesystem; slice 022 AC1), and a write is
  # atomic with a backup. Scoped to the function rather than .sobelow-skips, which keys on file
  # and line.
  @sobelow_skip ["Traversal.FileModule"]
  def restore(path, which \\ 0) do
    case Enum.at(backups(path), which) do
      nil ->
        {:error, :no_backup}

      backup ->
        with {:ok, bytes} <- File.read(backup),
             {:ok, _} <- backup(path),
             :ok <- atomic_write(path, bytes) do
          {:ok, backup}
        end
    end
  end

  # sobelow_skip reason: Traversal.FileModule fires on every File call whose path is a variable,
  # and a filesystem tool's path is the model's argument by design. The control is not the
  # path's shape but the gate: `Trinity.Tools.FS.Guard` judges every path (no symlink
  # followed, protected directories and inodes refused) against the roots and the tools
  # escalate anything outside to `:ask` (docs/07, filesystem; slice 022 AC1), and a write is
  # atomic with a backup. Scoped to the function rather than .sobelow-skips, which keys on file
  # and line.
  @sobelow_skip ["Traversal.FileModule"]
  defp prune(dir) do
    dir
    |> File.ls!()
    |> Enum.sort(:desc)
    |> Enum.drop(@backup_ring)
    |> Enum.each(&File.rm(Path.join(dir, &1)))
  end
end
