# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Archive do
  @moduledoc """
  Export, import, restore (slice 034): the data directory as one gzip tarball a person can
  take to another machine, and back. `export/3` snapshots each database with `VACUUM INTO`
  (consistent, including what the WAL holds, without stopping the app), copies the key
  registry and, only on the explicit flag, the private key files, and writes a manifest with
  a digest per file and the schema versions. `import/3` verifies every digest against the
  tarball's bytes and the schema versions against this binary's migrations before it writes
  anything, refuses a non-empty target unless forced (and then says what it replaced), and
  leaves a `RESTORED` marker naming the archive.

  The layout (`Trinity.Archive.Layout`) is the set of paths by role, derived from a data
  directory or given explicitly, so the same functions serve the mix tasks, the settings
  page and the tests, which work on their own directories.
  """
  use Boundary, deps: [Trinity], exports: [Layout, Manifest]

  alias Trinity.Archive.{Layout, Manifest}

  @marker "RESTORED"

  @type export_result :: %{path: Path.t(), manifest: Manifest.t(), bytes: non_neg_integer()}
  @type import_result :: %{manifest: Manifest.t(), written: [Path.t()], replaced: [Path.t()]}

  @doc """
  Writes the archive at `out`. `opts`: `keys: true` includes the private key files (the
  manifest records the choice either way).
  """
  @spec export(Layout.t(), Path.t(), keyword()) :: {:ok, export_result()} | {:error, term()}
  def export(%Layout{} = layout, out, opts \\ []) do
    keys? = Keyword.get(opts, :keys, false)
    tmp = Path.join(System.tmp_dir!(), "trinity-export-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    try do
      with {:ok, staged} <- stage(layout, tmp, keys?),
           manifest = Manifest.build(staged, schema_versions(layout), keys?),
           :ok <- File.write(Path.join(tmp, Manifest.file_name()), Manifest.encode(manifest)),
           entries = [
             {~c"manifest.json", String.to_charlist(Path.join(tmp, Manifest.file_name()))}
             | staged_entries(staged)
           ],
           :ok <- :erl_tar.create(String.to_charlist(out), entries, [:compressed]) do
        {:ok, %{path: out, manifest: manifest, bytes: File.stat!(out).size}}
      end
    after
      File.rm_rf!(tmp)
    end
  end

  @doc """
  Restores an archive into a layout. `opts`: `force: true` replaces what a non-empty target
  holds (listed in the result). Nothing is written until every digest and the schema versions
  have been checked.
  """
  @spec import(Path.t(), Layout.t(), keyword()) :: {:ok, import_result()} | {:error, term()}
  def import(archive, %Layout{} = layout, opts \\ []) do
    force? = Keyword.get(opts, :force, false)

    with {:ok, entries} <- read_tarball(archive),
         {:ok, manifest} <- Manifest.from_entries(entries),
         :ok <- check_schema(manifest),
         :ok <- Manifest.verify(manifest, entries),
         {:ok, replaced} <- clear_target(layout, force?) do
      written = write_files(manifest, entries, layout)
      File.write!(Path.join(layout.data_dir, @marker), marker(archive, manifest))
      {:ok, %{manifest: manifest, written: written, replaced: replaced}}
    end
  end

  @doc "The digest the manifest uses: SHA-256, lowercase hex."
  @spec digest(binary()) :: String.t()
  def digest(bytes) when is_binary(bytes),
    do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  @doc "A digest over a restored layout's files, by manifest path, to compare with the manifest."
  @spec digest_tree(Layout.t(), Manifest.t()) :: %{String.t() => String.t()}
  def digest_tree(%Layout{} = layout, %Manifest{files: files}) do
    Map.new(files, fn %{"path" => rel} ->
      abs = Layout.absolute(layout, rel)
      {rel, if(File.regular?(abs), do: digest(File.read!(abs)), else: nil)}
    end)
  end

  @doc "The migration versions this binary carries for a repo, from its migration files."
  @spec available_versions(module()) :: [integer()]
  def available_versions(repo) do
    repo
    |> Ecto.Migrator.migrations_path()
    |> Path.join("*.exs")
    |> Path.wildcard()
    |> Enum.map(fn f ->
      f |> Path.basename() |> String.split("_", parts: 2) |> hd() |> String.to_integer()
    end)
    |> Enum.sort()
  end

  @doc "The marker file's name."
  @spec marker_file() :: String.t()
  def marker_file, do: @marker

  ## Export

  # Each database is snapshotted with VACUUM INTO through exqlite directly: no Ecto, no
  # transaction, so it runs beside a live app and inside a test that must see disk.
  defp stage(layout, tmp, keys?) do
    Enum.reduce_while(Layout.sources(layout, keys?), {:ok, []}, fn {rel, abs, kind}, {:ok, acc} ->
      dest = Path.join(tmp, rel)
      File.mkdir_p!(Path.dirname(dest))

      result =
        case kind do
          :sqlite -> snapshot(abs, dest)
          :file -> File.cp(abs, dest)
        end

      case result do
        :ok ->
          {:cont,
           {:ok,
            acc ++
              [
                %{
                  path: rel,
                  staged: dest,
                  bytes: File.stat!(dest).size,
                  sha256: digest(File.read!(dest))
                }
              ]}}

        {:error, reason} ->
          {:halt, {:error, {:stage, rel, reason}}}
      end
    end)
  end

  defp snapshot(src, dest) do
    with {:ok, db} <- Exqlite.Sqlite3.open(src),
         :ok <- Exqlite.Sqlite3.execute(db, "VACUUM INTO '#{String.replace(dest, "'", "''")}'") do
      Exqlite.Sqlite3.close(db)
    end
  end

  defp staged_entries(staged),
    do: Enum.map(staged, &{String.to_charlist(&1.path), String.to_charlist(&1.staged)})

  # The migrated versions of each database, read from the source file itself.
  defp schema_versions(layout) do
    for {name, path, table} <- [
          {"trinity.db", layout.db, "schema_migrations"},
          {"receipts.db", layout.receipts_db, "receipts_schema_migrations"}
        ],
        File.regular?(path),
        into: %{} do
      {name, migrated(path, table)}
    end
  end

  defp migrated(path, table) do
    with {:ok, db} <- Exqlite.Sqlite3.open(path),
         {:ok, st} <- Exqlite.Sqlite3.prepare(db, "SELECT version FROM #{table} ORDER BY version"),
         {:ok, rows} <- Exqlite.Sqlite3.fetch_all(db, st),
         :ok <- Exqlite.Sqlite3.release(db, st),
         :ok <- Exqlite.Sqlite3.close(db) do
      List.flatten(rows)
    else
      _ -> []
    end
  end

  ## Import

  defp read_tarball(archive) do
    case :erl_tar.extract(String.to_charlist(archive), [:compressed, :memory]) do
      {:ok, entries} -> {:ok, Map.new(entries, fn {name, bin} -> {List.to_string(name), bin} end)}
      {:error, reason} -> {:error, {:archive, reason}}
    end
  end

  # A newer archive into an older binary refuses by name; the other way migrates on boot.
  defp check_schema(%Manifest{schema_versions: versions}) do
    binary = %{
      "trinity.db" => available_versions(Trinity.Repo),
      "receipts.db" => available_versions(Trinity.Repo.Receipts)
    }

    newer =
      for {db, archived} <- versions,
          have = Map.get(binary, db, []),
          extra = archived -- have,
          extra != [],
          do: {db, extra}

    if newer == [], do: :ok, else: {:error, {:schema_newer_than_binary, newer}}
  end

  defp clear_target(layout, force?) do
    present = Layout.present(layout)

    cond do
      present == [] -> {:ok, []}
      force? -> Enum.each(present, &File.rm_rf!/1) && {:ok, present}
      true -> {:error, {:not_empty, present}}
    end
  end

  defp write_files(%Manifest{files: files}, entries, layout) do
    for %{"path" => rel} <- files do
      abs = Layout.absolute(layout, rel)
      File.mkdir_p!(Path.dirname(abs))
      File.write!(abs, Map.fetch!(entries, rel))
      if String.starts_with?(rel, "keys/"), do: File.chmod!(abs, 0o600)
      abs
    end
  end

  defp marker(archive, %Manifest{} = m) do
    "restored from #{Path.basename(archive)} (created #{m.created_at}, format #{m.format}, keys #{if m.keys_included, do: "included", else: "not included"}) at #{DateTime.utc_now() |> DateTime.to_iso8601()}\n"
  end
end
