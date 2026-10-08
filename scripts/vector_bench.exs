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

# Migrated before the application starts: Oban checks its own migration at start, and a fresh
# scratch database has none yet.
for repo <- [Trinity.Repo, Trinity.Repo.Receipts] do
  _ = repo.__adapter__().storage_up(Application.get_env(:trinity, repo))
  {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
end

{:ok, _} = Application.ensure_all_started(:trinity)

# Slice 133: vectors live in memory_embeddings under a space; the bench writes the fake's space
# and searches it, as slice 032 measured the model column. TRINITY_BENCH_QUANT=int8 writes the
# same vectors under an int8 space instead, which `Brute` scores with `Trinity.Memory.Scorer`
# (the static floor's path: load, fit check, exact int8 cosine).
alias Trinity.Memory.{AlwaysOn, Embedders.Fake, Entry, Semantic, Spaces, Vector, VectorStore}
alias Trinity.Memory.VectorStores.Brute
{:ok, persona} = Trinity.Personas.create(%{name: "bench-#{System.unique_integer([:positive])}"})
scope = AlwaysOn.persona_scope(persona.id)
space =
  case System.get_env("TRINITY_BENCH_QUANT") do
    "int8" -> %{Fake.space() | model_id: "bench:int8", quantization: "int8"}
    _ -> Fake.space()
  end

{:ok, space_row} = Spaces.register(space)

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
            :ok = Spaces.put_vector(e.id, space_row.id, space, Fake.vector(attrs.body))
          end
        end,
        timeout: :infinity
      )
    end)

  filter = Semantic.filter(persona.id, [scope], space_row)
  q = Fake.vector("fact number #{div(n, 2)}")
  {first_us, _} = :timer.tc(fn -> VectorStore.search(q, 8, filter) end)
  times = for _ <- 1..5, do: elem(:timer.tc(fn -> VectorStore.search(q, 8, filter) end), 0)
  {:ok, [%{entry: top}]} = VectorStore.search(q, 1, filter)

  IO.puts(
    "rows=#{n} insert+store=#{div(ins_us, 1000)} ms search first=#{div(first_us, 1000)} ms p50=#{Enum.at(Enum.sort(times), 2) / 1000} ms max=#{Enum.max(times) / 1000} ms top=#{top.body} store=#{inspect(VectorStore.impl())}"
  )

  if VectorStore.impl() == Brute and space.quantization == "f32" do
    import Ecto.Query

    {load_us, rows} =
      :timer.tc(fn ->
        Trinity.Repo.all(
          from e in Entry,
            join: v in Vector,
            on: v.memory_id == e.id and v.space_id == ^space_row.id,
            where: e.persona_id == ^persona.id and e.tier == "semantic",
            select: {e, v.vector}
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
      "rows=#{n} split: load=#{div(load_us, 1000)} ms elixir_cosine=#{div(elixir_us, 1000)} ms #{exla} vector_bytes=#{Enum.sum(Enum.map(rows, &byte_size(elem(&1, 1))))}"
    )
  end
end
