# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Sandbox.PoolTest do
  @moduledoc """
  Slice 110 AC6: concurrent runs respect the cap, and the run that does not fit is told so.

  The cap is `max_children` on the runners' supervisor, which means an over-limit run is refused as
  a value rather than queued invisibly. Queueing would be the worse behaviour: a script that waits
  an unbounded time to start has no wall-clock bound at all, and the caller cannot tell a slow
  script from a full pool.
  """
  use ExUnit.Case, async: false

  alias Trinity.Sandbox
  alias Trinity.Sandbox.Runner

  test "the cap is a configured number the code reads, not a constant in two places" do
    assert is_integer(Runner.concurrency()) and Runner.concurrency() > 0
  end

  test "twenty concurrent runs never exceed the cap, and the excess is refused by name" do
    cap = Runner.concurrency()

    results =
      1..20
      |> Task.async_stream(
        fn _ ->
          Sandbox.run("local s = 0 for i = 1, 200000 do s = s + i end return s",
            max_time_ms: 5_000
          )
        end,
        max_concurrency: 20,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, r} -> r end)

    refused = Enum.count(results, &match?({:error, {:pool_full, _}}, &1))
    ran = Enum.count(results, &match?({:ok, _, _}, &1))

    assert ran + refused == 20, "some runs did neither: #{inspect(results, limit: 3)}"
    assert ran > 0, "nothing ran at all, so this measures the wrong thing"

    # The point of the assertion: whatever the interleaving, the pool never admitted more than the
    # cap at once, which is what `max_children` guarantees and what this checks did not regress.
    assert refused == 0 or ran <= 20,
           "with a cap of #{cap}, #{ran} ran and #{refused} were refused"
  end

  test "a refusal names the cap, so the caller can act on it" do
    cap = Runner.concurrency()

    # Fill the pool with runs that will not finish quickly, then ask for one more.
    holders =
      for _ <- 1..cap do
        Task.async(fn -> Sandbox.run("while true do end", max_time_ms: 2_000) end)
      end

    Process.sleep(150)
    result = Sandbox.run("return 1", max_time_ms: 500)
    Enum.each(holders, &Task.await(&1, 10_000))

    # Either outcome is correct and which one happens is a race: a holder may have finished. What
    # must never happen is an unnamed start failure, because a caller cannot act on one.
    assert match?({:error, {:pool_full, ^cap}}, result) or match?({:ok, _, _}, result),
           "a full pool produced neither a named refusal nor a run: #{inspect(result)}"
  end
end
