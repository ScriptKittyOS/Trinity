# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
#
# Gate 5, throughput (slice 134, AC9): p50 and p95 of an embedding call through Trinity's client
# at batch 1 and batch 32, recorded with no pass mark.
#
#   mix run --no-start scripts/tier3/bench.exs --record <import.json> --fixtures <dir> \
#     [--num-ctx 2048] [--n1 200] [--n32 40]
#
# The texts are the parity fixtures' natural sentences (documents, no template), cycled; each
# call is timed end to end from the client (tokenizing, the request, the answer's checks).
Code.require_file("gate_lib.exs", __DIR__)
{:ok, _} = Application.ensure_all_started(:req)

alias Trinity.Memory.Embedders.Ollama

opts =
  Tier3Gate.args(System.argv(),
    record: :string,
    fixtures: :string,
    num_ctx: :integer,
    n1: :integer,
    n32: :integer,
    base_url: :string
  )

record = Tier3Gate.record!(opts[:record])
num_ctx = Keyword.get(opts, :num_ctx, 2048)
Tier3Gate.configure!(record, num_ctx: num_ctx, base_url: Keyword.get(opts, :base_url, record["ollama"]["base_url"]))
:ok = Ollama.check()

texts =
  Tier3Gate.fixtures(opts[:fixtures], "parity.jsonl")
  |> Enum.filter(&(&1["role"] == "document" and &1["count"] <= 200))
  |> Enum.map(& &1["text"])

tokens = Enum.map(texts, &Trinity.Memory.BPE.count(elem(Ollama.tokenizer(elem(Ollama.config(), 1)), 1), &1))

run = fn batch, n, warm ->
  texts
  |> Stream.cycle()
  |> Stream.chunk_every(batch)
  |> Enum.take(n + warm)
  |> Enum.with_index()
  |> Enum.flat_map(fn {chunk, i} ->
    {us, {:ok, vs}} = :timer.tc(fn -> Ollama.embed(chunk) end)
    true = length(vs) == batch
    if i < warm, do: [], else: [us / 1000]
  end)
end

IO.puts(
  "GATE5 #{record["gguf"]} as #{record["ollama"]["model"]}, Ollama #{record["ollama"]["version"]}, num_ctx #{num_ctx}; " <>
    "#{length(texts)} sentences, #{Enum.min(tokens)} to #{Enum.max(tokens)} tokens (median #{Tier3Gate.percentile(tokens, 50)})"
)

for {batch, n, warm} <- [{1, Keyword.get(opts, :n1, 200), 10}, {32, Keyword.get(opts, :n32, 40), 3}] do
  ms = run.(batch, n, warm)

  IO.puts(
    "  batch #{batch}: #{length(ms)} calls after #{warm} warm-ups, p50 #{Float.round(Tier3Gate.percentile(ms, 50), 1)} ms, " <>
      "p95 #{Float.round(Tier3Gate.percentile(ms, 95), 1)} ms, max #{Float.round(Enum.max(ms), 1)} ms; " <>
      "#{Float.round(batch * 1000 / Tier3Gate.percentile(ms, 50), 1)} texts/s at p50"
  )
end

IO.puts("GATE5 MEASURED (no pass mark)")
IO.puts(Tier3Gate.env_line())
