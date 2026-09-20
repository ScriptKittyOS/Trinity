# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Mix.Tasks.Trinity.Receipts.Verify do
  @shortdoc "Verifies a receipt chain scope, or an exported file, with the exit vocabulary"

  @moduledoc """
  Runs `Trinity.Receipts.Verifier` over a scope in the database or over an exported file
  (slice 024):

      mix trinity.receipts.verify --scope session:<id>
      mix trinity.receipts.verify --file receipts.json

  Exit codes, the same vocabulary as `bin/verify_receipt.exs`: 0 verified, 1 invalid,
  2 usage, 5 trust not established (a key id the registry does not know), 6 compromised key.
  """
  use Boundary, classify_to: Trinity
  use Mix.Task

  alias Trinity.Receipts.Verifier

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: [scope: :string, file: :string])
    opts = Map.new(opts)

    export =
      cond do
        Map.has_key?(opts, :file) ->
          opts.file |> File.read!() |> JSON.decode!()

        Map.has_key?(opts, :scope) ->
          Mix.Task.run("app.start")
          {:ok, export} = Trinity.Receipts.export(opts.scope)
          export

        true ->
          Mix.shell().error("usage: mix trinity.receipts.verify --scope <scope> | --file <file>")
          exit({:shutdown, 2})
      end

    outcome = Verifier.verify(export)
    code = Verifier.exit_code(outcome)

    case outcome do
      {:ok, %{receipts: n, checkpoints: c}} ->
        Mix.shell().info("verified: #{n} receipts, #{c} checkpoints, exit #{code}")

      {:error, ^code, reason} ->
        Mix.shell().error("#{label(code)}: #{inspect(reason)}, exit #{code}")
    end

    if code != 0, do: exit({:shutdown, code})
  end

  defp label(1), do: "invalid"
  defp label(5), do: "trust not established"
  defp label(6), do: "compromised key"
end
