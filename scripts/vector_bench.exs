# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
#
# Slice 032 G3: the vector store in force measured over 1,000 and 10,000 fake vectors (the
# numbers in docs/perf.md). Runs against a scratch database, never the data directory:
#   MIX_ENV=test TRINITY_BENCH_DB=/tmp/vector_bench.db mix run --no-start scripts/vector_bench.exs
# On Postgres (the Pgvector store), point the test configuration at a scratch database instead:
#   TRINITY_DB=postgres DATABASE_URL=postgres://.../trinity_bench MIX_ENV=test mix run --no-start scripts/vector_bench.exs
if System.get_env("TRINITY_DB") != "postgres" do
  db =
    System.get_env("TRINITY_BENCH_DB") || raise "TRINITY_BENCH_DB names the scratch SQLite file"

  for repo <- [Trinity.Repo, Trinity.Repo.Receipts] do
    conf =
      Application.get_env(:trinity, repo)
      |> Keyword.delete(:pool)
      |> Keyword.put(:database, db <> if(repo == Trinity.Repo, do: "", else: "_receipts"))

    Application.put_env(:trinity, repo, conf)
  end
else
  for repo <- [Trinity.Repo, Trinity.Repo.Receipts],
      do:
        Application.put_env(
          :trinity,
          repo,
          Keyword.delete(Application.get_env(:trinity, repo), :pool)
        )
end

Logger.configure(level: :info)
{:ok, _} = Application.ensure_all_started(:trinity)
Ecto.Migrator.run(Trinity.Repo, :up, all: true)
Ecto.Migrator.run(Trinity.Repo.Receipts, :up, all: true)

alias Trinity.Memory.{AlwaysOn, Embedders.Fake, Entry, Semantic, VectorStore, VectorStores.Brute}
{:ok, persona} = Trinity.Personas.create(%{name: "bench-#{System.unique_integer([:positive])}"})
scope = AlwaysOn.persona_scope(persona.id)

for n <- [1_000, 10_000] do
  from = Semantic.count(persona.id)

  {ins_us, _} =
    :timer.tc(fn ->
      Trinity.Repo.transaction(
        fn ->
          for i <- (from + 1)..n do
            attrs = %{
              persona_id: persona.id,
              scope: scope,
              key: "k#{i}",
              body: "fact number #{i}"
            }

            {:ok, e} = %Entry{} |> Entry.semantic_changeset(attrs) |> Trinity.Repo.insert()
            :ok = VectorStore.upsert(e.id, Fake.vector("fact number #{i}"), Fake.model_id())
          end
        end,
        timeout: :infinity
      )
    end)

  filter = Semantic.filter(persona.id, [scope])
  q = Fake.vector("fact number #{div(n, 2)}")
  {first_us, _} = :timer.tc(fn -> VectorStore.search(q, 8, filter) end)
  times = for _ <- 1..5, do: elem(:timer.tc(fn -> VectorStore.search(q, 8, filter) end), 0)
  [%{entry: top}] = VectorStore.search(q, 1, filter)

  IO.puts(
    "rows=#{n} insert+store=#{div(ins_us, 1000)} ms search first=#{div(first_us, 1000)} ms p50=#{Enum.at(Enum.sort(times), 2) / 1000} ms max=#{Enum.max(times) / 1000} ms top=#{top.body} store=#{inspect(VectorStore.impl())}"
  )

  if VectorStore.impl() == Brute do
    import Ecto.Query

    {load_us, rows} =
      :timer.tc(fn ->
        Trinity.Repo.all(
          from e in Entry, where: e.persona_id == ^persona.id and e.tier == "semantic"
        )
      end)

    {elixir_us, _} = :timer.tc(fn -> Brute.elixir_scores(rows, q) end)

    exla =
      if Code.ensure_loaded?(EXLA.Backend) and Trinity.Memory.Embedders.Bumblebee.exla() == :ok do
        {a, _} = :timer.tc(fn -> Brute.exla_scores(rows, q) end)
        {b, _} = :timer.tc(fn -> Brute.exla_scores(rows, q) end)
        "exla_first=#{div(a, 1000)} ms exla_second=#{div(b, 1000)} ms"
      else
        "exla=off"
      end

    IO.puts(
      "rows=#{n} split: load=#{div(load_us, 1000)} ms elixir_cosine=#{div(elixir_us, 1000)} ms #{exla} vector_bytes=#{Enum.sum(Enum.map(rows, &byte_size(&1.embedding)))}"
    )
  end
end
