# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
#
# Slice 133, AC13 (D-scoring): the pure-Elixir scorer at 10^4 x 256 dimensions int8, on this
# machine. Over 50 ms p95 opens the scoring-crate slice; the Elixir path stays either way.
#
#   MIX_ENV=test mix run --no-start scripts/scorer_bench.exs
#   TRINITY_STATIC_MODEL_DIR=<dir> MIX_ENV=test mix run --no-start scripts/scorer_bench.exs
#
# With TRINITY_STATIC_MODEL_DIR set, the 10^4 vectors are the static model's own embeddings of
# 10^4 generated memory-shaped sentences (their distribution is what the scorer meets); without
# it, seeded Gaussian vectors quantized the same way. Each figure is one query at a time, 200
# queries after 20 discarded warm-ups, p50 and p95 by sorting the 200 times.
#
# Four scorers over the same rows:
#   exact      the int8 cosine over every row (`Scorer.exact/3` on a prepared index)
#   prefilter  sign bits by Hamming distance, then the exact int8 cosine over the 256 nearest
#              (`Scorer.prefilter/4`): the path D-scoring names
#   prepare    building the prepared index from the rows (norms and sign bits), once per load
#   naive      the deliberately unoptimised scorer: every row's bytes decoded to a list of
#              floats and the float cosine taken, per query, which is the Elixir path slice 032
#              measured at 390 ms over 10^4 x 384 floats. It is here to show the measurement can
#              tell a slow scorer from a fast one (AC13's red).
# And recall@10 of the prefilter against the exact search, since the prefilter is approximate.

alias Trinity.Memory.{Embedder, Scorer}

n = 10_000
queries = 200
warm = 20
candidates = 256

{source, vectors, query_vectors} =
  case System.get_env("TRINITY_STATIC_MODEL_DIR") do
    dir when dir not in [nil, ""] ->
      Application.put_env(:trinity, :memory, embedder: :static, static_dir: dir)
      alias Trinity.Memory.Embedders.Static
      topics = ~w(coffee tea Lisbon Boston sister brother dog cat garden piano budget project Postgres
                  SQLite meeting Tuesday allergy peanuts bicycle river library trip passport doctor)
      verbs = ~w(likes prefers decided remembers mentioned dislikes planned moved bought visited)
      :rand.seed(:exsss, {133, 13, 1})

      sentence = fn ->
        "The person #{Enum.random(verbs)} #{Enum.random(topics)} and #{Enum.random(topics)} " <>
          "on day #{:rand.uniform(365)}."
      end

      {:ok, vs} = Static.embed(for _ <- 1..n, do: sentence.())
      {:ok, qs} = Static.embed(for _ <- 1..(queries + warm), do: sentence.())
      {"static-retrieval-mrl-en-v1 256 int8, generated sentences", vs, qs}

    _ ->
      :rand.seed(:exsss, {133, 13, 2})
      gauss = fn -> for _ <- 1..256, do: :rand.normal() end
      {"seeded Gaussian", for(_ <- 1..n, do: gauss.()), for(_ <- 1..(queries + warm), do: gauss.())}
  end

rows = vectors |> Enum.with_index() |> Enum.map(fn {v, i} -> {i, Scorer.quantize(v)} end)
qs = Enum.map(query_vectors, &Scorer.quantize/1)

{prepare_us, index} = :timer.tc(fn -> Scorer.prepare(rows) end)

time = fn f ->
  all = for q <- qs, do: elem(:timer.tc(fn -> f.(q) end), 0)
  sorted = all |> Enum.drop(warm) |> Enum.sort()
  {Enum.at(sorted, div(queries, 2)) / 1000, Enum.at(sorted, round(queries * 0.95) - 1) / 1000}
end

{exact50, exact95} = time.(fn q -> Scorer.exact(index, q, 10) end)
{pre50, pre95} = time.(fn q -> Scorer.prefilter(index, q, 10, candidates) end)

naive = fn q ->
  qf = Scorer.to_floats(q)

  rows
  |> Enum.map(fn {id, bin} -> {id, Embedder.cosine(qf, for(<<x::signed-8 <- bin>>, do: x * 1.0))} end)
  |> Enum.sort_by(&elem(&1, 1), :desc)
  |> Enum.take(10)
end

{naive50, naive95} = time.(naive)

recall =
  qs
  |> Enum.drop(warm)
  |> Enum.map(fn q ->
    exact = q |> then(&Scorer.exact(index, &1, 10)) |> MapSet.new(&elem(&1, 0))
    pre = q |> then(&Scorer.prefilter(index, &1, 10, candidates)) |> MapSet.new(&elem(&1, 0))
    MapSet.size(MapSet.intersection(exact, pre)) / 10
  end)
  |> then(&(Enum.sum(&1) / length(&1)))

IO.puts("""
scorer bench: #{n} rows x 256 int8 (#{source}); #{queries} queries after #{warm} warm-ups
  exact      p50 #{exact50} ms  p95 #{exact95} ms
  prefilter  p50 #{pre50} ms  p95 #{pre95} ms  (#{candidates} candidates; recall@10 against exact #{Float.round(recall, 4)})
  prepare    #{div(prepare_us, 1000)} ms once per load (norms and sign bits for #{n} rows)
  naive      p50 #{naive50} ms  p95 #{naive95} ms  (decode to floats per query: the red)
  budget     50 ms p95: exact #{if exact95 <= 50, do: "within", else: "OVER"}, prefilter #{if pre95 <= 50, do: "within", else: "OVER"}, naive #{if naive95 <= 50, do: "within", else: "OVER"}
otp #{System.otp_release()} erts #{:erlang.system_info(:version)} elixir #{System.version()} schedulers #{System.schedulers_online()}
""")
