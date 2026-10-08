# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Mix.Tasks.Trinity.Eval.Memory do
  @shortdoc "Scores the memory eval (refuses until its labels are frozen)"

  @moduledoc """
  Slice 133, AC14: the scored run. Refuses a directory whose labels are not frozen or have
  changed since. Writes `results.json` beside them and prints the verdict against the threshold
  slice 133 set in advance.

      TRINITY_STATIC_MODEL_DIR=<dir> mix trinity.eval.memory --dir <dir> \\
        [--vectors <dir>] [--sizes 100,1000,10000] [--resamples 10000] [--only fts5,static-256-int8]

  The default candidates are `Trinity.Eval.MemoryRun.default_candidates/0`: MiniLM and
  potion-retrieval-32M from vectors `scripts/eval/reference_vectors.py` wrote into `<dir>/vectors`.
  """
  use Boundary, classify_to: Trinity.Eval
  use Mix.Task

  alias Trinity.Eval.MemoryRun

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [
          dir: :string,
          sizes: :string,
          resamples: :integer,
          only: :string,
          vectors: :string
        ]
      )

    dir = opts[:dir] || Mix.raise("--dir <dir> is required")
    Mix.Task.run("app.config")

    candidates =
      case opts[:only] do
        nil ->
          MemoryRun.default_candidates()

        names ->
          Enum.filter(MemoryRun.default_candidates(), &(elem(&1, 0) in String.split(names, ",")))
      end

    run_opts =
      [candidates: candidates]
      |> put_opt(
        :sizes,
        opts[:sizes] && Enum.map(String.split(opts[:sizes], ","), &String.to_integer/1)
      )
      |> put_opt(:resamples, opts[:resamples])
      |> put_opt(:vectors_dir, opts[:vectors])

    case MemoryRun.run(dir, run_opts) do
      {:ok, results} -> Mix.shell().info(Jason.encode!(results["verdict"], pretty: true))
      {:error, reason} -> Mix.raise("refused: #{inspect(reason)}")
    end
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
