# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Archive.Layout do
  @moduledoc """
  The files of a data directory by role (slice 034): the two databases, the key registry
  and the private key files under `keys/`, and the `skills/` and `personas/` directories
  (empty at this slice; 040 fills skills). `of/1` derives it from a directory; the tests and
  the tasks may give the paths themselves.
  """

  @type t :: %__MODULE__{
          data_dir: Path.t(),
          db: Path.t(),
          receipts_db: Path.t(),
          keys_dir: Path.t(),
          skills_dir: Path.t(),
          personas_dir: Path.t()
        }

  @enforce_keys [:data_dir, :db, :receipts_db, :keys_dir]
  defstruct [:data_dir, :db, :receipts_db, :keys_dir, :skills_dir, :personas_dir]

  @doc "The layout of a data directory."
  @spec of(Path.t()) :: t()
  def of(data_dir) do
    %__MODULE__{
      data_dir: data_dir,
      db: Path.join(data_dir, "trinity.db"),
      receipts_db: Path.join(data_dir, "receipts.db"),
      keys_dir: Path.join(data_dir, "keys"),
      skills_dir: Path.join(data_dir, "skills"),
      personas_dir: Path.join(data_dir, "personas")
    }
  end

  @doc "The running application's layout: its configured databases and keys directory."
  @spec current() :: t()
  def current do
    data_dir = Trinity.Paths.data_dir()

    %__MODULE__{
      data_dir: data_dir,
      db:
        Application.get_env(:trinity, Trinity.Repo)[:database] ||
          Path.join(data_dir, "trinity.db"),
      receipts_db:
        Application.get_env(:trinity, Trinity.Repo.Receipts)[:database] ||
          Path.join(data_dir, "receipts.db"),
      keys_dir:
        Application.get_env(:trinity, :receipts, [])[:keys_dir] || Path.join(data_dir, "keys"),
      skills_dir: Path.join(data_dir, "skills"),
      personas_dir: Path.join(data_dir, "personas")
    }
  end

  @doc """
  What an export takes, as `{archive path, absolute path, kind}`: the databases (`:sqlite`,
  snapshotted), the registry and, with `keys?`, the private key files, and every file under
  `skills/` and `personas/` (`:file`, copied). Only what exists.
  """
  @spec sources(t(), boolean()) :: [{String.t(), Path.t(), :sqlite | :file}]
  def sources(%__MODULE__{} = l, keys?) do
    dbs =
      for {rel, abs} <- [{"trinity.db", l.db}, {"receipts.db", l.receipts_db}],
          File.regular?(abs),
          do: {rel, abs, :sqlite}

    registry = Path.join(l.keys_dir, "registry.json")
    reg = if File.regular?(registry), do: [{"keys/registry.json", registry, :file}], else: []

    keys =
      if keys?,
        do:
          for(
            f <- Path.wildcard(Path.join(l.keys_dir, "receipts-*.key")),
            do: {"keys/" <> Path.basename(f), f, :file}
          ),
        else: []

    dirs =
      for {name, dir} <- [{"skills", l.skills_dir}, {"personas", l.personas_dir}],
          is_binary(dir) and File.dir?(dir),
          f <- Path.wildcard(Path.join(dir, "**/*")),
          File.regular?(f),
          do: {Path.join(name, Path.relative_to(f, dir)), f, :file}

    dbs ++ reg ++ keys ++ dirs
  end

  @doc "The absolute path a manifest path lands at in this layout."
  @spec absolute(t(), String.t()) :: Path.t()
  def absolute(%__MODULE__{} = l, "trinity.db"), do: l.db
  def absolute(%__MODULE__{} = l, "receipts.db"), do: l.receipts_db
  def absolute(%__MODULE__{} = l, "keys/" <> rest), do: Path.join(l.keys_dir, rest)

  def absolute(%__MODULE__{} = l, "skills/" <> rest),
    do: Path.join(l.skills_dir || Path.join(l.data_dir, "skills"), rest)

  def absolute(%__MODULE__{} = l, "personas/" <> rest),
    do: Path.join(l.personas_dir || Path.join(l.data_dir, "personas"), rest)

  def absolute(%__MODULE__{} = l, other), do: Path.join(l.data_dir, other)

  @doc "What is present of this layout (the files and directories an import would replace)."
  @spec present(t()) :: [Path.t()]
  def present(%__MODULE__{} = l) do
    files =
      for p <- [
            l.db,
            l.db <> "-wal",
            l.db <> "-shm",
            l.receipts_db,
            l.receipts_db <> "-wal",
            l.receipts_db <> "-shm"
          ],
          File.regular?(p),
          do: p

    dirs =
      for d <- [l.keys_dir, l.skills_dir, l.personas_dir],
          is_binary(d) and File.dir?(d) and File.ls!(d) != [],
          do: d

    files ++ dirs
  end
end
