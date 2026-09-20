# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Mix.Tasks.Trinity.Receipts.Export do
  @shortdoc "Writes one receipt chain scope, its checkpoints and the key registry to a JSON file"

  @moduledoc """
  Exports a scope for the standalone verifier (slice 024, AC7):

      mix trinity.receipts.export --scope session:<id> --out receipts.json
      mix trinity.receipts.export --scope boot --out boot.json

  The file is `Trinity.Receipts.export/1`'s map: the rows in seq order, the checkpoints and
  the registry, so `bin/verify_receipt.exs` needs nothing else. Exit 2 on usage.
  """
  use Boundary, classify_to: Trinity
  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: [scope: :string, out: :string])

    with {:ok, scope} <- Map.fetch(Map.new(opts), :scope),
         {:ok, out} <- Map.fetch(Map.new(opts), :out) do
      Mix.Task.run("app.start")

      case Trinity.Receipts.export(scope) do
        {:ok, export} ->
          File.write!(out, JSON.encode!(export))

          Mix.shell().info(
            "exported #{length(export["receipts"])} receipts, #{length(export["checkpoints"])} checkpoints of #{scope} to #{out}"
          )

        {:error, reason} ->
          Mix.raise("export failed: #{inspect(reason)}")
      end
    else
      :error ->
        Mix.shell().error("usage: mix trinity.receipts.export --scope <scope> --out <file>")
        exit({:shutdown, 2})
    end
  end
end
