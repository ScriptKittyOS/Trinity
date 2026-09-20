# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.SessionsStressTest do
  @moduledoc """
  Slice 010 AC2: 20 concurrent processes each append 200 messages across 5 sessions; every
  session's `seq` is gapless; no SQLITE_BUSY surfaces; `PRAGMA integrity_check` is `ok`. On
  the Postgres job the pragma assertion does not apply and the gapless property is the whole
  test. The -wal size is printed after the run, for the checkpoint threshold in config.
  """
  use Trinity.DataCase, async: false

  alias Trinity.Factory
  alias Trinity.Sessions

  @writers 20
  @per_writer 200
  @sessions 5

  @tag timeout: 300_000
  test "gapless seq per session under 20 concurrent writers" do
    sessions = for _ <- 1..@sessions, do: Factory.session!()
    ids = Enum.map(sessions, & &1.id)

    results =
      1..@writers
      |> Task.async_stream(
        fn w ->
          for i <- 1..@per_writer do
            id = Enum.at(ids, rem(w + i, @sessions))
            Sessions.append_message(id, %{role: "user", content: "w#{w} i#{i}"})
          end
        end,
        max_concurrency: @writers,
        timeout: 240_000,
        ordered: false
      )
      |> Enum.flat_map(fn {:ok, list} -> list end)

    case Enum.reject(results, &match?({:ok, _}, &1)) do
      [] -> :ok
      [first | _] = errors -> flunk("#{length(errors)} appends failed; first: #{inspect(first)}")
    end

    assert length(results) == @writers * @per_writer

    for id <- ids do
      seqs = Sessions.seqs(id)
      assert seqs == Enum.to_list(1..length(seqs)), "session #{id} has a gap or a duplicate"
    end

    assert Enum.sum(Enum.map(ids, &Sessions.message_count/1)) == @writers * @per_writer

    if Trinity.Repo.__adapter__() == Ecto.Adapters.SQLite3 do
      assert %{rows: [["ok"]]} = Trinity.Repo.query!("PRAGMA integrity_check")
      wal = Trinity.Repo.config()[:database] <> "-wal"
      size = if File.exists?(wal), do: File.stat!(wal).size, else: 0
      IO.puts("\nstress: -wal size after #{@writers * @per_writer} appends: #{size} bytes")
    end
  end
end
