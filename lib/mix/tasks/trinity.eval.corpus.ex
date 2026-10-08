# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Mix.Tasks.Trinity.Eval.Corpus do
  @shortdoc "Generates the memory eval's corpus, queries, labels and audit sample"

  @moduledoc """
  Slice 133, AC14. Writes the eval directory from a seed: `corpus.jsonl` (10^4 memories, the
  10^2 and 10^3 corpora their prefixes), `queries.jsonl` (300), `labels.jsonl`, `generation.json`
  and `audit-100.md`. Offline and deterministic: the same seed writes the same bytes.

      mix trinity.eval.corpus --out <dir> [--seed 20261007]

  Next: the owner audits `audit-100.md`, then `mix trinity.eval.freeze --dir <dir>`; only then
  will `mix trinity.eval.memory` score anything.
  """
  use Boundary, classify_to: Trinity.Eval
  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: [out: :string, seed: :integer])
    dir = opts[:out] || Mix.raise("--out <dir> is required")
    seed = opts[:seed] || 20_261_007
    record = Trinity.Eval.Labels.write!(dir, seed)
    audit = Trinity.Eval.Labels.write_audit!(dir, seed)
    Mix.shell().info(Jason.encode!(record, pretty: true))
    Mix.shell().info("audit sample: #{audit}")
  end
end
