# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
#
# Slice 032 G1: the local embedder measured on this machine. Run with a cache directory:
#   BUMBLEBEE_CACHE_DIR=/path/to/cache MIX_ENV=test mix run --no-start scripts/embed_bench.exs
# The first run downloads all-MiniLM-L6-v2 (91 MB) into that directory.
{:ok, _} = Application.ensure_all_started(:inets)
{:ok, _} = Application.ensure_all_started(:ssl)
{:ok, _} = Application.ensure_all_started(:bumblebee)
{:ok, _} = Application.ensure_all_started(:exla)
Nx.global_default_backend(EXLA.Backend)
cache = System.get_env("BUMBLEBEE_CACHE_DIR")
repo = {:hf, "sentence-transformers/all-MiniLM-L6-v2", cache_dir: cache}
{t_load, {:ok, model_info}} = :timer.tc(fn -> Bumblebee.load_model(repo) end)
{:ok, tokenizer} = Bumblebee.load_tokenizer(repo)
serving = Bumblebee.Text.text_embedding(model_info, tokenizer, compile: [batch_size: 32, sequence_length: 128], defn_options: [compiler: EXLA], output_pool: :mean_pooling, output_attribute: :hidden_state, embedding_processor: :l2_norm)
{t_first, r} = :timer.tc(fn -> Nx.Serving.run(serving, "the cat sat") end)
dim = Nx.size(r.embedding)
IO.puts("load_ms=#{div(t_load, 1000)} first_embed_ms=#{div(t_first, 1000)} dim=#{dim}")
single = for _ <- 1..20, do: elem(:timer.tc(fn -> Nx.Serving.run(serving, "a sentence to embed for timing") end), 0)
IO.puts("single_ms_p50=#{Enum.at(Enum.sort(single), 9) / 1000} single_ms_max=#{Enum.max(single) / 1000}")
batch = for i <- 1..32, do: "sentence number #{i} about something different each time"
{t_batch, _} = :timer.tc(fn -> Nx.Serving.run(serving, batch) end)
IO.puts("batch32_ms=#{div(t_batch, 1000)} per_item_ms=#{Float.round(t_batch / 32000, 2)}")
cos = fn a, b -> Nx.dot(a, b) |> Nx.to_number() end
e = fn t -> Nx.Serving.run(serving, t).embedding end
c1 = cos.(e.("the cat sat"), e.("a cat was sitting"))
c2 = cos.(e.("the cat sat"), e.("quarterly tax filing"))
IO.puts("cosine(cat sat, cat sitting)=#{Float.round(c1, 3)} cosine(cat sat, tax filing)=#{Float.round(c2, 3)}")
{:ok, files} = File.ls(Path.join([cache, "huggingface"]))
size = Path.wildcard(Path.join(cache, "**/*")) |> Enum.filter(&File.regular?/1) |> Enum.map(&File.stat!(&1).size) |> Enum.sum()
IO.puts("model_cache_bytes=#{size} (#{length(files)} entries)")

IO.puts("vm_total_mb=#{div(:erlang.memory(:total), 1_000_000)} rss_mb=#{String.trim(File.read!("/proc/self/status") |> then(fn s -> Regex.run(~r/VmRSS:\s+(\d+)/, s) |> List.last() end)) |> String.to_integer() |> div(1000)}")
