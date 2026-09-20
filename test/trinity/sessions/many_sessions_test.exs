# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Sessions.ManySessionsTest do
  @moduledoc "Slice 012 AC5: 100 sessions, one fake turn each, at once; no restart; gapless seq."
  use Trinity.SessionCase

  alias Trinity.Factory
  alias Trinity.LLM.Providers.Fake

  @n 100

  @tag timeout: 120_000
  test "100 concurrent sessions each complete a turn with the same pid throughout and seq 1, 2" do
    Fake.script(script_deltas(5, "z"))
    rows = for _ <- 1..@n, do: Factory.session!()
    pids = Map.new(rows, fn r -> {r.id, elem(Sessions.ensure_started(r.id), 1)} end)

    results =
      rows
      |> Task.async_stream(
        fn r ->
          :ok = Sessions.subscribe(r.id)
          {:ok, _} = Sessions.send_user_message(r.id, "hi")
          events = collect(r.id, &match?({:assistant_message, _}, &1), 30_000)
          {r.id, match?({:assistant_message, _}, List.last(events))}
        end,
        max_concurrency: @n,
        timeout: 60_000
      )
      |> Enum.map(fn {:ok, v} -> v end)

    assert Enum.all?(results, fn {_, ok} -> ok end),
           "#{Enum.count(results, &(not elem(&1, 1)))} sessions did not finish"

    for r <- rows do
      assert Sessions.whereis(r.id) == pids[r.id], "session #{r.id} was restarted"
      assert Sessions.seqs(r.id) == [1, 2]
    end
  end
end
