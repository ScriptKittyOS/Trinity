# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Eval.MemoryRun do
  @moduledoc """
  The scored run of the memory-recall eval (slice 133, AC14). **It refuses to run until the
  labels are frozen** (`Trinity.Eval.Labels.verify/1`): the owner audits 100 labels first, and a
  run against labels that moved afterwards measures nothing anyone agreed to.

  Each candidate is a dense leg fused with the full-text leg by reciprocal rank (k = 60,
  `Trinity.Memory.Retriever.rrf/1`), and on its own for diagnosis; `fts5` is the full-text leg
  alone. The legs are Trinity's own:

  * **Full text**: an FTS5 table (`porter unicode61`, as `messages_fts`) over the corpus, queried
    as `Trinity.Memory.Search` queries: the query's words (`Search.terms/1`), each quoted, all
    required, ordered by `bm25()`. The retriever hands its search the person's whole message, and
    so does this.
  * **Dense**: the query's cosine with every memory of the corpus size, exact; the candidate's own
    floor applied as the retriever applies it (`thresholds/0`'s `floor`). An int8 space is scored
    by `Trinity.Memory.Scorer`, as the store scores it.

  Recency decay is left out: the synthetic memories carry no dates. Each leg is cut at the
  retriever's depth for k = 10 (30).

  Candidates are `{name, source}`: `:fts5`; `{:embedder, module, memory_config}` (the static
  floor, at either variant); or `{:vectors, name}`, vectors precomputed outside the tree
  (`scripts/eval/reference_vectors.py`: MiniLM, potion-retrieval-32M) as `<name>.json`,
  `<name>.corpus.f32` and `<name>.queries.f32` in `vectors_dir:` (the eval directory's `vectors/`
  by default; vectors are derived from weights and stay with them, outside the tree, D7).

  Metrics, per corpus size and candidate: recall@5, recall@10 and MRR@10 over the answerable
  queries, each with a 95 % bootstrap interval (seeded, 10,000 resamples by default), and the
  share of no-answer queries answered with nothing. Pairs (static against MiniLM, potion against
  static) get a paired bootstrap interval on the recall@10 difference, and the verdict applies
  the threshold slice 133 set in advance.
  """

  alias Trinity.Eval.Labels
  alias Trinity.Memory.{Retriever, Scorer, Search}

  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @depth 30
  @default_resamples 10_000

  @type candidate ::
          {String.t(), :fts5 | {:embedder, module(), keyword()} | {:vectors, String.t()}}

  @doc """
  Runs the eval in `dir`. Options: `candidates:` (required), `sizes:` (the corpus sizes),
  `resamples:`, `seed:`. `{:ok, results}` (also written to `results.json` in `dir`), or
  `{:error, reason}` before anything is scored.
  """
  @spec run(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(dir, opts) do
    with :ok <- Labels.verify(dir), do: {:ok, scored(dir, opts)}
  end

  # sobelow_skip reason: Traversal.FileModule: the eval directory is the one the operator names on
  # `mix trinity.eval.*`, a developer tool run in the project; nothing a request, a model or a
  # remote party supplies reaches it, and the file names under it are constants.
  @sobelow_skip ["Traversal.FileModule"]
  defp scored(dir, opts) do
    memories = Labels.read!(dir, "corpus.jsonl")
    queries = Labels.read!(dir, "queries.jsonl")

    ctx = %{
      queries: queries,
      labels: Map.new(Labels.read!(dir, "labels.jsonl"), &{&1["query"], &1["targets"]}),
      resamples: Keyword.get(opts, :resamples, @default_resamples),
      seed: Keyword.get(opts, :seed, 20_261_007)
    }

    candidates = Keyword.fetch!(opts, :candidates)
    vdir = Keyword.get(opts, :vectors_dir, Path.join(dir, "vectors"))

    dense =
      Map.new(candidates, fn {name, src} -> {name, vectors(vdir, src, memories, queries)} end)

    by_size =
      opts
      |> Keyword.get(:sizes, Trinity.Eval.Corpus.sizes())
      |> Map.new(&{&1, at_size(&1, memories, candidates, dense, ctx)})

    results = %{
      "labels_sha256" => Labels.sha256_file(Path.join(dir, "labels.jsonl")),
      "resamples" => ctx.resamples,
      "seed" => ctx.seed,
      "sizes" => Map.new(by_size, fn {s, per} -> {to_string(s), per} end),
      "verdict" => verdict(by_size, ctx.resamples, ctx.seed)
    }

    File.write!(Path.join(dir, "results.json"), Jason.encode!(strip(results), pretty: true))
    results
  end

  defp at_size(size, memories, candidates, dense, ctx) do
    subset = Enum.filter(memories, &(&1["size"] <= size))
    fts = fts_rankings(subset, ctx.queries)
    Map.new(candidates, fn {name, _} -> {name, score(name, dense[name], subset, fts, ctx)} end)
  end

  ## Dense vectors per candidate: the corpus's and the queries'

  defp vectors(_dir, :fts5, _memories, _queries), do: nil

  defp vectors(_dir, {:embedder, module, config}, memories, queries) do
    previous = Application.get_env(:trinity, :memory, [])
    Application.put_env(:trinity, :memory, Keyword.merge(previous, config))

    try do
      {:ok, mv} = module.embed(Enum.map(memories, & &1["text"]))
      {:ok, qv} = module.embed(Enum.map(queries, & &1["text"]))
      quant = module.space().quantization

      %{
        memories: Map.new(Enum.zip(Enum.map(memories, & &1["id"]), prepare(mv, quant))),
        queries: Map.new(Enum.zip(Enum.map(queries, & &1["id"]), prepare(qv, quant))),
        floor: module.thresholds().floor,
        quantization: quant
      }
    after
      Application.put_env(:trinity, :memory, previous)
    end
  end

  # sobelow_skip reason: Traversal.FileModule: the eval directory is the one the operator names on
  # `mix trinity.eval.*`, a developer tool run in the project; nothing a request, a model or a
  # remote party supplies reaches it, and the file names under it are constants. The vectors
  # directory is named the same way (`--vectors`).
  @sobelow_skip ["Traversal.FileModule"]
  defp vectors(vdir, {:vectors, name}, memories, queries) do
    manifest = vdir |> Path.join("#{name}.json") |> File.read!() |> Jason.decode!()
    dim = manifest["dim"]
    read = fn file -> vdir |> Path.join(file) |> File.read!() |> rows(dim) end

    %{
      memories:
        Map.new(Enum.zip(manifest["corpus_ids"], prepare(read.(name <> ".corpus.f32"), "f32"))),
      queries:
        Map.new(Enum.zip(manifest["query_ids"], prepare(read.(name <> ".queries.f32"), "f32"))),
      floor: manifest["floor"] || 0.3,
      quantization: "f32"
    }
    |> tap(fn _ ->
      unless length(manifest["corpus_ids"]) == length(memories) and
               length(manifest["query_ids"]) == length(queries),
             do: raise(ArgumentError, "vectors/#{name} does not cover this corpus")
    end)
  end

  defp rows(bin, dim) do
    width = dim * 4
    for <<row::binary-size(^width) <- bin>>, do: for(<<f::float-little-32 <- row>>, do: f)
  end

  # int8 vectors as the store keeps them; float vectors normalised once, so a dot is a cosine.
  defp prepare(vs, "int8"),
    do:
      Enum.map(vs, fn v ->
        q = Scorer.quantize(v)
        {q, Scorer.norm2(q)}
      end)

  defp prepare(vs, _f32) do
    Enum.map(vs, fn v ->
      n = :math.sqrt(Enum.reduce(v, 0.0, &(&1 * &1 + &2)))
      if n == 0.0, do: v, else: Enum.map(v, &(&1 / n))
    end)
  end

  ## Full text: Trinity's search semantics over an in-memory FTS5 table

  defp fts_rankings(subset, queries) do
    {:ok, db} = Exqlite.Sqlite3.open(":memory:")

    try do
      :ok =
        Exqlite.Sqlite3.execute(
          db,
          "CREATE VIRTUAL TABLE c USING fts5(content, id UNINDEXED, tokenize = 'porter unicode61')"
        )

      {:ok, ins} = Exqlite.Sqlite3.prepare(db, "INSERT INTO c (content, id) VALUES (?1, ?2)")

      for m <- subset do
        :ok = Exqlite.Sqlite3.bind(ins, [m["text"], m["id"]])
        :done = Exqlite.Sqlite3.step(db, ins)
        :ok = Exqlite.Sqlite3.reset(ins)
      end

      {:ok, sel} =
        Exqlite.Sqlite3.prepare(
          db,
          "SELECT id FROM c WHERE c MATCH ?1 ORDER BY bm25(c) LIMIT #{@depth}"
        )

      Map.new(queries, fn q ->
        case Search.terms(q["text"]) do
          [] ->
            {q["id"], []}

          terms ->
            needle =
              Enum.map_join(terms, " ", &("\"" <> String.replace(&1, "\"", "\"\"") <> "\""))

            :ok = Exqlite.Sqlite3.bind(sel, [needle])
            {:ok, ids} = Exqlite.Sqlite3.fetch_all(db, sel)
            :ok = Exqlite.Sqlite3.reset(sel)
            {q["id"], Enum.map(ids, &hd/1)}
        end
      end)
    after
      Exqlite.Sqlite3.close(db)
    end
  end

  ## Scoring one candidate at one size

  defp score(name, dense, subset, fts, %{queries: queries, labels: labels} = ctx) do
    %{resamples: resamples, seed: seed} = ctx
    ids = Enum.map(subset, & &1["id"])

    rankings =
      Map.new(queries, fn q ->
        d = dense_ranking(dense, ids, q["id"])
        hybrid = if name == "fts5", do: fts[q["id"]], else: fuse(fts[q["id"]], d)
        {q["id"], %{hybrid: hybrid, dense: d}}
      end)

    answerable = Enum.filter(queries, &(labels[&1["id"]] != []))
    none = Enum.filter(queries, &(labels[&1["id"]] == []))

    leg = fn which ->
      per_query =
        Map.new(answerable, fn q ->
          r = rankings[q["id"]][which]
          t = labels[q["id"]]
          {q["id"], %{r5: recall(r, t, 5), r10: recall(r, t, 10), mrr: mrr(r, t)}}
        end)

      %{
        "recall@5" => interval(per_query, :r5, resamples, seed),
        "recall@10" => interval(per_query, :r10, resamples, seed),
        "mrr@10" => interval(per_query, :mrr, resamples, seed),
        "no_answer_empty" =>
          if(none == [],
            do: nil,
            else: Enum.count(none, &(rankings[&1["id"]][which] == [])) / length(none)
          ),
        :per_query => per_query
      }
    end

    if name == "fts5",
      do: %{"hybrid" => leg.(:hybrid)},
      else: %{"hybrid" => leg.(:hybrid), "dense_only" => leg.(:dense)}
  end

  defp dense_ranking(nil, _ids, _q), do: []

  defp dense_ranking(%{quantization: quant, floor: floor} = d, ids, q) do
    qv = d.queries[q]

    ids
    |> Enum.map(fn id -> {id, cosine(quant, qv, d.memories[id])} end)
    |> Enum.filter(fn {_, s} -> s >= floor end)
    |> Enum.sort(fn {ia, a}, {ib, b} -> a > b or (a == b and ia <= ib) end)
    |> Enum.take(@depth)
    |> Enum.map(&elem(&1, 0))
  end

  defp cosine("int8", {q, qn2}, {m, mn2}), do: Scorer.cosine(q, qn2, m, mn2)
  defp cosine(_f32, q, m), do: Enum.zip_reduce(q, m, 0.0, fn a, b, acc -> acc + a * b end)

  # Reciprocal rank fusion, as the retriever fuses: a first sighting takes its rank's share, a
  # second adds; ties broken by id.
  defp fuse(fts, dense) do
    [fts, dense]
    |> Enum.reduce(%{}, fn list, acc ->
      list
      |> Enum.with_index(1)
      |> Enum.reduce(acc, fn {id, rank}, a ->
        Map.update(a, id, Retriever.rrf(rank), &(&1 + Retriever.rrf(rank)))
      end)
    end)
    |> Enum.sort(fn {ia, a}, {ib, b} -> a > b or (a == b and ia <= ib) end)
    |> Enum.map(&elem(&1, 0))
  end

  defp recall(ranking, targets, k),
    do: Enum.count(targets, &(&1 in Enum.take(ranking, k))) / length(targets)

  defp mrr(ranking, targets) do
    case ranking |> Enum.take(10) |> Enum.find_index(&(&1 in targets)) do
      nil -> 0.0
      i -> 1 / (i + 1)
    end
  end

  ## Bootstrap intervals, seeded

  defp interval(per_query, key, resamples, seed) do
    values = per_query |> Enum.sort() |> Enum.map(fn {_, m} -> Map.fetch!(m, key) end)
    %{"mean" => mean(values), "ci95" => bootstrap(values, resamples, seed)}
  end

  @doc false
  @spec bootstrap([number()], pos_integer(), integer()) :: [float()]
  def bootstrap([], _resamples, _seed), do: [nil, nil]

  def bootstrap(values, resamples, seed) do
    :rand.seed(:exsss, {seed, 95, 2})
    t = List.to_tuple(values)
    n = tuple_size(t)

    means =
      for _ <- 1..resamples do
        Enum.reduce(1..n, 0.0, fn _, acc -> acc + elem(t, :rand.uniform(n) - 1) end) / n
      end
      |> Enum.sort()

    [Enum.at(means, round(resamples * 0.025)), Enum.at(means, round(resamples * 0.975) - 1)]
  end

  defp mean([]), do: nil
  defp mean(values), do: Enum.sum(values) / length(values)

  ## The verdict, against the threshold set before the run (slice 133 SLICE.md)

  defp verdict(by_size, resamples, seed) do
    gap = fn size, a, b ->
      with %{} = pa <- get_in(by_size, [size, a, "hybrid"]),
           %{} = pb <- get_in(by_size, [size, b, "hybrid"]) do
        paired = Enum.map(Map.keys(pa.per_query), &(pa.per_query[&1].r10 - pb.per_query[&1].r10))

        %{
          "points" => mean(paired) * 100,
          "ci95_points" => Enum.map(bootstrap(paired, resamples, seed), &(&1 && &1 * 100))
        }
      else
        _ -> nil
      end
    end

    sizes = [1_000, 10_000]
    static_vs_minilm = Map.new(sizes, &{to_string(&1), gap.(&1, "static-256-int8", "minilm")})

    potion_vs_static =
      Map.new(sizes, &{to_string(&1), gap.(&1, "potion-retrieval-32M", "static-256-int8")})

    within? =
      Enum.all?(sizes, fn s ->
        case static_vs_minilm[to_string(s)] do
          %{"points" => p} -> p >= -3.0
          _ -> false
        end
      end)

    replaces? =
      Enum.all?(sizes, fn s ->
        case potion_vs_static[to_string(s)] do
          %{"points" => p} -> p > 2.0
          _ -> false
        end
      end)

    %{
      "rule" =>
        "static-256-int8 hybrid within 3.0 points recall@10 of minilm hybrid at both 10^3 and 10^4; " <>
          "potion-retrieval-32M replaces it if more than 2.0 points better at both (subject to tokenizer parity)",
      "static_minus_minilm_recall10" => static_vs_minilm,
      "potion_minus_static_recall10" => potion_vs_static,
      "static_floor_is_regulated_default" => within?,
      "potion_replaces_static" => replaces?
    }
  end

  # The per-query detail stays in memory for the verdict; the file carries the summaries.
  defp strip(%{} = map) do
    map
    |> Enum.reject(fn {k, _} -> k == :per_query end)
    |> Map.new(fn {k, v} -> {k, strip(v)} end)
  end

  defp strip(other), do: other

  @doc "The candidates the owner's run uses, by name; vectors files where no embedder is in process."
  @spec default_candidates() :: [candidate()]
  def default_candidates do
    static = Trinity.Memory.Embedders.Static

    [
      {"fts5", :fts5},
      {"minilm", {:vectors, "minilm"}},
      {"static-256-int8", {:embedder, static, [static_variant: "256-int8"]}},
      {"static-1024-f32", {:embedder, static, [static_variant: "1024-f32"]}},
      {"potion-retrieval-32M", {:vectors, "potion-retrieval-32M"}}
    ]
  end
end
