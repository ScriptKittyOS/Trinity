# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
#
# Gate 1, parity (slice 134, AC5): every one of the 500 fixtures embedded by the service has
# cosine >= 0.999 with the sentence-transformers reference, at a pinned num_ctx.
#
#   mix run --no-start scripts/tier3/parity.exs --record <import.json> --fixtures <dir> \
#     [--num-ctx 2048] [--mode client|raw] [--truncate true|false] [--out <results.jsonl>]
#
# `client` (the default) embeds through Trinity's own client, configured from the import record:
# its own token count, truncate:false, the query template on queries, the pin checked first.
# `raw` posts to /api/embed one item at a time with the given num_ctx and truncate, and also
# compares each item's prompt_eval_count with the reference tokenizer's count; it is how the
# red is run (a num_ctx that does not fit the long items, with Ollama's default truncation).
Code.require_file("gate_lib.exs", __DIR__)
{:ok, _} = Application.ensure_all_started(:req)

alias Trinity.Memory.Embedders.Ollama

opts =
  Tier3Gate.args(System.argv(),
    record: :string,
    fixtures: :string,
    num_ctx: :integer,
    mode: :string,
    truncate: :string,
    out: :string,
    base_url: :string,
    batch: :integer
  )

record = Tier3Gate.record!(opts[:record])
dir = opts[:fixtures]
manifest = Tier3Gate.manifest(dir)
rows = Tier3Gate.fixtures(dir, "parity.jsonl")
num_ctx = Keyword.get(opts, :num_ctx, 2048)
mode = Keyword.get(opts, :mode, "client")
prompt = manifest["query_prompt"]
min_cosine = 0.999
base_url = Keyword.get(opts, :base_url, record["ollama"]["base_url"])

text = fn r -> if r["role"] == "query", do: prompt <> r["text"], else: r["text"] end

results =
  case mode do
    "client" ->
      Tier3Gate.configure!(record, num_ctx: num_ctx, query_prompt: prompt, base_url: base_url)
      :ok = Ollama.check()
      batch = Keyword.get(opts, :batch, 8)

      rows
      |> Enum.chunk_by(& &1["role"])
      |> Enum.flat_map(fn group ->
        group
        |> Enum.chunk_every(batch)
        |> Enum.flat_map(fn chunk ->
          texts = Enum.map(chunk, & &1["text"])
          role = hd(chunk)["role"]
          {:ok, vs} = if role == "query", do: Ollama.embed_query(texts), else: Ollama.embed(texts)
          Enum.zip_with(chunk, vs, fn r, v -> %{row: r, vector: v, served: nil, status: 200} end)
        end)
      end)

    "raw" ->
      truncate =
        case Keyword.get(opts, :truncate, "false") do
          "true" -> true
          "false" -> false
          "omit" -> :omit
        end

      Enum.map(rows, fn r ->
        case Tier3Gate.embed_raw(base_url, record["ollama"]["model"], [text.(r)], num_ctx, truncate) do
          {200, %{"embeddings" => [v], "prompt_eval_count" => n}} ->
            %{row: r, vector: v, served: n, status: 200}

          {status, body} ->
            %{row: r, vector: nil, served: nil, status: status, error: body["error"]}
        end
      end)
  end

scored =
  Enum.map(results, fn res ->
    cos = if res.vector, do: Tier3Gate.cosine(res.vector, res.row["embedding"]), else: nil
    Map.put(res, :cosine, cos)
  end)

cosines = for %{cosine: c} when is_number(c) <- scored, do: c
failed = Enum.filter(scored, &(&1.cosine == nil or &1.cosine < min_cosine))
counted = for %{served: s, row: r} when is_integer(s) <- scored, do: {s, r["count"]}
count_mismatch = Enum.count(counted, fn {s, c} -> s != c end)

if out = opts[:out] do
  File.write!(
    out,
    Enum.map_join(scored, "\n", fn s ->
      Jason.encode!(%{
        id: s.row["id"],
        role: s.row["role"],
        reference_count: s.row["count"],
        served: s.served,
        status: s.status,
        cosine: s.cosine
      })
    end) <> "\n"
  )
end

by_role =
  scored
  |> Enum.group_by(&{&1.row["role"], &1.row["count"] > 200})
  |> Enum.map(fn {{role, long}, xs} ->
    cs = for %{cosine: c} when is_number(c) <- xs, do: c
    label = if long, do: "#{role} (over 200 tokens)", else: role
    "  #{label}: #{length(xs)} items, min #{if cs == [], do: "none", else: Float.round(Enum.min(cs), 6)}"
  end)
  |> Enum.sort()

IO.puts("""
GATE1 #{record["gguf"]} as #{record["ollama"]["model"]} (digest #{record["ollama"]["digest"]}), Ollama #{record["ollama"]["version"]}
  mode #{mode}, num_ctx #{num_ctx}#{if mode == "raw", do: ", truncate #{Keyword.get(opts, :truncate, "false")}", else: ", truncate false (the client)"}
  items #{length(scored)}, vectors #{length(cosines)}, min cosine #{if cosines == [], do: "none", else: Float.round(Enum.min(cosines), 8)}, p01 #{if cosines == [], do: "none", else: Float.round(Tier3Gate.percentile(cosines, 1), 8)}, median #{if cosines == [], do: "none", else: Float.round(Tier3Gate.percentile(cosines, 50), 8)}
#{Enum.join(by_role, "\n")}
  below #{min_cosine} or without a vector: #{length(failed)}#{if mode == "raw", do: "\n  prompt_eval_count differing from the reference count: #{count_mismatch} of #{length(counted)}", else: ""}
  worst: #{scored |> Enum.filter(& &1.cosine) |> Enum.sort_by(& &1.cosine) |> Enum.take(3) |> Enum.map_join("; ", &"id #{&1.row["id"]} #{&1.row["role"]} #{&1.row["count"]} tokens #{Float.round(&1.cosine, 6)}")}
GATE1 VERDICT #{if failed == [], do: "PASS", else: "FAIL"} (#{length(scored) - length(failed)} of #{length(scored)} at or over #{min_cosine})
#{Tier3Gate.env_line()}\
""")
