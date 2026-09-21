# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Mix.Tasks.Trinity.Export do
  @shortdoc "Writes the data directory to one archive (databases, registry, skills; private keys only with --keys)"

  @moduledoc """
  Slice 034 (`docs/backup.md`):

      mix trinity.export --out trinity-2026-09-21.tar.gz
      mix trinity.export --out with-keys.tar.gz --keys

  The databases are snapshotted with `VACUUM INTO`, so a running Trinity is fine. Without
  `--keys` the archive carries the key registry (public) and not the private key files, so it
  can be handed to someone without the ability to sign as you; the manifest records which.
  """
  use Boundary, classify_to: Trinity
  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv, strict: [out: :string, keys: :boolean, data_dir: :string])

    opts = Map.new(opts)

    unless Map.has_key?(opts, :out) do
      Mix.shell().error(
        "usage: mix trinity.export --out <file.tar.gz> [--keys] [--data-dir <dir>]"
      )

      exit({:shutdown, 2})
    end

    Mix.Task.run("app.config")

    layout =
      if d = opts[:data_dir],
        do: Trinity.Archive.Layout.of(d),
        else: Trinity.Archive.Layout.current()

    case Trinity.Archive.export(layout, opts.out, keys: opts[:keys] == true) do
      {:ok, %{manifest: m, bytes: bytes}} ->
        Mix.shell().info(
          "exported #{length(m.files)} files, #{bytes} bytes, keys #{if m.keys_included, do: "included", else: "not included"}: #{opts.out}"
        )

      {:error, reason} ->
        Mix.raise("export failed: #{inspect(reason)}")
    end
  end
end
