# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Mix.Tasks.Trinity.Import do
  @shortdoc "Restores an archive into an empty data directory (or replaces one with --force)"

  @moduledoc """
  Slice 034 (`docs/backup.md`):

      mix trinity.import trinity-2026-09-21.tar.gz
      mix trinity.import trinity-2026-09-21.tar.gz --force
      mix trinity.import trinity-2026-09-21.tar.gz --data-dir /path/to/dir

  Stop Trinity first: the task refuses while a live process holds the data directory's lock.
  Every digest in the manifest is verified and the schema versions are checked against this
  binary before anything is written; a non-empty directory is refused unless `--force`, and
  then the task prints what it replaced. Exit 2 on usage, 1 on refusal.
  """
  use Boundary, classify_to: Trinity
  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    {opts, args, _} = OptionParser.parse(argv, strict: [force: :boolean, data_dir: :string])

    case args do
      [archive] ->
        Mix.Task.run("app.config")

        layout =
          if d = opts[:data_dir],
            do: Trinity.Archive.Layout.of(d),
            else: Trinity.Archive.Layout.current()

        case Trinity.DataDir.Lock.live_holder(layout.data_dir) do
          {:ok, %{pid: pid, mode: mode}} ->
            Mix.shell().error(
              "refused: a #{mode} Trinity (OS pid #{pid}) holds #{layout.data_dir}; stop it first"
            )

            exit({:shutdown, 1})

          :none ->
            import_into(archive, layout, opts[:force] == true)
        end

      _ ->
        Mix.shell().error("usage: mix trinity.import <file.tar.gz> [--force] [--data-dir <dir>]")
        exit({:shutdown, 2})
    end
  end

  defp import_into(archive, layout, force?) do
    File.mkdir_p!(layout.data_dir)

    case Trinity.Archive.import(archive, layout, force: force?) do
      {:ok, %{manifest: m, written: written, replaced: replaced}} ->
        Enum.each(replaced, &Mix.shell().info("replaced #{&1}"))

        Mix.shell().info(
          "restored #{length(written)} files from #{archive} (created #{m.created_at}, keys #{if m.keys_included, do: "included", else: "not included"}) into #{layout.data_dir}"
        )

      {:error, {:not_empty, present}} ->
        Mix.shell().error(
          "refused: #{layout.data_dir} is not empty (#{Enum.join(present, ", ")}); --force replaces them"
        )

        exit({:shutdown, 1})

      {:error, reason} ->
        Mix.shell().error("refused: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end
end
