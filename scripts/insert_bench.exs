# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
#
# The insert benchmark, run against a directory. Slice 025 AC5 uses it to measure what full-disk
# encryption costs, by running it on an encrypted volume and a plain one on the same machine on
# the same day.
#
# It reproduces the two write patterns this project actually uses rather than a synthetic one:
#
#   receipts  synchronous: :full,   one row per transaction  (slice 024: the signed chain, where
#                                                             every receipt must survive a power
#                                                             cut, measured there at 274 us/row)
#   main      synchronous: :normal, batched per transaction  (slice 010: everything else)
#
# Usage:  elixir scripts/insert_bench.exs <directory> [rows]
# Prints one line per pattern: the microseconds per row, which is the number to compare.
Mix.install([{:exqlite, "~> 0.40"}])

[dir | rest] = System.argv()
rows = case rest do
  [n | _] -> String.to_integer(n)
  [] -> 2_000
end

defmodule Bench do
  alias Exqlite.Sqlite3

  def run(dir, rows, label, synchronous, batch) do
    path = Path.join(dir, "insert_bench_#{label}.db")
    File.rm(path); File.rm(path <> "-wal"); File.rm(path <> "-shm")
    {:ok, db} = Sqlite3.open(path)

    :ok = Sqlite3.execute(db, "PRAGMA journal_mode=WAL")
    :ok = Sqlite3.execute(db, "PRAGMA synchronous=#{synchronous}")
    :ok = Sqlite3.execute(db, "CREATE TABLE t (id INTEGER PRIMARY KEY, payload BLOB NOT NULL)")

    # A payload the size of a signed receipt rather than a token, so the measurement is of this
    # project's writes and not of SQLite's row overhead.
    payload = :crypto.strong_rand_bytes(512)

    {micros, :ok} = :timer.tc(fn -> insert(db, rows, payload, batch) end)
    :ok = Sqlite3.close(db)
    File.rm(path); File.rm(path <> "-wal"); File.rm(path <> "-shm")

    per_row = micros / rows
    IO.puts("  #{String.pad_trailing(label, 10)} synchronous=#{String.pad_trailing(synchronous, 6)} " <>
            "batch=#{String.pad_trailing(to_string(batch), 5)} " <>
            "#{:erlang.float_to_binary(per_row, decimals: 1)} us/row  " <>
            "(#{rows} rows in #{div(micros, 1000)} ms)")
    per_row
  end

  defp insert(db, rows, payload, batch) do
    {:ok, stmt} = Sqlite3.prepare(db, "INSERT INTO t (payload) VALUES (?1)")

    Enum.chunk_every(1..rows, batch)
    |> Enum.each(fn chunk ->
      :ok = Sqlite3.execute(db, "BEGIN")
      Enum.each(chunk, fn _ ->
        :ok = Sqlite3.bind(stmt, [payload])
        :done = Sqlite3.step(db, stmt)
      end)
      :ok = Sqlite3.execute(db, "COMMIT")
    end)

    :ok = Sqlite3.release(db, stmt)
    :ok
  end
end

unless File.dir?(dir), do: (IO.puts("no such directory: #{dir}"); System.halt(1))

{fs, 0} = System.cmd("sh", ["-c", "df -T #{dir} | tail -1"])
{dev, _} = System.cmd("sh", ["-c", "findmnt -no SOURCE --target #{dir} 2>/dev/null || echo ?"])

IO.puts("\ninsert bench: #{dir}")
IO.puts("  device: #{String.trim(dev)}")
IO.puts("  mount : #{String.trim(fs)}")
IO.puts("")
Bench.run(dir, rows, "receipts", "FULL", 1)
Bench.run(dir, rows, "main", "NORMAL", 100)
IO.puts("")
