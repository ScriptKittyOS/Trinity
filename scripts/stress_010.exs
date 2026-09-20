# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
#
# Slice 010 AC2, outside the test sandbox, so the writes reach the WAL and the -wal size and
# the throughput are real numbers. Run against the dev database (it is reset first):
#
#   MIX_ENV=dev mix ecto.reset && MIX_ENV=dev mix run scripts/stress_010.exs
#
# Prints: appends, wall time, appends per second, integrity_check, -wal size, per-session
# gapless verdict. Nothing here is a test assertion; the numbers go in PROOF.md by hand.
alias Trinity.Sessions

writers = 20
per_writer = 200
session_count = 5

{:ok, persona} = Sessions.create_persona(%{name: "stress-#{System.unique_integer([:positive])}"})
ids = for _ <- 1..session_count, do: elem(Sessions.create_session(%{persona_id: persona.id}), 1).id

{micros, results} =
  :timer.tc(fn ->
    1..writers
    |> Task.async_stream(
      fn w ->
        for i <- 1..per_writer do
          Sessions.append_message(Enum.at(ids, rem(w + i, session_count)), %{role: "user", content: "w#{w} i#{i}"})
        end
      end,
      max_concurrency: writers,
      timeout: 600_000,
      ordered: false
    )
    |> Enum.flat_map(fn {:ok, list} -> list end)
  end)

errors = Enum.reject(results, &match?({:ok, _}, &1))
gapless =
  Enum.all?(ids, fn id ->
    seqs = Sessions.seqs(id)
    seqs == Enum.to_list(1..length(seqs)//1)
  end)
%{rows: [[integrity]]} = Trinity.Repo.query!("PRAGMA integrity_check")
db = Trinity.Repo.config()[:database]
wal = if File.exists?(db <> "-wal"), do: File.stat!(db <> "-wal").size, else: 0

%{rows: [[sqlite_version]]} = Trinity.Repo.query!("select sqlite_version()")
per_s = Float.round(length(results) / (micros / 1_000_000), 1)

IO.puts(
  "stress_010: appends=#{length(results)} errors=#{length(errors)} wall_ms=#{div(micros, 1000)} " <>
    "appends_per_s=#{per_s} integrity=#{integrity} wal_bytes=#{wal} gapless=#{gapless} sqlite=#{sqlite_version}"
)
