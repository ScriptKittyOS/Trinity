# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Mix.Tasks.Trinity.Eval.Freeze do
  @shortdoc "Freezes the memory eval's labels by SHA-256, after the audit"

  @moduledoc """
  Slice 133, AC14. Refuses unless `audit-100.md` in the directory has all 100 boxes ticked and
  names who audited it; then writes `labels.sha256`. A scored run refuses labels that no longer
  match it.

      mix trinity.eval.freeze --dir <dir>
  """
  use Boundary, classify_to: Trinity.Eval
  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: [dir: :string])
    dir = opts[:dir] || Mix.raise("--dir <dir> is required")

    case Trinity.Eval.Labels.freeze(dir) do
      {:ok, digest} -> Mix.shell().info("labels frozen: #{digest}  labels.jsonl")
      {:error, reason} -> Mix.raise("refused: #{inspect(reason)}")
    end
  end
end
