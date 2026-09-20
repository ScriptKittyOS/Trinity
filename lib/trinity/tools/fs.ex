# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Tools.FS do
  @moduledoc """
  What the filesystem tools share (docs/07, filesystem). Slice 022.

  **Roots.** A path is inside the allowlist when, after normalisation and symlink resolution,
  it is under one of `config :trinity, :fs, roots:` (the data directory is always one) or
  under the session's working directory. A read outside the roots is not a failure but an
  `:ask` (022 AC1): the tool escalates and the gate decides. A write outside the roots asks
  the same way.

  **Backups.** Before a write or an edit, the file's current bytes go to
  `<data dir>/backups/<sha256 of the path>/<utc stamp>` and the ring keeps the last five;
  `restore/2` puts a backup back through the same atomic write.

  **Atomic writes.** A temporary file beside the target, then `File.rename/2`.
  """

  @backup_ring 5

  # Sobelow reads `@sobelow_skip` from the source; the compiler would call it unused (the
  # measure `Trinity.Paths` takes).
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @doc "The configured roots plus the data directory, each expanded."
  @spec roots() :: [String.t()]
  def roots do
    configured = Application.get_env(:trinity, :fs, []) |> Keyword.get(:roots, [])
    Enum.map([Trinity.Paths.data_dir() | configured], &Path.expand/1) |> Enum.uniq()
  end

  @doc """
  The absolute, symlink-resolved path for `path` (relative to `cwd`), and whether it lies
  inside the roots or `cwd`. A path that does not exist yet is resolved through its nearest
  existing ancestor, so a new file's directory decides.
  """
  @spec resolve(String.t(), String.t() | nil) :: {:ok, String.t(), :inside | :outside}
  def resolve(path, cwd) do
    base = cwd || File.cwd!()
    absolute = Path.expand(path, base)
    real = realpath(absolute)
    allowed = if cwd, do: [Path.expand(cwd) | roots()], else: roots()
    inside? = Enum.any?(allowed, &under?(real, &1))
    {:ok, real, if(inside?, do: :inside, else: :outside)}
  end

  @doc "True when `path` is `root` or under it."
  @spec under?(String.t(), String.t()) :: boolean()
  def under?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  # Follows symlinks on the longest existing prefix, then appends the rest.
  defp realpath(absolute) do
    {existing, rest} = split_existing(absolute, [])

    resolved =
      case existing do
        nil -> "/"
        dir -> resolve_links(dir)
      end

    Path.join([resolved | rest])
  end

  defp split_existing("/", rest), do: {"/", rest}

  defp split_existing(path, rest) do
    if File.exists?(path) do
      {path, rest}
    else
      split_existing(Path.dirname(path), [Path.basename(path) | rest])
    end
  end

  defp resolve_links(path) do
    case :file.read_link_all(String.to_charlist(path)) do
      {:ok, target} ->
        target |> List.to_string() |> Path.expand(Path.dirname(path)) |> resolve_links()

      _ ->
        parent = Path.dirname(path)

        if parent == path,
          do: path,
          else: Path.join(resolve_links(parent), Path.basename(path))
    end
  end

  # sobelow_skip reason: Traversal.FileModule fires on every File call whose path is a variable,
  # and a filesystem tool's path is the model's argument by design. The control is not the
  # path's shape but the gate: `Trinity.Tools.FS.resolve/2` judges every path after symlink
  # resolution against the roots and the tools escalate anything outside to `:ask` (docs/07,
  # filesystem; slice 022 AC1), and a write is atomic with a backup. Scoped to the function
  # rather than .sobelow-skips, which keys on file and line.
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
  # path's shape but the gate: `Trinity.Tools.FS.resolve/2` judges every path after symlink
  # resolution against the roots and the tools escalate anything outside to `:ask` (docs/07,
  # filesystem; slice 022 AC1), and a write is atomic with a backup. Scoped to the function
  # rather than .sobelow-skips, which keys on file and line.
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
  # path's shape but the gate: `Trinity.Tools.FS.resolve/2` judges every path after symlink
  # resolution against the roots and the tools escalate anything outside to `:ask` (docs/07,
  # filesystem; slice 022 AC1), and a write is atomic with a backup. Scoped to the function
  # rather than .sobelow-skips, which keys on file and line.
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
  # path's shape but the gate: `Trinity.Tools.FS.resolve/2` judges every path after symlink
  # resolution against the roots and the tools escalate anything outside to `:ask` (docs/07,
  # filesystem; slice 022 AC1), and a write is atomic with a backup. Scoped to the function
  # rather than .sobelow-skips, which keys on file and line.
  @sobelow_skip ["Traversal.FileModule"]
  defp prune(dir) do
    dir
    |> File.ls!()
    |> Enum.sort(:desc)
    |> Enum.drop(@backup_ring)
    |> Enum.each(&File.rm(Path.join(dir, &1)))
  end
end
