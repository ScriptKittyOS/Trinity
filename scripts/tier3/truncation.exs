# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
#
# Gate 2, truncation (slice 134, AC6): against the real service, an input of max tokens + 1 with
# truncate:false returns an error, never a vector.
#
#   mix run --no-start scripts/tier3/truncation.exs --record <import.json> [--num-ctx 512]
#
# "Max tokens" is the most the service accepts at that num_ctx, which on Ollama 0.40.0 is
# num_ctx - 1 (slice 134 NOTES); the script finds the boundary rather than assuming it. Two
# inputs are built to an exact count with Trinity's tokenizer (a repeated word, and natural
# prose): max (expected: a vector, prompt_eval_count = max) and max + 1 (expected: an error and
# no vector with truncate:false). The red is the same max + 1 input with truncate:true and with
# truncate omitted (Ollama's default), which the gate exists because of: a vector comes back.
# Then the same through Trinity's client, whose own limit refuses max + 1 before sending.
Code.require_file("gate_lib.exs", __DIR__)
{:ok, _} = Application.ensure_all_started(:req)

alias Trinity.Memory.BPE
alias Trinity.Memory.Embedders.Ollama

opts = Tier3Gate.args(System.argv(), record: :string, num_ctx: :integer, base_url: :string, prose: :string)
record = Tier3Gate.record!(opts[:record])
num_ctx = Keyword.get(opts, :num_ctx, 512)
base = Keyword.get(opts, :base_url, record["ollama"]["base_url"])
model = record["ollama"]["model"]
{:ok, tok} = record["tokenizer_path"] |> File.read!() |> BPE.from_file()

# Exact-count inputs: n tokens with the end token, from a repeated word and from prose.
repeat = fn n -> String.duplicate(" a", n - 1) end
prose_words = String.split(opts[:prose] || File.read!(Path.join(__DIR__, "../../README.md")))

prose = fn n ->
  Enum.reduce_while(prose_words |> Stream.cycle() |> Enum.take(n * 3), "", fn w, acc ->
    next = if acc == "", do: w, else: acc <> " " <> w
    c = BPE.count(tok, next)

    cond do
      c == n -> {:halt, next}
      c > n -> {:halt, acc <> String.duplicate(" a", n - BPE.count(tok, acc))}
      true -> {:cont, next}
    end
  end)
end

show = fn {status, body} ->
  cond do
    is_map(body) and Map.has_key?(body, "embeddings") ->
      v = hd(body["embeddings"])
      "HTTP #{status}, a vector of #{length(v)}, prompt_eval_count #{body["prompt_eval_count"]}"

    true ->
      "HTTP #{status}, no vector, error #{inspect(body["error"])}"
  end
end

IO.puts("GATE2 #{model} (digest #{record["ollama"]["digest"]}), Ollama #{record["ollama"]["version"]}, num_ctx #{num_ctx}")

# The boundary, found: the largest count answered with truncate:false.
max =
  Enum.find((num_ctx + 1)..(num_ctx - 3)//-1, fn n ->
    match?({200, _}, Tier3Gate.embed_raw(base, model, [repeat.(n)], num_ctx, false))
  end)

IO.puts("  the largest input the service accepts at num_ctx #{num_ctx}: #{max} tokens")

verdicts =
  for {name, build} <- [repeat: repeat, prose: prose] do
    at_max = build.(max)
    over = build.(max + 1)
    IO.puts("  #{name}: Trinity counts #{BPE.count(tok, at_max)} and #{BPE.count(tok, over)}")
    a = Tier3Gate.embed_raw(base, model, [at_max], num_ctx, false)
    b = Tier3Gate.embed_raw(base, model, [over], num_ctx, false)
    red_true = Tier3Gate.embed_raw(base, model, [over], num_ctx, true)
    red_omit = Tier3Gate.embed_raw(base, model, [over], num_ctx, :omit)
    IO.puts("    max (#{max}), truncate:false     -> #{show.(a)}")
    IO.puts("    max + 1 (#{max + 1}), truncate:false -> #{show.(b)}")
    IO.puts("    red: max + 1, truncate:true    -> #{show.(red_true)}")
    IO.puts("    red: max + 1, truncate omitted -> #{show.(red_omit)}")
    {at_status, at_body} = a
    {over_status, over_body} = b

    at_status == 200 and at_body["prompt_eval_count"] == max and over_status != 200 and
      not Map.has_key?(over_body, "embeddings")
  end

# Through Trinity's client, limit max (= num_ctx - 1): max + 1 refused before sending.
Tier3Gate.configure!(record, num_ctx: num_ctx, max_input_tokens: max, base_url: base)
:ok = Ollama.check()
IO.puts("  client, max_input_tokens #{max}: max -> #{inspect(Ollama.embed([repeat.(max)]) |> elem(0))}, max + 1 -> #{inspect(Ollama.embed([repeat.(max + 1)]))}")

IO.puts("GATE2 VERDICT #{if Enum.all?(verdicts), do: "PASS", else: "FAIL"}")
IO.puts(Tier3Gate.env_line())
